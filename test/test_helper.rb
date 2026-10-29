# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "y"
require "minitest/autorun"

# The client and agent warn that they are experimental when loaded.
Warning[:experimental] = false
