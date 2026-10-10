# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "yrby"
gemspec name: "yrby-rails"

# json 3.0 changed JSON.parse's signature, and ActiveSupport 8.1's
# JSON.decode still calls it with two arguments, so every signed-message
# read raises ArgumentError. This pin applies to development and CI only.
# The conflict is between two of our dependencies, and the published gems
# shouldn't force it on apps. Remove it once ActiveSupport ships a compatible
# release.
gem "json", "< 3"

# Fiber scheduler used by test/fiber_scheduler_test.rb to drive the native
# extension inside an Async reactor (the server shape under Falcon).
gem "async"

# Test-only: the store and generator tests run on SQLite (activerecord and
# railties come in through the yrby-rails gemspec).
gem "puma", require: false # runs the ActionCable server for the element browser tests
gem "sqlite3", require: false

gem "rubocop", require: false

# Y::ActionCable::Client speaks Action Cable over async-websocket. An app that
# uses the client adds this gem.
gem "async-websocket", require: false
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false
