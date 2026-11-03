//! Tells Ruby's GC how much memory the extension holds.
//!
//! Ruby frees a dropped document only when its GC runs, and it runs the GC
//! sooner the more memory it knows about. Without this, a document holding
//! tens of megabytes looks to Ruby like a small object, so dropped documents
//! pile up. Each thread adds up its own allocations and reports them once
//! they pass `BATCH`, the way Ruby batches its own: reporting every
//! allocation makes threads contend on Ruby's shared counter.

use rb_sys::tracking_allocator::TrackingAllocator;
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

const BATCH: isize = 64 * 1024;

thread_local! {
    // Const-initialized with no destructor, so the allocator can use it
    // without allocating.
    static UNREPORTED: Cell<isize> = const { Cell::new(0) };
}

fn record(delta: isize) {
    // Fails only while the thread is exiting; that change goes unreported.
    let _ = UNREPORTED.try_with(|unreported| {
        let total = unreported.get() + delta;
        if total.abs() >= BATCH {
            // Ruby updates its counter without the GVL and starts no GC
            // here; this is a no-op before the VM starts.
            TrackingAllocator::adjust_memory_usage(total);
            unreported.set(0);
        } else {
            unreported.set(total);
        }
    });
}

struct Reporting;

unsafe impl GlobalAlloc for Reporting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            record(layout.size() as isize);
        }
        ptr
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc_zeroed(layout);
        if !ptr.is_null() {
            record(layout.size() as isize);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        record(-(layout.size() as isize));
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new = System.realloc(ptr, layout, new_size);
        if !new.is_null() {
            record(new_size as isize - layout.size() as isize);
        }
        new
    }
}

#[global_allocator]
static ALLOCATOR: Reporting = Reporting;

#[cfg(test)]
mod tests {
    use super::BATCH;
    use magnus::{Ruby, Value};
    use rb_sys_test_helpers::ruby_test;

    fn malloc_increase(ruby: &Ruby) -> isize {
        ruby.eval("GC.stat(:malloc_increase_bytes)").unwrap()
    }

    #[ruby_test]
    fn ruby_counts_what_the_extension_allocates() {
        let ruby = Ruby::get().unwrap();
        let _: Value = ruby.eval("GC.disable").unwrap();
        let before = malloc_increase(&ruby);
        let held = std::hint::black_box(vec![1u8; 1 << 20]);
        let grew = malloc_increase(&ruby) - before;
        drop(held);
        let _: Value = ruby.eval("GC.enable").unwrap();
        assert!(grew >= (1 << 20) - BATCH, "Ruby counted {grew} bytes");
    }
}
