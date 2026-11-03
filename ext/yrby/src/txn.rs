//! `Doc#transact` and `Doc#edit`: one write transaction across several calls.
//!
//! Every handle call and document read opens its own transaction, unless the
//! current fiber is inside a `transact` or `edit` block for the same
//! document. Then it uses the block's transaction, so the block's writes
//! commit together and its reads see them before they commit.
//!
//! A block's transaction belongs to its fiber. Another thread or fiber waits
//! for the commit and never sees the block's writes half done.
//!
//! Waiting happens with the GVL held: try the lock, and if it's taken, sleep
//! through Kernel#sleep and try again. So a wait can be interrupted (Timeout,
//! Thread#kill, Ctrl-C), and under a fiber scheduler it yields to other
//! fibers, the block's among them. A fiber with no scheduler can't let the
//! block's fiber on its own thread run, so it raises instead of waiting
//! forever.
//!
//! Applying a remote update needs a transaction of its own, so it raises
//! inside a block instead of joining it.

use std::cell::RefCell;
use std::ops::{Deref, DerefMut};

use magnus::{prelude::*, Error, Ruby, Value};
use yrs::{
    Doc, Origin, ReadTxn, Store, Transact, Transaction, TransactionAcqError, TransactionMut,
};

use crate::shared::ORIGIN;
use crate::{nogvl, yrb_error};

/// How long a wait sleeps between tries, in seconds.
const RETRY: f64 = 0.001;

/// A transaction a block holds open: its document and its fiber.
struct Held {
    doc: Doc,
    fiber: rb_sys::VALUE,
    txn: *mut TransactionMut<'static>,
}

thread_local! {
    static HELD: RefCell<Vec<Held>> = const { RefCell::new(Vec::new()) };
}

/// Who holds a block's transaction for a document, as this fiber sees it.
enum Holder {
    Nobody,
    ThisFiber(*mut TransactionMut<'static>),
    AnotherFiber,
}

fn current_fiber() -> rb_sys::VALUE {
    // SAFETY: called with the GVL held, from Ruby.
    unsafe { rb_sys::rb_fiber_current() }
}

fn holder(doc: &Doc) -> Holder {
    HELD.with(|held| {
        let held = held.borrow();
        // Most calls run outside any block: skip looking up the fiber.
        if held.is_empty() {
            return Holder::Nobody;
        }
        let fiber = current_fiber();
        let mut holder = Holder::Nobody;
        for h in held.iter().filter(|h| Doc::ptr_eq(&h.doc, doc)) {
            if h.fiber == fiber {
                return Holder::ThisFiber(h.txn);
            }
            holder = Holder::AnotherFiber;
        }
        holder
    })
}

/// Raises instead of opening a second transaction inside this fiber's
/// block, which would never get the lock.
fn refuse_held(doc: &Doc, what: &str) -> Result<(), Error> {
    if let Holder::ThisFiber(_) = holder(doc) {
        return Err(yrb_error(format!(
            "{what} can't run inside transact or edit on the same document"
        )));
    }
    Ok(())
}

/// Tries `attempt` until it gets the lock. Between tries it sleeps through
/// Ruby, which can interrupt it or run other fibers.
fn acquire<T>(
    doc: &Doc,
    mut attempt: impl FnMut() -> Result<T, TransactionAcqError>,
) -> Result<T, Error> {
    loop {
        match attempt() {
            Ok(txn) => return Ok(txn),
            Err(TransactionAcqError::DocumentDropped) => {
                return Err(yrb_error("the document was dropped".to_string()))
            }
            Err(_) => {}
        }
        // SAFETY: called with the GVL held, from Ruby.
        let scheduler = unsafe { rb_sys::rb_fiber_scheduler_current() };
        if matches!(holder(doc), Holder::AnotherFiber) && scheduler == rb_sys::Qnil as rb_sys::VALUE
        {
            return Err(yrb_error(
                "another fiber on this thread holds the document in transact or edit, \
                 and without a fiber scheduler it can't run while this one waits"
                    .to_string(),
            ));
        }
        let ruby = Ruby::get().map_err(|e| yrb_error(e.to_string()))?;
        let _: Value = ruby.module_kernel().funcall("sleep", (RETRY,))?;
    }
}

/// A read transaction: the block's, or one of its own.
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

/// A write transaction: the block's, or one of its own that commits when
/// it's dropped.
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

// SAFETY: a transaction moves only into a `nogvl` closure, which runs on
// the thread that opened it.
unsafe impl Send for Reader<'_> {}
unsafe impl Send for Writer<'_> {}

/// A transaction to read `doc` with. Call with the GVL held, then move it
/// into `nogvl` to do the work.
pub fn read(doc: &Doc) -> Result<Reader<'_>, Error> {
    match holder(doc) {
        // SAFETY: the held transaction lives until its block returns, and
        // this fiber is inside that block. A reader never outlives the
        // native call that made it.
        Holder::ThisFiber(txn) => Ok(Reader::Held(unsafe { &*txn.cast::<TransactionMut<'_>>() })),
        _ => acquire(doc, || doc.try_transact()).map(Reader::Own),
    }
}

/// A transaction to write `doc` with. Writes carry the handle origin.
pub fn write(doc: &Doc) -> Result<Writer<'_>, Error> {
    match holder(doc) {
        // SAFETY: as in `read`. One native call makes one writer at a time,
        // and nothing else on this fiber runs until it returns.
        Holder::ThisFiber(txn) => Ok(Writer::Held(unsafe {
            &mut *txn.cast::<TransactionMut<'_>>()
        })),
        _ => acquire(doc, || doc.try_transact_mut_with(ORIGIN)).map(Writer::Own),
    }
}

/// A transaction of its own for applying a remote update, under `origin`
/// if one is given. `what` names the call in the error inside a block.
pub fn apply<'a>(
    doc: &'a Doc,
    origin: Option<Origin>,
    what: &str,
) -> Result<TransactionMut<'a>, Error> {
    refuse_held(doc, what)?;
    acquire(doc, || match &origin {
        Some(origin) => doc.try_transact_mut_with(origin.clone()),
        None => doc.try_transact_mut(),
    })
}

