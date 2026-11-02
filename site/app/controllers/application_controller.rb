class ApplicationController < ActionController::Base
  after_action :log_referrer

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

  # Thruster's request log has no Referer, so pages note where a visitor came
  # from. Only links from other sites: a click within the site isn't a source.
  def log_referrer
    return unless request.get? && response.media_type == "text/html"

    host = URI.parse(request.referer.to_s).host
    return if host.nil? || own_host?(host)

    logger.info "Referred from #{request.referer.truncate(200)} to #{request.path}"
  rescue URI::InvalidURIError
    nil
  end

  def own_host?(host)
    [request.host, URI.parse(CANONICAL_HOST).host].any? do |own|
      host.delete_prefix("www.") == own.delete_prefix("www.")
    end
  end
end
