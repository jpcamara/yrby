# frozen_string_literal: true

# Local-only browser fixture: real Rails, signed grants, SQLite and ActionCable.
# Started and stopped by packages/client/browser/run.mjs (Turbo) and
# run_turbolinks.mjs (BROWSER_FRAMEWORK=turbolinks). Never deploy this app.
ENV["RAILS_ENV"] = "test"
FRAMEWORK = ENV.fetch("BROWSER_FRAMEWORK", "turbo")
CLIENT_BUNDLE = FRAMEWORK == "turbolinks" ? "client_turbolinks.js" : "client.js"
CLIENT_SCRIPT = %(<script type="module" src="/assets/#{CLIENT_BUNDLE}" data-#{FRAMEWORK}-track="reload"></script>).freeze
$stdout.sync = true
ENV["DATABASE_URL"] ||= "sqlite3:#{File.expand_path("../../tmp/browser.sqlite3", __dir__)}"
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "action_cable/engine"
require "yrby-rails"
require "puma"
require "fileutils"

class BrowserApplication < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "yrby-browser-fixture-secret" * 4
  config.hosts = ["127.0.0.1", "localhost"]
  config.logger = Logger.new($stdout)
  config.log_level = :warn
  config.action_cable.mount_path = "/cable"
  config.action_cable.allowed_request_origins = [%r{\Ahttp://127\.0\.0\.1:\d+\z}]
  config.action_cable.cable = { "adapter" => "async" }
  config.active_record.encryption.primary_key = "browser-primary-key" * 2
  config.active_record.encryption.deterministic_key = "browser-deterministic-key" * 2
  config.active_record.encryption.key_derivation_salt = "browser-key-derivation-salt" * 2
end
BrowserApplication.initialize!
FileUtils.mkdir_p(File.expand_path("../../tmp", __dir__))
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :pages, force: true do |t|
    t.string :title
    t.string :body_editor, default: "editor"
  end
  create_table :y_documents, force: true do |t|
    t.string :key, null: false, index: { unique: true }
    t.references :record, polymorphic: true
    t.string :name
    t.binary :state
    t.timestamps
    t.index %i[record_type record_id name], unique: true
  end
  create_table :external_updates, force: true do |t|
    t.bigint :record_id, null: false
    t.string :name, null: false
    t.binary :payload, null: false
  end
  create_table :y_document_updates, force: true do |t|
    t.references :document, null: false
    t.binary :payload, null: false
    t.boolean :pending, null: false, default: false
    t.datetime :created_at, null: false
  end
end
class ExternalUpdate < ActiveRecord::Base
end

class BrowserStore
  def self.load(record, name)
    doc = Y::Doc.new
    ExternalUpdate.where(record_id: record.id, name: name).pluck(:payload).each { |update| doc.apply_update(update) }
    doc.encode_state_as_update
  end

  def self.write(record, name, update)
    ExternalUpdate.create!(record_id: record.id, name: name, payload: update)
  end
end

class Page < ActiveRecord::Base
  has_collaborative_document :secret, encrypted: true
  has_collaborative_document :external, storage: BrowserStore
end
Page.create!(id: 1, title: "Browser regression")

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = cookies.signed[:browser_user]
      reject_unauthorized_connection unless current_user
    end
  end
end

Y::DocumentChannel.authorize_document do |record, name|
  # Fixture policy: body is restricted; other fields let us prove denial does
  # not close unrelated subscriptions sharing the same socket.
  name != "body" || record.body_editor == current_user
end

class BrowserController < ActionController::Base
  def show
    # Test-only login and deliberate grant exposure for copied-grant tests.
    # This fixture is local-only and must never be deployed.
    cookies.signed[:browser_user] = params[:user].presence || "editor"
    @page = Page.find(1)
    render inline: <<~ERB, layout: false
      <!doctype html><html><head><title>yrby browser regression</title>
      <meta name="action-cable-url" content="/cable">
      <script>window.socketCount ??= 0; if (!window.socketCounting) { window.socketCounting = true;
      const Socket = window.WebSocket; window.WebSocket = class extends Socket {
        constructor(...args) { super(...args); window.socketCount++; }
      }; }</script>
      #{CLIENT_SCRIPT}
      </head><body><h1>Collaborative document</h1>
      <%= collaborative_document_tag @page, :body, id: "body-doc", refresh: "/grant?name=body", data: (params[:permanent].present? ? { "#{FRAMEWORK}-permanent" => true } : {}) do %>
        <label>Body <textarea aria-label="Body" disabled></textarea></label>
      <% end %>
      <%# A grant that expires almost at once, so a reconnect has to refresh it. %>
      <%= collaborative_document_tag @page, :notes, id: "notes-doc", expires_in: 2.seconds, refresh: "/grant?name=notes" do %>
        <label>Notes <textarea aria-label="Notes" disabled></textarea></label>
      <% end %>
      <%= collaborative_document_tag @page, :secret, id: "secret-doc" do %>
        <label>Encrypted text <textarea aria-label="Encrypted text" disabled></textarea></label>
      <% end %>
      <%= collaborative_document_tag @page, :external, id: "external-doc" do %>
        <label>Custom storage <textarea aria-label="Custom storage" disabled></textarea></label>
      <% end %>
      <p id="status">Loading</p><div id="move-target"></div>
      <a href="/away">Away</a></body></html>
    ERB
  end

  def away
    render html: <<~HTML.html_safe
      <!doctype html><html><head><title>Away</title>
      #{CLIENT_SCRIPT}
      </head><body><h1>Away</h1><a href="/">Editor</a></body></html>
    HTML
  end

  def state
    attribute = Page.find(1).collaborative_document(params[:name])
    if params[:name] == "external"
      render json: { text: attribute.y_doc.read_text("content"), storage: "BrowserStore",
                     built_in_rows: Y::Document.where(record: Page.find(1), name: "external").count }
    else
      document = attribute.collaborative_record
      raw = Y::DocumentUpdate.where(document_id: document.id).pick(:payload)
      render json: { text: attribute.y_doc.read_text("content"), storage: document.class.name,
                     raw_payload: raw && Base64.strict_encode64(raw) }
    end
  end

  def permission
    Page.find(1).update!(body_editor: params.require(:editor))
    head :no_content
  end

  # The refresh endpoint: the same rule the channel policy applies, re-run over
  # HTTP with the session cookie, then a fresh short-lived grant.
  def grant
    page = Page.find(1)
    name = params.require(:name)
    return head :forbidden unless name != "body" || page.body_editor == cookies.signed[:browser_user]

    render json: { grant: page.collaborative_sgid(name, expires_in: 2.seconds) }
  end

  def asset
    path = File.join(ENV.fetch("BROWSER_ASSETS"), File.basename(params[:file]))
    # Exercise the default async import, including simultaneous elements and
    # detach-before-ready. The delay is confined to this local test fixture.
    sleep 0.3 if File.basename(path).start_with?("actioncable")
    send_file path, type: "text/javascript", disposition: "inline"
  end
end
BrowserApplication.routes.draw do
  root to: "browser#show"
  get "/away", to: "browser#away"
  get "/state/:name", to: "browser#state"
  post "/permission", to: "browser#permission"
  get "/grant", to: "browser#grant"
  get "/favicon.ico", to: ->(_env) { [204, {}, []] }
  get "/assets/:file", to: "browser#asset", constraints: { file: %r{[^/]+} }
end
server = Puma::Server.new(BrowserApplication)
server.add_tcp_listener "127.0.0.1", Integer(ENV.fetch("PORT", "3789"))
trap("TERM") { server.stop }
server.run.join
