# The HTTP side of "no uploads": every public route is a GET, so the app
# refuses any other method before routing, sessions, or body parsing run.
#
# - A multipart body (multipart/form-data, or any other multipart/ type) gets
#   415 on every path and method. Rack never parses it into a tempfile.
# - GET and HEAD go through.
# - The AnyCable RPC endpoint (/_anycable) goes through with any method. The
#   embedded anycable-go POSTs every cable command there with a JSON body.
#   Rack::Attack still checks its bearer token and answers an outside caller
#   with a 404 (see rack_attack.rb), so this gate doesn't open it up.
# - Everything else gets 405 with an Allow header.
#
# The site has no forms, no CSP report endpoint, and no other POST target.
# Anything that needs one has to be added here on purpose.
class MethodGate
  READ_METHODS = %w[GET HEAD].freeze
  # /_anycable and its command paths (/_anycable/connect, /command, ...).
  RPC_PATH = %r{\A/_anycable(?:/[a-z_]+)?\z}
  # Inviting the agent into a Lexxy room: a POST with no body. Rack::Attack
  # throttles it per IP and DemosController#agent checks the Origin.
  AGENT_INVITE = %r{\A/demos/lexxy/[A-Za-z0-9_-]+/agent\z}
  HEADERS = { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return refuse(415, "This site doesn't accept uploads.\n") if multipart?(env)
    return @app.call(env) if READ_METHODS.include?(env["REQUEST_METHOD"]) || rpc_path?(env["PATH_INFO"].to_s)
    return @app.call(env) if agent_invite?(env)

    refuse(405, "This site only serves GET and HEAD requests.\n", "allow" => "GET, HEAD")
  end

  private

  def multipart?(env) = env["CONTENT_TYPE"].to_s.strip.downcase.start_with?("multipart/")

  def rpc_path?(path) = RPC_PATH.match?(path)

  def agent_invite?(env)
    env["REQUEST_METHOD"] == "POST" && env["CONTENT_LENGTH"].to_i.zero? && AGENT_INVITE.match?(env["PATH_INFO"].to_s)
  end

  def refuse(status, body, extra = {})
    [status, HEADERS.merge(extra), [body]]
  end
end

# First in the stack, so a refused request costs nothing past this check.
Rails.application.config.middleware.insert_before 0, MethodGate
