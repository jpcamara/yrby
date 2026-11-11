# frozen_string_literal: true

require_relative "y/version"

# Load the native extension. Precompiled gems ship it in a per-Ruby-version
# subdir (lib/y/<major.minor>/yrby.<ext>); a source build puts it flat at
# lib/y/yrby.<ext>. Try the versioned path first, fall back.
if ENV["YRBY_NATIVE"] == "c"
  # Spike (docs/no-magnus.md): the C-ABI build of a slice of the extension.
  require_relative "y/yrby_c"
elsif ENV["YRBY_NATIVE_PATH"]
  # Spike: any build at this path, e.g. tmp/magnus_slice/build/yrby.bundle.
  require File.expand_path(ENV["YRBY_NATIVE_PATH"])
else
  begin
    RUBY_VERSION =~ /(\d+\.\d+)/
    require_relative "y/#{Regexp.last_match(1)}/yrby"
  rescue LoadError
    require_relative "y/yrby"
  end
end

require_relative "y/rendering"
require_relative "y/lexxy"
require_relative "y/lexical_writer"
require_relative "y/lexical_markdown"
require_relative "y/anchor"
require_relative "y/xml_text"
require_relative "y/text"
require_relative "y/map"
require_relative "y/array"
require_relative "y/doc"
require_relative "y/tiptap"
require_relative "y/decoder"

module Y
  # Doc, Error, and the protocol module functions are defined in the Rust
  # extension. The ActionCable integration (Y::ActionCable::Sync) lives in the
  # `yrby-rails` gem; require "y/action_cable".
end
