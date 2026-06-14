# frozen_string_literal: true

require_relative "yrb_lite/version"
require_relative "yrb_lite/yrb_lite"
require_relative "yrb_lite/prosemirror_extractor"

module YrbLite
  # Error class is defined in Rust extension

  # Autoload Sync module - only loaded when ActionCable is available
  autoload :Sync, "yrb_lite/sync"
end
