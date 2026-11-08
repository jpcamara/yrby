# frozen_string_literal: true

# A Rage app with a yrby channel, for packages/client/rage/run.mjs. It's only
# for local test runs and must not be deployed.
require "bundler/setup"
require "rage"
# Loads yrby-rails, which requires y/rage because Rage is defined.
Bundler.require(*Rage.groups)
require "rage/all"

Rage.configure do
  config.logger = Rage::Logger.new($stdout)
  config.log_level = Logger::WARN
  config.server.workers_count = Integer(ENV.fetch("WORKERS", 1))
  # The Node clients send no Origin header, and Rage turns away a socket
  # without one.
  config.cable.disable_request_forgery_protection = true

  # The yrby-rails tables, as yrby:tables migrates them.
  config.after_initialize do
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :y_documents, if_not_exists: true do |t|
        t.string :key, null: false, index: { unique: true }
        t.references :record, polymorphic: true, null: true, index: false
        t.string :name
        t.binary :state
        t.timestamps
      end
      create_table :y_document_updates, if_not_exists: true do |t|
        t.references :document, null: false, index: false
        t.binary :payload, null: false
        t.boolean :pending, null: false, default: false
        t.datetime :created_at, null: false
        t.index %i[document_id pending]
      end
    end
  end
end

require "rage/setup"
