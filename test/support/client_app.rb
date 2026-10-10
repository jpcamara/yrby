# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "socket"
require "tmpdir"

# Starts test/client_app/app.rb once per run, a Rails app with the shipped
# Y::DocumentChannel, in a subprocess so it has a database of its own.
module ClientApp
  TOKEN = "agent-test-token"

  def self.port
    @port ||= begin
      dir = Dir.mktmpdir("yrby-client-app")
      port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
      env = { "PORT" => port.to_s, "CLIENT_APP_TOKEN" => TOKEN, "CLIENT_APP_DB" => File.join(dir, "app.sqlite3") }
      out = IO.popen(env, [RbConfig.ruby, File.expand_path("../client_app/app.rb", __dir__)], err: %i[child out])
      raise "client app did not start" unless out.each_line.any? { |line| line.strip == "ready" }

      Minitest.after_run do
        Process.kill("TERM", out.pid)
        Process.wait(out.pid)
        FileUtils.remove_entry(dir)
      end
      port
    end
  end

  def self.url = "ws://127.0.0.1:#{port}/cable"

  def self.get(path) = JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}#{path}")))

  def self.grant(name) = get("/grant/#{name}").fetch("grant")

  def self.headers(token = TOKEN) = { "Authorization" => "Bearer #{token}" }
end
