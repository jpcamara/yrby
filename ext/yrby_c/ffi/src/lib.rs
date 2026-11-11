//! yrby's binding as a C ABI (spike). Every function takes one `YrbyArgs`
//! and returns one `YrbyResult`, so the C side has a single trampoline that
//! releases the GVL around any of them (see `../../yrby_c.c`).
//!
//! Contract with the C side:
//! - Nothing here touches Ruby. Inputs are borrowed bytes the caller keeps
//!   alive and unchanged for the call; outputs are owned buffers the caller
//!   frees with `yrby_free`.
//! - No panic crosses the boundary: each entry point catches it and returns
//!   `YRBY_STATUS_PANIC` with the message.
//! - Handles (`YrbyDoc`, `YrbyText`) are boxed and freed by the C side's
//!   dfree. They hold no Ruby objects, so nothing needs GC marking.

#![allow(clippy::missing_safety_doc)]

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, MutexGuard};

use yrs::branch::BranchID;
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, GetString, ReadTxn, Text, TextRef, Transact};

// The pure helpers are shared with the magnus build, file for file.
#[allow(dead_code)]
#[path = "../../../yrby/src/protocol.rs"]
mod protocol;
#[allow(dead_code)]
#[path = "../../../yrby/src/read.rs"]
mod read;
mod shared;

use protocol::{
    classify_message, has_pending, integrated_update, merged_doc_update, update_advances_doc,
    update_is_ready,
};
use shared::{char_len, delete_span, end_or_units, identity, resolve, to_units};

// ---------------------------------------------------------------------------
// The boundary
// ---------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum YrbyStatus {
    /// `ptr`/`len` hold the bytes (if the call returns bytes) and `value` the
    /// number (if it returns one).
    Ok = 0,
    /// The call's answer is nil.
    Nil,
    /// `ptr`/`len` hold the message (UTF-8). Raise `Y::Error`.
    Error,
    /// A panic was caught. `ptr`/`len` hold its message. Raise `Y::Error`.
    Panic,
}

#[repr(C)]
pub struct YrbyResult {
    pub status: YrbyStatus,
    pub value: u64,
    pub ptr: *mut u8,
    pub len: usize,
}

/// One call's arguments. `handle` is a `YrbyDoc` or `YrbyText` (the C side
/// knows which), `ptr`/`len` borrowed input bytes, `a`/`b` integers.
#[repr(C)]
pub struct YrbyArgs {
    pub handle: *mut c_void,
    pub ptr: *const u8,
    pub len: usize,
    pub a: i64,
    pub b: i64,
}

enum Out {
    Bytes(Vec<u8>),
    Value(u64),
    Both(u64, Vec<u8>),
    Nil,
}

fn leak(bytes: Vec<u8>) -> (*mut u8, usize) {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    (Box::into_raw(boxed) as *mut u8, len)
}

fn result(status: YrbyStatus, value: u64, bytes: Option<Vec<u8>>) -> YrbyResult {
    let (ptr, len) = bytes.map(leak).unwrap_or((std::ptr::null_mut(), 0));
    YrbyResult {
        status,
        value,
        ptr,
        len,
    }
}

fn run(f: impl FnOnce() -> Result<Out, String>) -> YrbyResult {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(Out::Bytes(b))) => result(YrbyStatus::Ok, 0, Some(b)),
        Ok(Ok(Out::Value(v))) => result(YrbyStatus::Ok, v, None),
        Ok(Ok(Out::Both(v, b))) => result(YrbyStatus::Ok, v, Some(b)),
        Ok(Ok(Out::Nil)) => result(YrbyStatus::Nil, 0, None),
        Ok(Err(message)) => result(YrbyStatus::Error, 0, Some(message.into_bytes())),
        Err(panic) => {
            let message = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "the document operation failed".to_string());
            result(YrbyStatus::Panic, 0, Some(message.into_bytes()))
        }
    }
}

unsafe fn input<'a>(args: *const YrbyArgs) -> &'a [u8] {
    let args = &*args;
    if args.ptr.is_null() || args.len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(args.ptr, args.len)
    }
}

unsafe fn input_str<'a>(args: *const YrbyArgs) -> Result<&'a str, String> {
    std::str::from_utf8(input(args)).map_err(|e| format!("invalid UTF-8: {e}"))
}

