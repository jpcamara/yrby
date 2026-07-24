# frozen_string_literal: true

source "https://rubygems.org"

gemspec name: "yrby"
gemspec name: "yrby-rails"
gemspec name: "yrby-decoder"

gem "rake-compiler"
gem "rb_sys"

# Fiber scheduler used by test/fiber_scheduler_test.rb to drive the native
# extension inside an Async reactor (the server shape under Falcon).
gem "async"

# Generator + generated-store tests only (the gems themselves never depend
# on Rails beyond actioncable).
gem "activerecord", require: false
gem "railties", require: false
gem "sqlite3", require: false

gem "rubocop", require: false
gem "rubocop-minitest", require: false
gem "rubocop-rake", require: false
