# Fail-closed boot checks for production. A misconfigured public demo is worse
# than one that won't start, so these raise at boot rather than degrade quietly.
#
# They run in production only. Development, test, and the local e2e (which boots
# without RAILS_ENV=production) stay permissive so the app works wherever it
# lands. The checks live in a module method so they can be unit-tested without
# booting a production process.
module ProductionBootChecks
  # The value config/anycable.yml falls back to outside production.
  DEV_ANYCABLE_SECRET = "yrby-site-development-secret".freeze
  MIN_SECRET_LENGTH = 32

  class << self
    # Returns a list of human-readable problems with the given environment. Empty
    # means safe to boot.
    def problems(env = ENV)
      [secret_problem(env["ANYCABLE_SECRET"]), origins_problem(env["ALLOWED_ORIGINS"])].compact
    end

    # The AnyCable secret configures both halves of the cable, and the HTTP RPC
    # endpoint (/_anycable) authenticates callers with a bearer derived from it.
    # A weak or default value lets anyone reading the repo forge RPC calls, past
    # the Go socket boundary, the origin check, and every limit.
    def secret_problem(secret)
      secret = secret.to_s
      if secret.empty?
        "ANYCABLE_SECRET is not set"
      elsif secret == DEV_ANYCABLE_SECRET
        "ANYCABLE_SECRET is the committed development default"
      elsif secret.length < MIN_SECRET_LENGTH
        "ANYCABLE_SECRET is too short (#{secret.length} chars; use at least " \
          "#{MIN_SECRET_LENGTH}, e.g. `openssl rand -hex 32`)"
      end
    end

    # With ALLOWED_ORIGINS unset, Rails disables request-forgery protection on
    # the cable and anycable-go does no origin check, so any page anywhere can
    # open a socket to this cable in a visitor's browser (cross-site WebSocket
    # hijacking). Production must name its origins — including a plain-http LAN
    # box, whose own origin belongs in the list.
    def origins_problem(raw)
      origins = raw.to_s.split(",").map(&:strip).reject(&:empty?)
      "ALLOWED_ORIGINS is not set" if origins.empty?
    end
  end
end

if Rails.env.production?
  problems = ProductionBootChecks.problems
  unless problems.empty?
    abort <<~MSG
      FATAL: production is misconfigured and will not boot:
      #{problems.map { |p| "  - #{p}" }.join("\n")}

      Set a strong AnyCable secret (openssl rand -hex 32) and the WebSocket origin
      allow-list (ALLOWED_ORIGINS=https://your-host, or http://<lan-ip>:<port> for
      a plain-http box). See config/limits.rb and site/README.md.
    MSG
  end
end
