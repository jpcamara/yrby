# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "yrby"
gemspec name: "yrby-rails"

# json 3.0 changed JSON.parse's signature, and ActiveSupport 8.1's
# JSON.decode still calls it with two arguments, so every signed-message
# read raises ArgumentError. Development and CI only: the incompatibility is
# between two of our dependencies, not something the published gems should
# constrain for an app. Drop this once ActiveSupport ships a compatible
# release.
gem "json", "< 3"

# Fiber scheduler used by test/fiber_scheduler_test.rb to drive the native
# extension inside an Async reactor (the server shape under Falcon).
gem "async"

# Test-only: the store and generator tests run on SQLite (activerecord and
# railties come in through the yrby-rails gemspec).
gem "puma", require: false # real ActionCable server for the element browser regression
gem "sqlite3", require: false

gem "rubocop", require: false
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false

# The websocket client (Y::ActionCable::Client) speaks Action Cable over
# socketry. Optional at runtime: an app that uses the client adds this gem.
gem "async-websocket", require: false
