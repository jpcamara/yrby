# Boot checks for production. A misconfigured public demo is worse than one
# that won't start, so these stop the boot.
#
# They run in production only. Development, test, and the local e2e (which
# boots without RAILS_ENV=production) skip them so the app runs anywhere. The
# checks are module methods so the tests can call them without booting a
# production process.
module ProductionBootChecks
  # The value config/anycable.yml falls back to outside production.
  DEV_ANYCABLE_SECRET = "yrby-site-development-secret".freeze
  MIN_SECRET_LENGTH = 32

  class << self
    # Returns a list of problems with the given environment, as messages. An
    # empty list means it's safe to boot.
    def problems(env = ENV)
      [secret_problem(env["ANYCABLE_SECRET"]), origins_problem(env["ALLOWED_ORIGINS"])].compact
    end

    # Both halves of the cable use the AnyCable secret, and the HTTP RPC
    # endpoint (/_anycable) authenticates callers with a bearer derived from it.
    # With a weak or default value, anyone who reads the repo could forge RPC
    # calls and skip the Go socket, the origin check, and every limit.
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

    # With ALLOWED_ORIGINS unset, Rails turns off request-forgery protection on
    # the cable and anycable-go doesn't check origins, so any page on the
    # internet could open a socket to this cable from a visitor's browser
    # (cross-site WebSocket hijacking). Production has to list its origins. A
    # plain-http LAN box lists its own origin too.
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
