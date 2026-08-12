# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "yrby"
gemspec name: "yrby-rails"

# Fiber scheduler used by test/fiber_scheduler_test.rb to drive the native
# extension inside an Async reactor (the server shape under Falcon).
gem "async"

# Test-only: the store and generator tests run on SQLite (activerecord and
# railties come in through the yrby-rails gemspec).
gem "sqlite3", require: false

gem "rubocop", require: false
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false
