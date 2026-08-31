class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  # The absolute base URL for canonical tags, the sitemap, Open Graph, JSON-LD,
  # and llms.txt. ENV-driven, and deliberately not derived from the request:
  # Cloudflare and the plain-http Pi origin mean the request host varies, but
  # the canonical host must be one value. The default is the deploy.yml
  # placeholder — set CANONICAL_HOST to the real domain before launch (see the
  # README).
  CANONICAL_HOST = ENV.fetch("CANONICAL_HOST", "https://yrby.example.com").chomp("/").freeze

  helper_method :canonical_host, :canonical_url

  private

  def canonical_host = CANONICAL_HOST

  def canonical_url(path = request.path) = "#{CANONICAL_HOST}#{path}"
end