/// A write transaction held open while a Ruby block runs.
struct Hold {
    // Declared before `_doc` so it drops (commits) first.
    txn: Option<Box<TransactionMut<'static>>>,
    _doc: Box<Doc>,
    _fiber: Pinned,
}

impl Hold {
    /// Waits for the document, then holds a write transaction open for this
    /// fiber.
    fn open(doc: &Doc) -> Result<Hold, Error> {
        let owned = Box::new(doc.clone());
        // SAFETY: the box keeps the document at one address for as long as
        // the transaction that borrows it, which drops first.
        let borrowed: &'static Doc = unsafe { &*(&*owned as *const Doc) };
        let txn = Box::new(acquire(doc, || borrowed.try_transact_mut_with(ORIGIN))?);
        let fiber = current_fiber();
        let mut hold = Hold {
            txn: Some(txn),
            _doc: owned,
            _fiber: Pinned::new(fiber),
        };
        let ptr: *mut TransactionMut<'static> = &mut **hold.txn.as_mut().unwrap();
        HELD.with(|held| {
            held.borrow_mut().push(Held {
                doc: doc.clone(),
                fiber,
                txn: ptr,
            })
        });
        Ok(hold)
    }

    /// The update this transaction has made so far, or nil for none.
    fn update(&self) -> Option<Vec<u8>> {
        let txn = self.txn.as_ref().unwrap();
        let update = txn.encode_update_v1();
        // An update with no structs and no deletions encodes as [0, 0].
        (update != [0, 0]).then_some(update)
    }
}

/// Keeps a fiber alive and in place while the registry names it: the GC
/// treats a registered address as a root it can't move.
struct Pinned(Box<rb_sys::VALUE>);

impl Pinned {
    fn new(value: rb_sys::VALUE) -> Pinned {
        let mut pinned = Pinned(Box::new(value));
        // SAFETY: the box outlives the registration, which drop removes.
        unsafe { rb_sys::rb_gc_register_address(&mut *pinned.0) };
        pinned
    }
}

impl Drop for Pinned {
    fn drop(&mut self) {
        // SAFETY: registered in `new`, with the GVL held as here.
        unsafe { rb_sys::rb_gc_unregister_address(&mut *self.0) };
    }
}

/// Moves a value into and out of a `nogvl` closure. The closure runs on the
/// calling thread, so nothing actually crosses threads.
struct OnThisThread<T>(T);
unsafe impl<T> Send for OnThisThread<T> {}

impl Drop for Hold {
    fn drop(&mut self) {
        let ptr: *const TransactionMut<'static> = &**self.txn.as_ref().unwrap();
        HELD.with(|held| held.borrow_mut().retain(|h| !std::ptr::eq(h.txn, ptr)));
        // Committing runs observers and merges blocks, without the GVL.
        let txn = OnThisThread(self.txn.take());
        nogvl(move || drop(txn));
    }
}

/// A document, or a handle on one: what `transact` runs on.
pub trait OnDoc {
    fn doc(&self) -> &Doc;
}

/// `transact` for a document and each handle: runs the caller's block with a
/// write transaction held open for the document, and commits when it returns
/// or raises. Inside a block of this fiber's for the document, it just runs
/// the block.
pub fn transact<T: OnDoc>(ruby: &Ruby, rb_self: &T) -> Result<Value, Error> {
    let doc = rb_self.doc();
    let block = ruby.block_proc()?;
    if let Holder::ThisFiber(_) = holder(doc) {
        return block.call(());
    }
    let hold = Hold::open(doc)?;
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
    let hold = Hold::open(doc)?;
    let result = block.call::<_, Value>(());
    let update = hold.update();
    drop(hold);
    result.map(|_| update)
}