unsafe fn doc<'a>(args: *const YrbyArgs) -> &'a YrbyDoc {
    &*((*args).handle as *const YrbyDoc)
}

unsafe fn text<'a>(args: *const YrbyArgs) -> &'a YrbyText {
    &*((*args).handle as *const YrbyText)
}

/// Free a buffer a `YrbyResult` handed out.
#[no_mangle]
pub unsafe extern "C" fn yrby_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
    }
}

// ---------------------------------------------------------------------------
// Y::Doc
// ---------------------------------------------------------------------------

type Unsent = Arc<Mutex<Vec<Vec<u8>>>>;

pub struct YrbyDoc {
    doc: Doc,
    unsent: Unsent,
}

fn lock(unsent: &Unsent) -> MutexGuard<'_, Vec<Vec<u8>>> {
    unsent
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

const MERGE_FAN_IN: usize = 16;

fn merge_unsent(updates: &[Vec<u8>]) -> Result<Vec<u8>, String> {
    let mut level: Vec<Vec<u8>> = match updates {
        [update] => return Ok(update.clone()),
        _ => merge_chunks(updates)?,
    };
    while level.len() > 1 {
        level = merge_chunks(&level)?;
    }
    Ok(level.pop().unwrap_or_default())
}

fn merge_chunks(updates: &[Vec<u8>]) -> Result<Vec<Vec<u8>>, String> {
    updates
        .chunks(MERGE_FAN_IN)
        .map(|chunk| match chunk {
            [update] => Ok(update.clone()),
            _ => yrs::merge_updates_v1(chunk).map_err(|e| e.to_string()),
        })
        .collect()
}

