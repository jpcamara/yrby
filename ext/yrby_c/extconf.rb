# frozen_string_literal: true

# Spike: build the Rust staticlib with cargo, then compile yrby_c.c with
# plain mkmf and link the staticlib in. The shape of Marco Roth's extconf
# (oxc-ruby, lightningcss-ruby, ...), cut to the native, non-cross case.
require "mkmf"

ffi_dir = File.expand_path("ffi", __dir__)
abort "yrby: the Rust toolchain is required (https://rustup.rs)" unless system("cargo --version > /dev/null 2>&1")

target = ENV.fetch("CARGO_BUILD_TARGET", nil)
# Outside ext/, so the gemspec's ext glob never packages it.
target_dir = ENV.fetch("CARGO_TARGET_DIR", File.expand_path("../../target/yrby_c", __dir__))
args = ["build", "--release", "--locked", "--manifest-path", File.join(ffi_dir, "Cargo.toml"), "--target-dir", target_dir]
args += ["--target", target] if target
system("cargo", *args) || abort("yrby: cargo build failed")

static_lib = File.join(target_dir, *[target, "release"].compact, "libyrby_ffi.a")
abort "yrby: #{static_lib} is missing" unless File.exist?(static_lib)

$INCFLAGS << " -I#{File.join(__dir__, "include")}"
$CFLAGS << " -std=c99 -Wall -Wextra -Wno-unused-parameter"
$LDFLAGS << " #{static_lib}"
# Export only the init function (rustc does this for a cdylib; linking a
# staticlib by hand doesn't) and let the linker drop unused Rust code.
if RUBY_PLATFORM.include?("darwin")
  $LDFLAGS << " -Wl,-exported_symbol,_Init_yrby_c -Wl,-dead_strip"
elsif RUBY_PLATFORM.match?(/mingw/)
  # What `cargo rustc -- --print native-static-libs` lists for windows-gnu.
  $LDFLAGS << " -Wl,--gc-sections"
  %w[kernel32 ntdll userenv ws2_32 dbghelp].each { |lib| $libs << " -l#{lib}" }
else
  $LDFLAGS << " -Wl,--exclude-libs,ALL -Wl,--gc-sections"
end
# On Linux the Rust std needs these; macOS gets them from libSystem.
%w[pthread dl m].each { |lib| have_library(lib) } unless RUBY_PLATFORM.include?("darwin")

create_makefile("y/yrby_c")
