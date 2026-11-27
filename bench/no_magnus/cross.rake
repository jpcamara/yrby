# frozen_string_literal: true

# Cross-compile the spike's C build inside a rake-compiler-dock image, as
# Marco's gems do (cargo for the target, then rake-compiler for the C file):
#   bench/no_magnus/cross.sh x64-mingw-ucrt x86_64-pc-windows-gnu
require "rake/extensiontask"

Rake::ExtensionTask.new("yrby_c") do |ext|
  ext.ext_dir = "ext/yrby_c"
  ext.lib_dir = "lib/y"
  ext.source_pattern = "*.{c,h}"
  ext.cross_compile = true
  ext.cross_platform = [ENV.fetch("RCD_PLATFORM")]
end
