# frozen_string_literal: true

# A Rails app for the Ruby client's end-to-end test: the shipped
# Y::DocumentChannel, record-backed documents with signed grants, and a
# connection that authenticates a process by a bearer token. The test starts
# it as a subprocess and talks to it over HTTP and the cable.
ENV["RAILS_ENV"] = "test"
$stdout.sync = true
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"
require "yrby-rails"
require "puma"

TOKEN = ENV.fetch("CLIENT_APP_TOKEN")
ENV["DATABASE_URL"] = "sqlite3:#{ENV.fetch("CLIENT_APP_DB")}"

class ClientApplication < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.secret_key_base = "yrby-client-fixture-secret" * 4
  config.hosts = ["127.0.0.1"]
  config.logger = Logger.new($stdout)
  config.log_level = :warn
  config.action_cable.mount_path = "/cable"
  config.action_cable.allowed_request_origins = [%r{\Ahttp://127\.0\.0\.1:\d+\z}]
  config.action_cable.cable = { "adapter" => "async" }
end
ClientApplication.initialize!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :pages, force: true do |t|
    t.string :title
  end
  create_table :y_documents, force: true do |t|
    t.string :key, null: false, index: { unique: true }
    t.references :record, polymorphic: true
    t.string :name
    t.binary :state
    t.timestamps
    t.index %i[record_type record_id name], unique: true
  end
  create_table :y_document_updates, force: true do |t|
    t.references :document, null: false
    t.binary :payload, null: false
    t.boolean :pending, null: false, default: false
    t.datetime :created_at, null: false
  end
end

class Page < ActiveRecord::Base
end
Page.create!(id: 1, title: "Agent test")

module ApplicationCable
  # A process authenticates with a bearer token, the way an app might let
  # its own agents in. Anything else is turned away at connect.
  class Connection < ActionCable::Connection::Base
    identified_by :agent

    def connect
      self.agent = request.authorization == "Bearer #{TOKEN}" ? "agent" : reject_unauthorized_connection
    end
  end
end

class ClientController < ActionController::Base
  def grant
    render json: { grant: Page.find(1).collaborative_sgid(params.require(:name)) }
  end

  def text
    render json: { html: Y::Lexxy.new(Page.find(1).collaborative_document(params.require(:name)).y_doc).to_html("root") }
  end
end

ClientApplication.routes.draw do
  get "/grant/:name", to: "client#grant"
  get "/text/:name", to: "client#text"
end

server = Puma::Server.new(ClientApplication)
server.add_tcp_listener "127.0.0.1", Integer(ENV.fetch("PORT"))
trap("TERM") { server.stop }
puts "ready"
server.run.join
