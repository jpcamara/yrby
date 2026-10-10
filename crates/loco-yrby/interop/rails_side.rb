# frozen_string_literal: true

# The Rails side of the Rails <-> Loco storage interop test
# (tests/rails_interop.rs). It uses yrby-rails' own models and migration
# template, so what it writes and reads is exactly what a Rails app would.
#
#   ruby rails_side.rb migrate            # yrby:tables' migration, as shipped
#   ruby rails_side.rb append  docs.json  # [{key, encrypted, updates: [base64]}]
#   ruby rails_side.rb read    docs.json  # [{key, encrypted}] -> {key: text}
#   ruby rails_side.rb compact docs.json  # Rails compaction of each document
#   ruby rails_side.rb inspect docs.json  # {key: {encrypted_values, plain_values}}
#
# DATABASE_URL picks the database (a SQLite path or a postgres:// URL).
# AR_PRIMARY_KEY, AR_KEY_DERIVATION_SALT, and AR_HASH_DIGEST configure Active
# Record encryption; COMPACT_EVERY sets Y::Document.compact_every.
require "json"
require "base64"
require "erb"
require "active_record"
require "y"

repo = File.expand_path("../../..", __dir__)
%w[document document_update encrypted_document encrypted_document_update].each do |model|
  require File.join(repo, "app/models/y/#{model}")
end

url = ENV.fetch("DATABASE_URL")
if url.start_with?("postgres")
  ActiveRecord::Base.establish_connection(url)
else
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: url)
end
ActiveRecord::Encryption.configure(
  primary_key: ENV.fetch("AR_PRIMARY_KEY"),
  deterministic_key: "unused-deterministic-key-for-interop",
  key_derivation_salt: ENV.fetch("AR_KEY_DERIVATION_SALT"),
  hash_digest_class: ENV.fetch("AR_HASH_DIGEST", "SHA256") == "SHA1" ? OpenSSL::Digest::SHA1 : OpenSSL::Digest::SHA256
)
Y::Document.compact_every = Integer(ENV.fetch("COMPACT_EVERY", "64"))

def model(doc) = doc["encrypted"] ? Y::EncryptedDocument : Y::Document

def text(state)
  return "" unless state

  doc = Y::Doc.new
  doc.apply_update(state)
  doc.read_text("content")
end

command, file = ARGV
docs = file ? JSON.parse(File.read(file)) : []

case command
when "migrate"
  template = File.read(File.join(repo, "lib/generators/yrby/tables/templates/create_y_tables.rb"))
  migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
  eval(ERB.new(template).result(binding)) # rubocop:disable Security/Eval -- our own template
  ActiveRecord::Migration.verbose = false
  CreateYTables.migrate(:up)
when "append"
  docs.each do |doc|
    doc["updates"].each { |update| model(doc).append(doc["key"], Base64.strict_decode64(update)) }
  end
when "read"
  puts JSON.dump(docs.to_h { |doc| [doc["key"], text(model(doc).load_state(doc["key"]))] })
when "compact"
  docs.each { |doc| model(doc).locate(doc["key"]).compact! }
when "inspect"
  encryptor = ActiveRecord::Encryption.encryptor
  result = docs.to_h do |doc|
    row = Y::Document.locate(doc["key"])
    values = [row.state, *Y::DocumentUpdate.where(document_id: row.id).pluck(:payload)].compact
    encrypted = values.count { |value| encryptor.encrypted?(value) }
    [doc["key"], { "encrypted_values" => encrypted, "plain_values" => values.size - encrypted }]
  end
  puts JSON.dump(result)
else
  abort "unknown command #{command.inspect}"
end
