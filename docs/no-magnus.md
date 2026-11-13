# Moving yrby's native extension off magnus

Spike, November 2026, branch `spike/no-magnus`. The question: can yrby's Ruby
binding drop magnus and bind Rust the way Marco Roth's gems do, and is it
worth it?

**Short answer:** yes, it works, and it's worth doing in stages, but not
for speed. The ported slice passes the same 298 tests as a magnus build of
the same slice. It builds 18% faster clean on all cores and 31% faster with
two jobs, and its binary is 5% smaller. Per-call cost is the same within
noise, and so is memory. The case for moving is robustness. The C build
drops bindgen and libclang, which broke yrby's build twice this year. It
also cross-builds for 32-bit ARM Linux, which magnus can't, and for both
Windows targets (linked, not yet loaded there). And no Ruby exception ever jumps over a Rust frame. The cost
is about two-thirds more binding code, written by hand, and some of it in C.

## How Marco Roth binds Rust into Ruby

Read from the source of his Rust-backed gems as of 2026-11-11: `oxc-ruby`,
`lightningcss-ruby`, `rolldown-ruby`, `tsrs-ruby` and `yerba` (all MIT,
© Marco Roth). Herb itself is a C library with a C extension; these gems are
the Rust side of the same ecosystem. All five use the same pattern:

1. **A Rust crate with a C ABI.** `rust/` is a normal crate,
   `crate-type = ["cdylib", "staticlib", "rlib"]`, whose public surface is
   `#[no_mangle] pub unsafe extern "C" fn` items. Data crosses as C strings
   (options in as JSON, results out as JSON or text) plus a `#[repr(C)]`
   result struct holding a value pointer, a length, an error message and an
   error code. Rust allocates results; a `*_free` function releases them. No
   magnus, no rb-sys, no Ruby types in Rust at all.
2. **A cbindgen header.** `build.rs` runs `cbindgen` on every build and
   writes `ext/<gem>/include/<gem>.h`.
3. **A hand-written C extension.** `ext/<gem>/<gem>.c` (130 to 260 lines;
   `yerba.c` is 1,370) includes `ruby.h` and the generated header, defines the
   classes and methods with `rb_define_*`, calls the Rust functions, turns
   results into Ruby strings, maps error codes to exception classes, and
   frees. Stateful objects (`Yerba::Document`, `Tsrs` sessions) are
   `TypedData` wrapping an opaque Rust pointer with a `dfree` that calls the
   Rust free. Long calls run under `rb_thread_call_without_gvl`. Panics are
   caught with `catch_unwind` in Rust and returned as an error code.
4. **A plain mkmf `extconf.rb`.** It shells out to `cargo build --release
   --locked` (with `--target` when cross-compiling), appends the staticlib to
   `$LDFLAGS`, and calls `create_makefile`. When installing from a source gem
   it copies the `.a` next to the extension and deletes `target/`.
5. **Precompiled gems per platform.** `rake-compiler` plus
   `rake-compiler-dock`, using rb-sys's Docker images (`rbsys/<platform>`)
   only as a cross toolchain. The Rust staticlib is built once per platform;
   only the C file is compiled per Ruby version. The matrix is 8 platforms
   (aarch64/x86_64/arm Linux gnu and musl, arm64/x86_64 Darwin) plus the
   source gem. No Windows. `rb_sys` appears only in the Gemfile, for the image
   version, never as a runtime dependency. Publishing is trusted publishing
   from a GitHub release.
