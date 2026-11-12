//! pg_yrby: Yjs documents as a Postgres column type.
//!
//! `ydoc` is a varlena holding a v1-encoded Yjs update (the merged document).
//! Functions take raw updates and state vectors as `bytea`, which is what Yjs
//! clients send. See README.md for the storage patterns.

use pgrx::callconv::{Arg, ArgAbi, BoxRet, FcInfo};
use pgrx::datum::Datum;
use pgrx::nullable::Nullable;
use pgrx::prelude::*;
use pgrx::{Internal, JsonB, PgMemoryContexts};
use std::ffi::{CStr, CString};

::pgrx::pg_module_magic!(name, version);

pub mod ycore;

fn raise(e: ycore::Error) -> ! {
    pgrx::error!("pg_yrby: {e}")
}

fn ok<T>(r: Result<T, ycore::Error>) -> T {
    r.unwrap_or_else(|e| raise(e))
}

// ---------------------------------------------------------------------------
// The ydoc type

/// A Yjs document: a v1 update holding the whole state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ydoc(pub Vec<u8>);

impl Ydoc {
    fn bytes(&self) -> &[u8] {
        &self.0
    }
}

impl FromDatum for Ydoc {
    unsafe fn from_polymorphic_datum(datum: pg_sys::Datum, is_null: bool, typoid: pg_sys::Oid) -> Option<Self> {
        // Same varlena layout as bytea.
        unsafe { <Vec<u8> as FromDatum>::from_polymorphic_datum(datum, is_null, typoid) }.map(Ydoc)
    }
}

impl IntoDatum for Ydoc {
    fn into_datum(self) -> Option<pg_sys::Datum> {
        self.0.into_datum()
    }

    fn type_oid() -> pg_sys::Oid {
        pgrx::regtypein("ydoc")
    }
}

unsafe impl<'fcx> ArgAbi<'fcx> for Ydoc {
    unsafe fn unbox_arg_unchecked(arg: Arg<'_, 'fcx>) -> Self {
        let index = arg.index();
        unsafe { arg.unbox_arg_using_from_datum() }.unwrap_or_else(|| panic!("argument {index} must not be null"))
    }

    unsafe fn unbox_nullable_arg(arg: Arg<'_, 'fcx>) -> Nullable<Self> {
        unsafe { arg.unbox_arg_using_from_datum() }.into()
    }
}

unsafe impl BoxRet for Ydoc {
    unsafe fn box_into<'fcx>(self, fcinfo: &mut FcInfo<'fcx>) -> Datum<'fcx> {
        unsafe { fcinfo.return_optional_datum(self.into_datum()) }
    }
}

pgrx::impl_sql_translatable!(Ydoc, "ydoc");

extension_sql!(
    "CREATE TYPE ydoc; -- shell, completed in ydoc_type",
    name = "ydoc_shell",
    bootstrap
);

/// Text input: bytea hex (`\x...`). Validated as a v1 update.
#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_in(input: &CStr) -> Ydoc {
    let s = input.to_str().unwrap_or_else(|_| pgrx::error!("pg_yrby: ydoc input is not UTF-8"));
    let hex = s
        .strip_prefix("\\x")
        .unwrap_or_else(|| pgrx::error!("pg_yrby: ydoc input must be bytea hex (\\x...)"));
    let bytes = decode_hex(hex).unwrap_or_else(|| pgrx::error!("pg_yrby: invalid hex in ydoc input"));
    ok(ycore::validate(&bytes));
    Ydoc(bytes)
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_out(doc: Ydoc) -> CString {
    let mut s = String::with_capacity(2 + doc.0.len() * 2);
    s.push_str("\\x");
    for b in doc.bytes() {
        s.push_str(&format!("{b:02x}"));
    }
    CString::new(s).expect("hex has no NUL")
}

fn decode_hex(hex: &str) -> Option<Vec<u8>> {
    if hex.len() % 2 != 0 {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect()
}

/// Binary input (binary COPY, binary protocol): the raw v1 update, validated
/// like text input. Output is bytea's `byteasend`, the same bytes.
#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_recv(mut buf: Internal) -> Ydoc {
    // SAFETY: Postgres passes a receive function a StringInfo positioned at
    // this value, and the value is the rest of the buffer.
    let buf = unsafe { buf.get_mut::<pg_sys::StringInfoData>() }.expect("ydoc_recv needs a buffer");
    let bytes = unsafe {
        std::slice::from_raw_parts(buf.data.add(buf.cursor as usize).cast::<u8>(), (buf.len - buf.cursor) as usize)
    }
    .to_vec();
    buf.cursor = buf.len;
    ok(ycore::validate(&bytes));
    Ydoc(bytes)
}

