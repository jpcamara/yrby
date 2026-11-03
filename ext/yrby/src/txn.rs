//! `Doc#transact` and `Doc#edit`: one write transaction across several calls.
//!
//! Every handle call and document read opens its own transaction, unless a
//! `transact` or `edit` block has one open for the same document on this
//! thread. Then it uses that one, so the block's writes commit together and
//! its reads see them before they commit.
//!
//! The scope is the thread. Ruby runs the block with the GVL held, and
//! fibers on a thread take turns, so a fiber the block resumes joins the
//! transaction. A separate transaction on the same thread would wait forever
//! on the open one. Another thread waits for the commit, with the GVL
//! released, and never sees the block's writes half done.
//!
//! Applying a remote update needs a transaction of its own, so it raises
//! inside a block instead of joining it.

use std::cell::RefCell;
use std::ops::{Deref, DerefMut};

use magnus::{Error, Ruby, Value};
use yrs::{Doc, ReadTxn, Store, Transact, Transaction, TransactionMut};

use crate::shared::ORIGIN;
use crate::{nogvl, yrb_error};

/// A transaction a block holds open, and the document it is for.
struct Held {
    doc: Doc,
    txn: *mut TransactionMut<'static>,
}

thread_local! {
    static HELD: RefCell<Vec<Held>> = const { RefCell::new(Vec::new()) };
}

/// The transaction a block on this thread holds open for `doc`, if any.
fn held(doc: &Doc) -> Option<*mut TransactionMut<'static>> {
    HELD.with(|held| {
        held.borrow()
            .iter()
            .find(|h| Doc::ptr_eq(&h.doc, doc))
            .map(|h| h.txn)
    })
}

/// Whether a block on this thread holds a transaction open for `doc`.
pub fn is_held(doc: &Doc) -> bool {
    held(doc).is_some()
}

/// Raises instead of opening a second transaction where one is held, which
/// would never return.
pub fn refuse_held(doc: &Doc, what: &str) -> Result<(), Error> {
    if is_held(doc) {
        return Err(yrb_error(format!(
            "{what} can't run inside transact or edit on the same document"
        )));
    }
    Ok(())
}

/// A read transaction: the held one, or one of its own.
pub enum Reader<'a> {
    Own(Transaction<'a>),
    Held(&'a TransactionMut<'a>),
}

impl ReadTxn for Reader<'_> {
    fn store(&self) -> &Store {
        match self {
            Reader::Own(txn) => ReadTxn::store(txn),
            Reader::Held(txn) => ReadTxn::store(*txn),
        }
    }
}

/// A write transaction: the held one, or one of its own that commits when
/// it's dropped. It lives on the stack for one call, so its size is fine.
#[allow(clippy::large_enum_variant)]
pub enum Writer<'a> {
    Own(TransactionMut<'a>),
    Held(&'a mut TransactionMut<'a>),
}

impl<'a> Deref for Writer<'a> {
    type Target = TransactionMut<'a>;

    fn deref(&self) -> &TransactionMut<'a> {
        match self {
            Writer::Own(txn) => txn,
            Writer::Held(txn) => txn,
        }
    }
}

impl<'a> DerefMut for Writer<'a> {
    fn deref_mut(&mut self) -> &mut TransactionMut<'a> {
        match self {
            Writer::Own(txn) => txn,
            Writer::Held(txn) => txn,
        }
    }
}

impl ReadTxn for Writer<'_> {
    fn store(&self) -> &Store {
        ReadTxn::store(&**self)
    }
}

/// A transaction to read `doc` with.
pub fn read(doc: &Doc) -> Reader<'_> {
    match held(doc) {
        // SAFETY: the held transaction lives until its block returns, and
        // this thread is inside that block. A reader never outlives the
        // native call that made it.
        Some(txn) => Reader::Held(unsafe { &*(txn as *const TransactionMut<'_>) }),
        None => Reader::Own(doc.transact()),
    }
}

/// A transaction to write `doc` with. Writes carry the handle origin.
pub fn write(doc: &Doc) -> Writer<'_> {
    match held(doc) {
        // SAFETY: as in `read`. One native call makes one writer at a time,
        // and nothing else on this thread runs until it returns.
        Some(txn) => Writer::Held(unsafe { &mut *txn.cast::<TransactionMut<'_>>() }),
        None => Writer::Own(doc.transact_mut_with(ORIGIN)),
    }
}

/// Moves a value into and out of a `nogvl` closure. The closure runs on the
/// calling thread, so nothing actually crosses threads.
struct OnThisThread<T>(T);
unsafe impl<T> Send for OnThisThread<T> {}

/// A write transaction held open while a Ruby block runs.
struct Hold {
    // Declared before `_doc` so it drops (commits) first.
    txn: Option<Box<TransactionMut<'static>>>,
    _doc: Box<Doc>,
}

impl Hold {
    /// Waits for the document, with the GVL released, then holds a write
    /// transaction open on this thread.
    fn open(doc: &Doc) -> Hold {
        let owned = Box::new(doc.clone());
        // SAFETY: the box keeps the document at one address for as long as
        // the transaction that borrows it, which drops first.
        let borrowed: &'static Doc = unsafe { &*(&*owned as *const Doc) };
        let txn = nogvl(move || OnThisThread(Box::new(borrowed.transact_mut_with(ORIGIN)))).0;
        let mut hold = Hold {
            txn: Some(txn),
            _doc: owned,
        };
        let ptr: *mut TransactionMut<'static> = &mut **hold.txn.as_mut().unwrap();
        HELD.with(|held| {
            held.borrow_mut().push(Held {
                doc: doc.clone(),
                txn: ptr,
            })
        });
        hold
    }

    /// The update this transaction has made so far, or nil for none.
    fn update(&self) -> Option<Vec<u8>> {
        let txn = self.txn.as_ref().unwrap();
        let update = txn.encode_update_v1();
        // An update with no structs and no deletions encodes as [0, 0].
        (update != [0, 0]).then_some(update)
    }
}

impl Drop for Hold {
    fn drop(&mut self) {
        let ptr: *const TransactionMut<'static> = &**self.txn.as_ref().unwrap();
        HELD.with(|held| held.borrow_mut().retain(|h| !std::ptr::eq(h.txn, ptr)));
        // Committing runs observers and merges blocks, without the GVL.
        let txn = OnThisThread(self.txn.take());
        nogvl(move || drop(txn));
    }
}

/// Runs the caller's block with a write transaction held open for `doc`, and
/// commits when it returns or raises. A block already holding one for `doc`
/// on this thread just runs, inside it.
pub fn transact(ruby: &Ruby, doc: &Doc) -> Result<Value, Error> {
    let block = ruby.block_proc()?;
    if is_held(doc) {
        return block.call(());
    }
    let hold = Hold::open(doc);
    let result = block.call(());
    drop(hold);
    result
}

/// Runs the caller's block in a transaction of its own and returns the
/// update its writes made, or nil when they changed nothing. The block's
/// writes stay in the document even if it raises.
pub fn edit(ruby: &Ruby, doc: &Doc) -> Result<Option<Vec<u8>>, Error> {
    let block = ruby.block_proc()?;
    refuse_held(doc, "edit")?;
    let hold = Hold::open(doc);
    let result = block.call::<_, Value>(());
    let update = hold.update();
    drop(hold);
    result.map(|_| update)
}