/// A new document. `a` is the client id when `b` is 1. On success `value`
/// holds the `YrbyDoc` pointer.
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_new(args: *const YrbyArgs) -> YrbyResult {
    let (client_id, has_id) = ((*args).a as u64, (*args).b == 1);
    run(|| {
        let mut options = if has_id {
            yrs::Options::with_client_id(yrs::block::ClientID::new(client_id))
        } else {
            yrs::Options::default()
        };
        options.offset_kind = yrs::OffsetKind::Utf16;
        let doc = Doc::with_options(options);
        let unsent = Unsent::default();
        let sink = unsent.clone();
        doc.observe_update_v1("yrby-unsent", move |txn, event| {
            if shared::is_remote(txn.origin()) {
                return;
            }
            lock(&sink).push(event.update.clone());
        })
        .map_err(|e| e.to_string())?;
        let handle = Box::into_raw(Box::new(YrbyDoc { doc, unsent }));
        Ok(Out::Value(handle as usize as u64))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_free(doc: *mut c_void) {
    if !doc.is_null() {
        drop(Box::from_raw(doc as *mut YrbyDoc));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_client_id(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| Ok(Out::Value(d.doc.client_id().get())))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_encode_state_vector(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| Ok(Out::Bytes(d.doc.transact().state_vector().encode_v1())))
}

/// `b` is 1 when `ptr`/`len` hold a state vector to diff against.
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_encode_state_as_update(args: *const YrbyArgs) -> YrbyResult {
    let (d, sv, has_sv) = (doc(args), input(args), (*args).b == 1);
    run(|| {
        let sv = if has_sv {
            yrs::StateVector::decode_v1(sv).map_err(|e| e.to_string())?
        } else {
            yrs::StateVector::default()
        };
        Ok(Out::Bytes(d.doc.transact().encode_state_as_update_v1(&sv)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_apply_update(args: *const YrbyArgs) -> YrbyResult {
    let (d, bytes) = (doc(args), input(args));
    run(|| {
        let update = yrs::Update::decode_v1(bytes).map_err(|e| e.to_string())?;
        let mut txn = d.doc.transact_mut_with(shared::REMOTE);
        txn.apply_update(update).map_err(|e| e.to_string())?;
        Ok(Out::Nil)
    })
}

/// The root names, each as a u32 (little endian) length and its bytes.
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_root_names(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let mut out = Vec::new();
        for (name, _) in d.doc.transact().root_refs() {
            out.extend_from_slice(&(name.len() as u32).to_le_bytes());
            out.extend_from_slice(name.as_bytes());
        }
        Ok(Out::Bytes(out))
    })
}

fn some_string(s: Option<String>) -> Out {
    s.map_or(Out::Nil, |s| Out::Bytes(s.into_bytes()))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_read_text(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let name = input_str(args)?;
        let txn = d.doc.transact();
        Ok(some_string(txn.get_text(name).map(|t| t.get_string(&txn))))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_read_xml(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let name = input_str(args)?;
        let txn = d.doc.transact();
        let text = txn
            .get_xml_fragment(name)
            .map(|f| read::xml_blocks_text(&txn, &f));
        Ok(some_string(text))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_read_map(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let name = input_str(args)?;
        let txn = d.doc.transact();
        Ok(some_string(
            txn.get_map(name).map(|m| read::map_json(&txn, &m)),
        ))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_read_array(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let name = input_str(args)?;
        let txn = d.doc.transact();
        Ok(some_string(
            txn.get_array(name).map(|a| read::array_json(&txn, &a)),
        ))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_pending(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| Ok(Out::Value(has_pending(&d.doc) as u64)))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_compacted_state_update(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| integrated_update(&d.doc, &yrs::StateVector::default()).map(Out::Bytes))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_update_ready(args: *const YrbyArgs) -> YrbyResult {
    let (d, bytes) = (doc(args), input(args));
    run(|| update_is_ready(&d.doc, bytes).map(|b| Out::Value(b as u64)))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_update_advances(args: *const YrbyArgs) -> YrbyResult {
    let (d, bytes) = (doc(args), input(args));
    run(|| update_advances_doc(&d.doc, bytes).map(|b| Out::Value(b as u64)))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_sync_step1(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let sv = d.doc.transact().state_vector();
        Ok(Out::Bytes(
            Message::Sync(SyncMessage::SyncStep1(sv)).encode_v1(),
        ))
    })
}

/// `value` is the message type in the high byte and the sync type in the
/// low one; the bytes are the response (empty for none).
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_handle_sync_message(args: *const YrbyArgs) -> YrbyResult {
    let (d, bytes) = (doc(args), input(args));
    let apply = |update_bytes: &[u8]| -> Result<(), String> {
        let update = yrs::Update::decode_v1(update_bytes).map_err(|e| e.to_string())?;
        let mut txn = d.doc.transact_mut_with(shared::REMOTE);
        txn.apply_update(update).map_err(|e| e.to_string())
    };
    run(
        || match Message::decode_v1(bytes).map_err(|e| e.to_string())? {
            Message::Sync(SyncMessage::SyncStep1(sv)) => {
                let update = d.doc.transact().encode_state_as_update_v1(&sv);
                let response = Message::Sync(SyncMessage::SyncStep2(update));
                Ok(Out::Both(0, response.encode_v1()))
            }
            Message::Sync(SyncMessage::SyncStep2(update)) => {
                apply(&update)?;
                Ok(Out::Both(1, Vec::new()))
            }
            Message::Sync(SyncMessage::Update(update)) => {
                apply(&update)?;
                Ok(Out::Both(2, Vec::new()))
            }
            Message::Awareness(_) => Ok(Out::Both(1 << 8, Vec::new())),
            _ => Err("unsupported message type".to_string()),
        },
    )
}

/// Every unsent update merged into one, or nil. On a failed merge they go
/// back ahead of anything written since.
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_take_unsent(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let taken = std::mem::take(&mut *lock(&d.unsent));
        if taken.is_empty() {
            return Ok(Out::Nil);
        }
        match merge_unsent(&taken) {
            Ok(merged) => Ok(Out::Bytes(merged)),
            Err(error) => {
                let mut unsent = lock(&d.unsent);
                let since = std::mem::replace(&mut *unsent, taken);
                unsent.extend(since);
                Err(error)
            }
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_doc_keep_unsent(args: *const YrbyArgs) -> YrbyResult {
    let (d, bytes) = (doc(args), input(args));
    run(|| {
        lock(&d.unsent).insert(0, bytes.to_vec());
        Ok(Out::Nil)
    })
}

// ---------------------------------------------------------------------------
// Y::Text
// ---------------------------------------------------------------------------

pub struct YrbyText {
    doc: Doc,
    id: BranchID,
}

/// A handle to the root text named by `ptr`/`len`, created if absent.
/// `value` holds the `YrbyText` pointer.
#[no_mangle]
pub unsafe extern "C" fn yrby_doc_get_text(args: *const YrbyArgs) -> YrbyResult {
    let d = doc(args);
    run(|| {
        let name = input_str(args)?;
        let id = identity(&d.doc.get_or_insert_text(name));
        let handle = Box::into_raw(Box::new(YrbyText {
            doc: d.doc.clone(),
            id,
        }));
        Ok(Out::Value(handle as usize as u64))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_text_free(text: *mut c_void) {
    if !text.is_null() {
        drop(Box::from_raw(text as *mut YrbyText));
    }
}

#[no_mangle]
pub unsafe extern "C" fn yrby_text_to_s(args: *const YrbyArgs) -> YrbyResult {
    let t = text(args);
    run(|| {
        let txn = t.doc.transact();
        let s = resolve::<TextRef, _>(&txn, &t.id)
            .map(|t| t.get_string(&txn))
            .unwrap_or_default();
        Ok(Out::Bytes(s.into_bytes()))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_text_length(args: *const YrbyArgs) -> YrbyResult {
    let t = text(args);
    run(|| {
        let txn = t.doc.transact();
        let n = resolve::<TextRef, _>(&txn, &t.id).map_or(0, |x| char_len(&txn, &x));
        Ok(Out::Value(n as u64))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_text_is_empty(args: *const YrbyArgs) -> YrbyResult {
    let t = text(args);
    run(|| {
        let txn = t.doc.transact();
        let empty = resolve::<TextRef, _>(&txn, &t.id).is_none_or(|x| x.len(&txn) == 0);
        Ok(Out::Value(empty as u64))
    })
}

/// Insert `ptr`/`len` (UTF-8) at character `a` (-1 appends).
#[no_mangle]
pub unsafe extern "C" fn yrby_text_insert(args: *const YrbyArgs) -> YrbyResult {
    let (t, index) = (text(args), (*args).a);
    run(|| {
        let chunk = input_str(args)?;
        let mut txn = t.doc.transact_mut_with(shared::ORIGIN);
        let x = resolve::<TextRef, _>(&txn, &t.id).ok_or("text no longer exists")?;
        let at = end_or_units(&txn, &x, index);
        x.insert(&mut txn, at, chunk);
        Ok(Out::Nil)
    })
}

/// Remove `b` characters from character `a`, as `String#slice!` does.
#[no_mangle]
pub unsafe extern "C" fn yrby_text_delete(args: *const YrbyArgs) -> YrbyResult {
    let (t, index, length) = (text(args), (*args).a, (*args).b);
    run(|| {
        let mut txn = t.doc.transact_mut_with(shared::ORIGIN);
        let x = resolve::<TextRef, _>(&txn, &t.id).ok_or("text no longer exists")?;
        if let Some((from, to)) = delete_span(index, length, char_len(&txn, &x)) {
            let (from, to) = (to_units(&txn, &x, from), to_units(&txn, &x, to));
            if to > from {
                x.remove_range(&mut txn, from, to - from);
            }
        }
        Ok(Out::Nil)
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_text_clear(args: *const YrbyArgs) -> YrbyResult {
    let t = text(args);
    run(|| {
        let mut txn = t.doc.transact_mut_with(shared::ORIGIN);
        if let Some(x) = resolve::<TextRef, _>(&txn, &t.id) {
            let len = x.len(&txn);
            if len > 0 {
                x.remove_range(&mut txn, 0, len);
            }
        }
        Ok(Out::Nil)
    })
}

// ---------------------------------------------------------------------------
// Y module functions: the stateless protocol codec
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn yrby_wrap_update(args: *const YrbyArgs) -> YrbyResult {
    let bytes = input(args);
    run(|| {
        Ok(Out::Bytes(
            Message::Sync(SyncMessage::Update(bytes.to_vec())).encode_v1(),
        ))
    })
}

#[no_mangle]
pub unsafe extern "C" fn yrby_message_kind(args: *const YrbyArgs) -> YrbyResult {
    let bytes = input(args);
    run(|| Ok(Out::Value(classify_message(bytes) as u64)))
}

#[no_mangle]
pub unsafe extern "C" fn yrby_update_from_message(args: *const YrbyArgs) -> YrbyResult {
    let bytes = input(args);
    run(|| Ok(merged_doc_update(bytes)?.map_or(Out::Nil, Out::Bytes)))
}

/// Compile-time proof that what the handles hold may cross threads.
#[allow(dead_code)]
fn assert_thread_safe() {
    fn is_send_sync<T: Send + Sync>() {}
    is_send_sync::<YrbyDoc>();
    is_send_sync::<YrbyText>();
}