/// A ydoc from a raw v1 update, validated. Also the `bytea::ydoc` cast.
#[pg_extern(immutable, parallel_safe, strict, name = "ydoc", requires = ["ydoc_shell"])]
fn ydoc_from_bytea(update: &[u8]) -> Ydoc {
    ok(ycore::validate(update));
    Ydoc(update.to_vec())
}

/// An empty document.
#[pg_extern(immutable, parallel_safe, name = "ydoc", requires = ["ydoc_shell"])]
fn ydoc_empty() -> Ydoc {
    Ydoc(ycore::EMPTY.to_vec())
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_eq(a: Ydoc, b: Ydoc) -> bool {
    ok(ycore::equal(a.bytes(), b.bytes()))
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_ne(a: Ydoc, b: Ydoc) -> bool {
    !ydoc_eq(a, b)
}

extension_sql!(
    r#"
CREATE FUNCTION ydoc_send(ydoc) RETURNS bytea AS 'byteasend' LANGUAGE internal IMMUTABLE STRICT PARALLEL SAFE;

CREATE TYPE ydoc (
    INPUT = ydoc_in,
    OUTPUT = ydoc_out,
    RECEIVE = ydoc_recv,
    SEND = ydoc_send,
    INTERNALLENGTH = VARIABLE,
    STORAGE = extended,
    ALIGNMENT = int4
);

-- Same bytes either way; bytea -> ydoc validates the update.
CREATE CAST (ydoc AS bytea) WITHOUT FUNCTION;
CREATE CAST (bytea AS ydoc) WITH FUNCTION ydoc(bytea);

CREATE OPERATOR = (
    LEFTARG = ydoc, RIGHTARG = ydoc, FUNCTION = ydoc_eq,
    COMMUTATOR = =, NEGATOR = <>
);
CREATE OPERATOR <> (
    LEFTARG = ydoc, RIGHTARG = ydoc, FUNCTION = ydoc_ne,
    COMMUTATOR = <>, NEGATOR = =
);
"#,
    name = "ydoc_type",
    requires = [ydoc_in, ydoc_out, ydoc_recv, ydoc_from_bytea, ydoc_eq, ydoc_ne]
);

// ---------------------------------------------------------------------------
// Operations

/// Apply a v1 update. A NULL document is treated as empty, so this works for
/// a new row. When the update changes nothing the input value comes back.
#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_apply(doc: Option<Ydoc>, update: Option<&[u8]>) -> Option<Ydoc> {
    let Some(update) = update else { return doc };
    let current = doc.as_ref().map(Ydoc::bytes).unwrap_or(&[]);
    match ok(ycore::apply(current, update)) {
        Some(next) => Some(Ydoc(next)),
        None => Some(doc.unwrap_or_else(ydoc_empty)),
    }
}

/// True if applying `update` would change the document.
#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_adds(doc: Option<Ydoc>, update: &[u8]) -> bool {
    ok(ycore::adds(doc.as_ref().map(Ydoc::bytes).unwrap_or(&[]), update))
}

/// The v1 state vector (sync step 1).
#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_state_vector(doc: Ydoc) -> Vec<u8> {
    ok(ycore::state_vector(doc.bytes()))
}

/// What a peer with state vector `sv` is missing (sync step 2). With no
/// state vector, the whole document. Pending content is left out unless
/// `include_pending`, which serves it the way Yjs's `encodeStateAsUpdate`
/// does so a peer can hold it and heal the gap too.
#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_diff(doc: Ydoc, sv: default!(Option<&[u8]>, "NULL"), include_pending: default!(bool, false)) -> Vec<u8> {
    let sv = sv.unwrap_or(&[]);
    if include_pending {
        ok(ycore::diff_with_pending(doc.bytes(), sv))
    } else {
        ok(ycore::diff(doc.bytes(), sv))
    }
}

/// True if the document holds updates waiting on a missing dependency.
#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_has_pending(doc: Ydoc) -> bool {
    ok(ycore::pending(doc.bytes()))
}

/// Merge two documents (or a document and an update) without loading either.
#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_merge(a: Ydoc, b: Ydoc) -> Ydoc {
    Ydoc(ok(ycore::merge(&[a.0, b.0])))
}

// ---------------------------------------------------------------------------
// Reads