6. **Release profile:** `lto = "fat"`, `codegen-units = 1`,
   `strip = "symbols"`, `panic = "unwind"`. (On this Mac, cargo's strip step
   can produce a binary dyld won't load; see Numbers.)

His `rake-cross-compiler` (Zig instead of Docker) exists but none of these
gems use it.

Two details in his C glue that yrby can't copy as is. `StringValueCStr` is
fine for source text, but yrs updates are binary and contain NUL bytes, so
yrby passes pointer and length. And he hands a mutable Ruby string's pointer
to code running without the GVL; another thread could change the string
meanwhile. The spike passes a frozen view instead (below).

## What the spike built

`ext/yrby_c/` ports a slice of the extension to that pattern, behind the same
Ruby API:

- `Y::Doc`: `new`, `client_id`, `encode_state_vector`,
  `encode_state_as_update`, `apply_update`, `root_names`, `read_text`,
  `read_xml`, `read_map`, `read_array`, `pending?`, `compacted_state_update`,
  `update_ready?`, `update_advances?`, `sync_step1`, `handle_sync_message`,
  `get_text`, and the private `native_take_unsent`/`native_keep_unsent` that
  `Doc#edit` uses.
- `Y::Text`: `to_s`, `<<`/`push`, `insert`, `delete`, `clear`,
  `length`/`size`, `empty?` (not `relative_position`/`index_at`).
- `Y.wrap_update`, `Y.message_kind`, `Y.update_from_message`, `Y::Error`,
  the `MSG_*` constants.

Not ported: `Y::Map`, `Y::Array`, `Y::XmlText`, `Y::Awareness`, the Lexical
and ProseMirror renderers, anchors (`block_at`, `find`), and
`apply_update_changes`.

Files:

- `ext/yrby_c/ffi/` is the Rust crate (`staticlib`). It includes
  `ext/yrby/src/protocol.rs` and `read.rs` unchanged through `#[path]`, and a
  copy of the magnus-free part of `shared.rs`. Every function takes one
  `YrbyArgs` (handle, input pointer and length, two integers) and returns one
  `YrbyResult` (status, integer, owned bytes). One signature means one GVL
  trampoline on the C side.
- `ext/yrby_c/include/yrby_ffi.h` is generated by cbindgen and checked in.
  cbindgen runs only with `cargo build --features header`, so a gem install
  doesn't compile it.
- `ext/yrby_c/yrby_c.c` is the C extension.
- `ext/yrby_c/extconf.rb` runs `cargo build --locked` and links the
  staticlib. It exports only `Init_yrby_c`, drops unused sections, and on
  mingw names the system libraries the Rust std needs.
- `rake spike:compile_c` builds `lib/y/yrby_c.bundle`; `YRBY_NATIVE=c` makes
  `require "y"` load it instead of the magnus build.

It keeps the magnus build's runtime contract:

- **GVL.** Every call the magnus build runs in `nogvl` goes through one C
  `call()`: `rb_nogvl(..., RB_NOGVL_INTR_FAIL)`, run with the GVL held if an
  interrupt was already pending, then `rb_thread_check_ints()` after. In C a
  Ruby exception can't skip a destructor, so this is simpler than the Rust
  version. The only rule is to free Rust memory before anything raises.
- **Interrupts during `Doc#edit`.** `native_take_unsent` checks interrupts
  under `rb_protect` and, if one is pending, puts the merged update back
  before re-raising, as the magnus build does.
- **Inputs.** The bytes Rust reads can't change or move while the GVL is
  released. A frozen argument crosses as is. An unfrozen one up to 1 KB is
  copied to the C stack. A larger one crosses as `rb_str_new_frozen`'s
  copy-on-write view, so it isn't copied. The magnus build copies every input
  into a `Vec`.
- **Panics.** Every `extern "C"` function runs under `catch_unwind` and returns
  a status. Panics become `Y::Error`.
- **GC.** Nothing in yrby's Rust holds a Ruby object. Handles hold a
  `yrs::Doc` (an `Arc`) and a branch id. So `TypedData` with a `dfree` is
  enough: no `dmark`, no compaction concerns. This is what usually makes C
  bindings painful, and yrby doesn't have it.
- **Strings.** Binary results are ASCII-8BIT and text results UTF-8. Text
  arguments follow magnus's `String` conversion: UTF-8 or US-ASCII with valid
  bytes, or 7-bit binary, cross as is; anything else is transcoded to UTF-8,
  and if that fails it raises `EncodingError` with magnus's messages.
- **Construction.** `Y::Doc.new` is a singleton method with no allocator, as
  in the magnus build, so there is no `allocate`, `dup` or re-`initialize`
  of an empty Doc. The client id converts as magnus's `u64` does.

## Tests

yrby's Ruby suite ran file by file (`bench/no_magnus/run_tests.sh`) against
three builds. File by file it is 509 runs: `collaborative_edit_test` and
`collaborative_attribute_test` require `document_channel_test`, so its 28
tests run three times. The full `rake test` run is 468 tests, and it passes
in full on the magnus build with the spike's loader change.

| build | pass | fail or error |
|---|---|---|
| magnus, whole extension | 509 | 0 |
| magnus, cut to the spike's slice (`make_magnus_slice.rb`) | 298 | 211 |
| C ABI, the spike's slice | 298 | 211 |

The two slice builds match file by file. Every one of the 211 fails on API
outside the slice: `get_xml_text` (74), `Y::Awareness` (40), `get_map` (39),
the renderers (34), `get_array` (21), `Text#relative_position` (3). None
fails on a behaviour difference. Files that only touch the slice pass in
full, among them `sync_test`, `doc_test`, `doc_edit_test`'s Text cases,
`text_test`, `pending_test`, `interop_test` (Yjs fixtures), `robustness_test`,
`codec_test`, `document_channel_test`, `fiber_scheduler_test` and
`encrypted_document_test`.

Two test files (`collaborative_grant_test`, `collaborative_helper_test`)
only load inside the full `rake test` run (they need ActiveSupport loaded by
an earlier file). They are excluded from all three rows alike.

`thread_safety_test`'s interrupt tests use `Y::Map`, so
`bench/no_magnus/slice_interrupt_test.rb` repeats them on `Y::Text`, plus an
interrupt during `native_take_unsent` (the update must come back) and an input
string another thread keeps replacing during `apply_update`. All four pass on
all three builds.

The Rust unit tests (`cargo test` in `ext/yrby`) are unchanged; the spike
didn't port them.

## Review

A separate review of the C build looked for memory-safety, GVL and idiom
problems, by reading and by running stress tests. It found nothing critical
or high. These held up on reading and under 4-thread stress with
`GC.compact` running alongside, and under `GC.stress` with large and
transcoded inputs:

- input strings while the GVL is released (stack copy or frozen view);
- each result buffer freed once, by Rust's allocator;
- no use after free of a Doc or Text;
- no Ruby API without the GVL;
- no Ruby exception or longjmp across a Rust frame.

Fixed after the review:

- **Text encoding (medium).** `rb_str_export_to_enc` returns the original
  string when it can't transcode, and Rust then took the bytes if they
  happened to be valid UTF-8. Binary `"\xC3\xA9".b`, malformed UTF-16LE and
  US-ASCII with high bytes were all accepted where magnus raises
  `EncodingError`, and broken UTF-8 raised `Y::Error` instead. Now the
  check is magnus's, in C.
- **Interrupt order (low).** An error result raised `Y::Error` before a
  pending interrupt; magnus lets the interrupt go first. Now `check()` runs
  `rb_thread_check_ints()` before raising.
- **`Y::Doc.new` (low).** `new(nil)` was accepted and `new("5")` raised
  `NoMethodError`; `allocate` and `dup` gave an empty Doc; re-entering
  `initialize` could leak one. Now it matches magnus (see Strings and
  Construction above).
- **`get_text` leak on allocation failure (low).** The Ruby wrapper is now
  made before Rust hands over the Text.

`bench/no_magnus/behavior_diff.rb` prints these edge cases for both builds
to diff. Two differences remain, both deliberate: `Y::Text.new` raises in
C (magnus returns an empty handle) and `encode_state_as_update` with two
arguments raises `ArgumentError` (magnus ignores the second).

Still open, to fix before the C build ships:

- **Other leaks on raise.** `take_string`, `check`, `root_names` and
  `take_unsent` can leak a Rust buffer if Ruby allocation itself raises
  (`NoMemoryError` only). `take_unsent` would also lose the unsent updates.
  Fix with `rb_protect` around the conversion.
- **32-bit `long` on Windows.** Results over 2 GiB are cast to `long`. Check
  `r.len <= LONG_MAX` before converting.
- **Panics.** Every panic becomes `Y::Error`, on Doc methods too (magnus
  turns those into `fatal`). A panic mid-transaction still commits on drop,
  as with magnus's `guarded`. Pin `panic = "unwind"` in `Cargo.toml` so an
  abort profile can't silently change this.
- **extconf and packaging.** The `cargo --version > /dev/null` check fails
  under Windows `cmd.exe`. `make` doesn't rebuild when the Rust changes. The
  gemspec glob would not ship `yrby_c.c`, `yrby_ffi.h` or `Cargo.lock`.
- **Header drift.** Nothing checks the checked-in header against the Rust
  signatures; a mismatch is silent undefined behaviour. CI should regenerate
  it and `git diff --exit-code`.
- **Tests.** `gc_stress.rb` only sends inputs under 1 KB, and the
  "replaced input" interrupt test writes identical bytes, so neither covers
  what it's meant to. `gc_stress_large.rb`, `thread_stress.rb` and
  `mutate_input.rb` cover those paths; fold them into the suite when the C
  build becomes the main one.
- **Nits.** Mark both types `RUBY_TYPED_WB_PROTECTED`, typed opaque handles
  in the header, `rust-version` in `Cargo.toml`, and the copied `shared.rs`
  that can drift from the original.

## Numbers

All on the Mac mini (Apple M5 Pro, 18 cores), Ruby 3.4.7, rustc 1.96.1,
yrs 0.28.1, release builds. The registry was fetched first, so no build
includes downloads. Every benchmark prints the path, size and SHA-256 of the
binary it loaded.

"magnus slice" is yrby's magnus extension cut to the same slice by
`bench/no_magnus/make_magnus_slice.rb`, so it is the same Rust code with the
same dependencies, minus the renderer crates. Comparing it with the C slice
isolates the binding layer. "magnus full" is today's extension.

**Clean build** (`build_times.sh`, 3 runs each, seconds, median):

| profile, jobs | magnus full | magnus slice | C slice | C vs slice |
|---|---|---|---|---|
| default, 18 | 8.1 | 6.6 | 5.4 | -18% |
| default, 2 | 19.2 | 16.1 | 11.2 | -31% |
| LTO fat, 18 | 15.2 | 11.5 | 9.8 | -15% |
| LTO fat, 2 | 21.8 | 18.0 | 12.6 | -30% |

Most of the gap is the 25 crates only the magnus build compiles: bindgen,
clang-sys, rb-sys, rb-sys-build, magnus, magnus-macros, regex, nom and friends
(60 crates against 35). Two jobs is closer to a source install on a small
machine or CI runner, where the critical path matters more.

**Incremental build** (touch one file and rebuild, seconds):

| profile | magnus full, `lib.rs` | magnus slice, `lib.rs` | C slice, Rust side | C slice, C side |
|---|---|---|---|---|
| default | 2.6 | 1.0 | 1.1 | 0.4 to 0.6 |
| LTO fat | 9.2 | 5.6 | 5.4 | 0.5 |

Editing Rust costs the same either way. Editing only the C glue skips cargo
work entirely. The full extension's 2.6s is its size, not magnus.

**Binary size** (`sizes.sh`, bytes after `strip -x`):

| profile | magnus full | magnus slice | C slice |
|---|---|---|---|
| default | 1,766,640 | 1,152,352 | 1,084,240 (-6%) |
| LTO fat | 1,500,128 | 952,512 | 901,136 (-5%) |

Linking a staticlib by hand exports every Rust symbol unless told otherwise.
The first arm-linux build exported 2,647 symbols and was 2.46 MB. The
extconf now exports only `Init_yrby_c` and garbage-collects sections, as
rustc does for a cdylib. The same arm build is then 1.10 MB with one export.

**Call overhead** (`call_overhead.rb`, LTO builds, best of 7, ns per call,
two runs agreed within 2%):

| case | magnus full | magnus slice | C slice |
|---|---|---|---|
| `client_id` (no GVL release; pure binding cost) | 32 | 32 | 27 |
| `Y.message_kind` (GVL released, tiny work) | 300 | 300 | 293 |
| `encode_state_vector` | 355 | 354 | 349 |
| `read_text`, 1k chars | 440 | 440 | 415 |
| `apply_update`, one-char updates | 7,830 | 7,840 | 7,850 to 8,020 |
| `Text#<<` one char | 7,700 | 7,690 | 7,700 to 7,880 |
| `Doc#edit { Text#<< }` | 8,460 | 8,460 | 8,450 to 8,620 |
| apply a 20k-char state | 23,700 | 24,800 | 23,600 |

The binding itself costs about 5 ns less per call in C. Real calls are
dominated by yrs, and the builds land within 2% of each other, which is about
the variance between two LTO builds of the same code. The first C version was
20 ns slower on `message_kind`. It made a frozen shared copy of every
unfrozen argument, and allocating that object cost more than magnus's
`Vec` copy. Copying small unfrozen inputs to the stack fixed it.

**Memory:** RSS growth for 10,000 docs with a little text was 23.4 to 23.9 MB
in every build, and RSS at the end 101 to 104 MB. No difference.

**Cross-compiling** (`cross.sh`, rake-compiler-dock 1.10.0 images, which have
arm64 variants, so they run natively here; time-boxed):

| platform | magnus today | C slice |
|---|---|---|
| `arm-linux-gnu` (armv7) | not built: magnus doesn't compile | builds and links; 1 export; glibc 2.30 floor |
| `x64-mingw-ucrt` | shipped | builds and links; imports ucrt only (no msvcrt) and `x64-ucrt-ruby340.dll`, the same set as the 0.9.1 magnus gem; 1 export |
| `aarch64-mingw-ucrt` | shipped | builds and links (`aarch64-pc-windows-gnullvm`); ucrt; 1 export |

None were loaded on their real platform. The arm/v7 Ruby container needs
qemu binfmt in the Docker VM, which this Mac doesn't have, and there is no
Windows machine here. Windows needed two fixes. The C `enum` names `BOOL`
and `INT` collide with `windows.h`. And the Rust std's system libraries
(`ntdll`, `userenv`, `ws2_32`, `dbghelp`) have to be named, since only rustc
adds them automatically. Linux and macOS needed neither.

**A toolchain bug on this Mac, not magnus.** macOS 27's `strip` sometimes
writes the symbol string table at a 4-byte offset, and dyld then refuses the
binary ("mis-aligned LINKEDIT string pool"). cargo's default release profile
runs it (`strip = "debuginfo"`). With it, today's magnus build fails to load
here, and the LTO magnus slice too. `CARGO_PROFILE_RELEASE_STRIP=none` fixed
every case. All numbers above are from builds that loaded (the benchmark
prints the binary's path and hash). The C build links the staticlib itself
and never runs cargo's strip.

## Why leave magnus, item by item

What magnus and rb-sys cost yrby, from yrby's own history and this spike:

- **Build breakage from the toolchain, not from yrby.** rb-sys runs bindgen
  against the Ruby headers through libclang on every build, so a new libclang
  or a new Ruby can break the build with no yrby change. It has, twice this
  year. Ruby 4.0 changed `RTypedData` and magnus 0.7 stopped compiling
  (33a8353, June: upgrade to 0.8 and port the deprecated calls). Then
  ubuntu-latest moved to 26.04, whose libclang 22 makes bindgen 0.69 name a
  union differently, and magnus 0.8.2 stopped compiling until rb-sys 0.9.130
  (d19b44e, 2a5ddf9, November). The same thing happens to anyone installing
  the source gem on a new distro. The C build has no bindgen. It needs a C
  compiler and cargo, and the Ruby C API it calls is the stable one.
- **Platforms.** `cross-gem.yml` skips `arm-linux` and `arm-linux-musl`
  because magnus doesn't compile there (timespec bitfields). Marco's gems
  ship both with this pattern. The spike's C build cross-compiles and links
  for `arm-linux-gnu` (not load-tested; see Numbers).
- **Exceptions across Rust frames.** A Ruby raise is a longjmp. Through
  magnus it can jump over Rust frames and skip their destructors, which is
  why `nogvl` grew `RB_NOGVL_INTR_FAIL` and a manual interrupt check (5031e5e).
  In the C build no Rust frame is ever on the stack when Ruby raises: Rust
  returns a status, and C raises afterwards. That whole class of bug goes.
- **Build time.** 15 to 31% faster clean, by not compiling bindgen, rb-sys
  and magnus. Incremental Rust edits are the same.
- **Binary size.** 5 to 6% smaller.
- **Call overhead.** No meaningful difference (about 5 ns per call in C's
  favour, invisible next to yrs's work).
- **Dependencies.** The gemspec's runtime dependency on the `rb_sys` gem
  goes, and so do 25 crates.
- **Precompiled gem CI.** With rb-sys the Rust crate compiles once per Ruby
  version per platform (the 0.9.1 run compiled yrs twice on x86_64-linux, 26s
  then 16s). With a staticlib it compiles once per platform and only the C
  file per Ruby version. A small saving, since each job takes 135 to 175s,
  mostly Docker.
- **Debuggability.** Mixed. The C side is plain C that lldb and ASan handle
  well, and the boundary is a header you can read. But a mistake in the C
  file is a segfault, where magnus would have given a type error.

What magnus gives that the C build has to do by hand:

- argument conversion and type errors (`TryConvert`), arity checks,
  `Obj<Self>` for returning self;
- the `TypedData` boilerplate (`#[magnus::wrap]`);
- converting Ruby Hashes and Arrays to Rust values. The slice didn't need
  this, but `Map#[]=`, `Array#push`, `XmlText#insert` with attributes, the
  awareness states and the renderers' output do. Each needs either a C
  converter or a serialized form across the boundary (JSON, as Marco does,
  or a small binary encoding);
- calling back into Ruby (block-yielding `each`, the renderers' callback
  rules) is more code in C.

## What gets harder

- **Two languages and a header.** Every method is a Rust `extern "C"`
  function, a C wrapper and a registration line. The slice took 804 lines of
  binding code (350 C, 454 Rust) against 481 with magnus (code lines, no comments or blanks).
  The generic trampoline keeps the C wrappers to a few lines each, but
  conversions are by hand.
- **Unsafe on both sides.** C has no borrow checker: freeing a result twice,
  forgetting `RB_GC_GUARD`, or raising while Rust owns a buffer are all easy.
  The rules are few and the spike follows them in one place (`call`,
  `finish`, `check`), but review has to know them.
- **Structured values.** The handles that take and return Hashes and Arrays
  (`Y::Map`, `Y::Array`, `Y::XmlText`, `Y::Awareness`) are about half of
  the remaining binding. The C side either walks Ruby collections itself
  or sends JSON across. JSON costs a parse on each side; walking costs C.
- **Callbacks.** The render rules accept Ruby callables. Calling Ruby from
  inside Rust means a C function pointer into Ruby with the GVL held, and
  catching Ruby exceptions with `rb_protect` so they never cross Rust. None
  of Marco's gems calls back into Ruby, so there is no prior art to copy.
- **GC marking.** Not needed today: no Rust object holds a Ruby object. If
  that changes (say, a Ruby proc stored on a handle), each such type needs a
  `dmark` and compaction support by hand.
- **Windows.** yrby ships `x64-mingw-ucrt` and `aarch64-mingw-ucrt`, and
  Marco's gems don't ship Windows, so there was no recipe to copy. The spike
  cross-builds both. They link against ucrt and Ruby's DLL, as the magnus
  gem does, but they haven't been loaded on Windows. Until a Windows CI job
  requires one, Windows is the biggest remaining risk.

## Recommendation

**Move, in stages, when there's room for it. It isn't urgent.**

Speed doesn't justify it: build and binary gains are real but modest, and
call cost is a wash. Robustness does. Twice this year magnus or rb-sys broke
yrby's build for reasons outside yrby, and each time a source install on a
new system would have broken the same way. The C-ABI design has no bindgen
and needs only a C compiler and cargo. It cross-built for every platform the
spike tried, including both Windows targets and 32-bit ARM Linux (linked; not
yet loaded on those platforms). It also removes a class of bug (Ruby raising across Rust
frames) that yrby has already paid for once.

The price is roughly two-thirds more binding code, two languages per method, and
unsafe C that review has to watch. The spike keeps that contained: one GVL
trampoline, one result conversion, one error path, no GC marking. But the
structured-value handles (`Map`, `Array`, `XmlText`, `Awareness`) and the
renderer callbacks are where most of the remaining work and risk are, and
the spike didn't touch them.

Not a permanent hybrid. Two bindings means two sets of glue, and magnus's
build costs stay. A hybrid only makes sense while migrating, behind
`YRBY_NATIVE`, as the plan below does.

If the C isn't worth taking on: stay on magnus, and cut the risk it
brings by pinning rb-sys in `Cargo.lock` and testing new Ruby and libclang
releases in a scheduled CI job.

## Migration plan

Each step lands on its own, with both builds loadable side by side
(`YRBY_NATIVE=c`) and the whole test suite run against both, until the last.

1. **Prove the platforms first.** The spike already cross-builds for
   `arm-linux-gnu`, `x64-mingw-ucrt` and `aarch64-mingw-ucrt`
   (`bench/no_magnus/cross.sh`). Add a CI job that builds the slice for every
   platform yrby ships plus `arm-linux` and `arm-linux-musl`, and loads it
   and runs the slice's tests on `windows-latest`, `ubuntu-latest` (x86_64
   and arm64), macOS, and an armv7 container under qemu. Windows loading is
   the gate: if it fails, stop here.
2. **Make the pure Rust code magnus-free.** Split `shared.rs` into the pure
   half (origins, identity, index maths, value types) and the conversion half.
   Move the remaining logic out of the `impl Rb*` blocks into plain functions
   over `yrs::Doc` and branch ids, as `protocol.rs` and `read.rs` already are.
   This helps the magnus build too, and it is most of the work.
3. **Pick the value encoding for Hashes and Arrays.** Options: walk Ruby
   values in C, or encode them in C as lib0 `Any` (the format yrs already
   decodes with `Any::decode`) and decode on the other side. lib0 keeps
   types JSON loses (binary, integers versus floats) and needs only a small C
   encoder and decoder. Nested shared types (a Map inside a Map) come back as
   handles, so they need their own tag either way.
4. **Port by class:** `Text` (done), then `Map`, `Array`, `XmlText` with
   anchors and `apply_update_changes`, then `Awareness`, then the two
   renderers with callback rules (`rb_protect` around the Ruby call, so no
   Ruby exception crosses Rust).
5. **Move the Rust tests.** Handle tests that embed Ruby through
   `rb-sys-test-helpers` become tests of the `extern "C"` functions, or of the
   plain functions from step 2, with no Ruby at all. The Ruby suite covers the
   C side.
6. **Switch.** Make `ext/yrby_c` the extension (`spec.extensions`), drop
   magnus and rb-sys from `Cargo.toml`, and drop the `rb_sys` runtime
   dependency from the gemspec (source installs no longer need the rb_sys gem
   or libclang). Replace `oxidize-rb/actions/cross-gem` with rake-compiler-dock
   tasks like Marco's: cargo once per platform, the C file per Ruby version.
   Add the two ARM platforms.
7. **Release** as a minor version with no API change, after a beta and the
   same smoke tests the precompiled gems get today.

Rough size: the magnus binding is 2,228 code lines (no tests, comments or
blank lines, not counting `protocol.rs` and `read.rs`). The slice took 481 of
them, which leaves about 1,750. At the spike's ratio (804 for 481) that is
about 2,900 lines of C and `extern "C"` Rust, less what step 2 moves into
shared plain functions.

## Reproducing

```sh
bundle exec rake compile                    # magnus build -> lib/y/yrby.bundle
bundle exec rake spike:compile_c            # C build      -> lib/y/yrby_c.bundle
ruby bench/no_magnus/make_magnus_slice.rb   # magnus build of the same slice -> tmp/magnus_slice

bench/no_magnus/run_tests.sh OUT            # each test file, magnus build
YRBY_NATIVE=c bench/no_magnus/run_tests.sh OUT
YRBY_NATIVE=c bundle exec ruby -Ilib -Itest bench/no_magnus/slice_interrupt_test.rb
bench/no_magnus/build_times.sh 2            # clean and incremental build times (TSV)
bench/no_magnus/sizes.sh                    # after building all three
bench/no_magnus/call_overhead_all.sh        # all three builds
YRBY_NATIVE=c bundle exec ruby bench/no_magnus/gc_stress.rb
YRBY_NATIVE=c bundle exec ruby bench/no_magnus/gc_stress_large.rb
YRBY_NATIVE=c bundle exec ruby bench/no_magnus/thread_stress.rb      # SECS=20
YRBY_NATIVE=c bundle exec ruby bench/no_magnus/mutate_input.rb
YRBY_NATIVE=c bundle exec ruby bench/no_magnus/interrupt_order.rb
bundle exec ruby bench/no_magnus/behavior_diff.rb > m.txt           # then YRBY_NATIVE=c, and diff
bench/no_magnus/cross.sh x64-mingw-ucrt x86_64-pc-windows-gnu   # needs Docker
```

On this Mac, build the magnus extension with
`CARGO_PROFILE_RELEASE_STRIP=none` or it may not load (see Numbers).
