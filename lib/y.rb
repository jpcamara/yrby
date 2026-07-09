# frozen_string_literal: true

require_relative "y/version"

# Load the native extension. Precompiled gems ship it in a per-Ruby-version
# subdir (lib/y/<major.minor>/yrby.<ext>); a source build puts it flat at
# lib/y/yrby.<ext>. Try the versioned path first, fall back.
begin
  RUBY_VERSION =~ /(\d+\.\d+)/
  require_relative "y/#{Regexp.last_match(1)}/yrby"
rescue LoadError
  require_relative "y/yrby"
end

require_relative "y/rendering"
require_relative "y/lexxy"

module Y
  # Doc, Error, and the protocol module functions are defined in the Rust
  # extension. The ActionCable integration (Y::ActionCable::Sync) lives in the
  # separate `yrby-actioncable` gem; require "y/action_cable".
end