#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_text(doc: Ydoc, name: &str) -> Option<String> {
    ok(ycore::text(doc.bytes(), name))
}

#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_map(doc: Ydoc, name: &str) -> Option<JsonB> {
    ok(ycore::map_json(doc.bytes(), name)).map(jsonb)
}

#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_array(doc: Ydoc, name: &str) -> Option<JsonB> {
    ok(ycore::array_json(doc.bytes(), name)).map(jsonb)
}

#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_xml(doc: Ydoc, name: &str) -> Option<String> {
    ok(ycore::xml(doc.bytes(), name))
}

/// Every root as JSON, with each root's type inferred from its content.
#[pg_extern(immutable, parallel_safe, strict, requires = ["ydoc_shell"])]
fn ydoc_json(doc: Ydoc) -> JsonB {
    jsonb(ok(ycore::json(doc.bytes())))
}

fn jsonb(s: String) -> JsonB {
    JsonB(serde_json::from_str(&s).unwrap_or_else(|e| pgrx::error!("pg_yrby: bad JSON from yrs: {e}")))
}

// ---------------------------------------------------------------------------
// Merge aggregate

/// Collected updates, owned by the aggregate's memory context. Folded into
/// one update every `FOLD_AT` rows to bound memory.
type AggState = Vec<Vec<u8>>;
const FOLD_AT: usize = 256;

unsafe fn agg_state<'a>(state: Option<Internal>, fcinfo: pg_sys::FunctionCallInfo) -> (Internal, &'a mut AggState) {
    if let Some(mut state) = state {
        if let Some(parts) = unsafe { state.get_mut::<AggState>() } {
            let ptr = parts as *mut AggState;
            return (state, unsafe { &mut *ptr });
        }
    }
    let mut ctx = std::ptr::null_mut();
    if unsafe { pg_sys::AggCheckCallContext(fcinfo, &mut ctx) } == 0 {
        pgrx::error!("pg_yrby: ydoc_merge_agg transition called outside an aggregate");
    }
    let ptr = PgMemoryContexts::For(ctx).leak_and_drop_on_delete(AggState::new());
    (Internal::from(Some(pg_sys::Datum::from(ptr))), unsafe { &mut *ptr })
}

fn agg_push(parts: &mut AggState, update: &[u8]) {
    parts.push(update.to_vec());
    if parts.len() >= FOLD_AT {
        let folded = ok(ycore::merge(parts));
        parts.clear();
        parts.push(folded);
    }
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_merge_agg_bytea_sfunc(
    state: Option<Internal>,
    update: Option<&[u8]>,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Internal {
    let (state, parts) = unsafe { agg_state(state, fcinfo) };
    if let Some(update) = update {
        agg_push(parts, update);
    }
    state
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_merge_agg_ydoc_sfunc(
    state: Option<Internal>,
    doc: Option<Ydoc>,
    fcinfo: pg_sys::FunctionCallInfo,
) -> Internal {
    let (state, parts) = unsafe { agg_state(state, fcinfo) };
    if let Some(doc) = doc {
        agg_push(parts, doc.bytes());
    }
    state
}

#[pg_extern(immutable, parallel_safe, requires = ["ydoc_shell"])]
fn ydoc_merge_agg_ffunc(state: Option<Internal>) -> Option<Ydoc> {
    let state = state?;
    let parts = unsafe { state.get::<AggState>()? };
    if parts.is_empty() {
        return None;
    }
    Some(Ydoc(ok(ycore::merge(parts))))
}

extension_sql!(
    r#"
-- Merge a set of updates (or documents) into one document, without loading
-- a Doc. Order does not matter. NULL inputs are skipped; no inputs give NULL.
CREATE AGGREGATE ydoc_merge_agg(bytea) (
    SFUNC = ydoc_merge_agg_bytea_sfunc,
    STYPE = internal,
    FINALFUNC = ydoc_merge_agg_ffunc
);
CREATE AGGREGATE ydoc_merge_agg(ydoc) (
    SFUNC = ydoc_merge_agg_ydoc_sfunc,
    STYPE = internal,
    FINALFUNC = ydoc_merge_agg_ffunc
);
"#,
    name = "ydoc_merge_agg",
    requires = ["ydoc_type", ydoc_merge_agg_bytea_sfunc, ydoc_merge_agg_ydoc_sfunc, ydoc_merge_agg_ffunc]
);

#[cfg(any(test, feature = "pg_test"))]
mod tests;

/// This module is required by `cargo pgrx test` invocations.
/// It must be visible at the root of your extension crate.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
