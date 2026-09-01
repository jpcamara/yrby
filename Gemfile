# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "yrby"
gemspec name: "yrby-rails"
gemspec name: "yrby-forms"

# Fiber scheduler used by test/fiber_scheduler_test.rb to drive the native
# extension inside an Async reactor (the server shape under Falcon).
gem "async"

# Test-only: the store and generator tests run on SQLite (activerecord and
# railties come in through the yrby-rails gemspec).
gem "sqlite3", require: false

gem "rubocop", require: false
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false

# Test-only: the engine boot test runs the collaborative macros against real
# Action Text in a booted Rails app (test/support/collaborative_boot_check.rb).
gem "actiontext", require: false
