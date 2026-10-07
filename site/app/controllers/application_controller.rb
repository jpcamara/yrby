class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  # The absolute base URL for canonical tags, the sitemap, Open Graph, JSON-LD,
  # and llms.txt. It comes from ENV because the request host varies behind
  # Cloudflare and on the plain-http LAN origin, and these tags need a single
  # host. The default is the placeholder from deploy.yml. Set CANONICAL_HOST to
  # the real domain before launch (see the README).
  CANONICAL_HOST = ENV.fetch("CANONICAL_HOST", "https://yrby.example.com").chomp("/").freeze

  helper_method :canonical_host, :canonical_url

  private

  def canonical_host = CANONICAL_HOST

  def canonical_url(path = request.path) = "#{CANONICAL_HOST}#{path}"
end
