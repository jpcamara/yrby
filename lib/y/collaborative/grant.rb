# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "active_support/security_utils"

module Y
  module Collaborative
    # The JWT form of a grant, the one loco-yrby (Rust) mints and verifies, so
    # a Rails app and a Loco app can hand each other's pages grants:
    #
    #   { "aud": "yrby", "sub": "Post/<public id>", "name": "body", "exp": 1790000000 }
    #
    # signed HS256 with a secret both apps share (config.yrby.grant_secret).
    # `sub` names the record by type and public id (see collaborative_public_id),
    # `name` is the attribute, as the signed GlobalID's purpose is, and `aud`
    # keeps a grant from passing for any other kind of token. A grant must
    # expire. Only HS256 is accepted, so an unsigned or differently signed
    # token never verifies.
    module Grant
      AUDIENCE = "yrby"
      HEADER = { "alg" => "HS256", "typ" => "JWT" }.freeze

      class << self
        def encode(subject:, name:, expires_at:, secret:)
          claims = { "aud" => AUDIENCE, "sub" => subject, "name" => name.to_s, "exp" => expires_at.to_i }
          body = "#{segment(HEADER)}.#{segment(claims)}"
          "#{body}.#{signature(body, secret)}"
        end

        # The token's subject, if it is an authentic, unexpired yrby grant for
        # `name`. Nil for anything else.
        def verify(token, name:, secret:)
          return nil unless jwt?(token) && secret && signed?(token, secret)

          header, claims = token.split(".").first(2).map { |segment| parse(segment) }
          return nil unless header.is_a?(Hash) && header["alg"] == "HS256"

          claims["sub"] if acceptable?(claims, name)
        end

        # Whether a token has a JWT's shape, so locate knows which kind to check.
        def jwt?(token)
          token.is_a?(String) && token.count(".") == 2
        end

        private

        def signed?(token, secret)
          body, _, signature = token.rpartition(".")
          ActiveSupport::SecurityUtils.secure_compare(signature(body, secret), signature)
        end

        def acceptable?(claims, name)
          claims.is_a?(Hash) && audience?(claims["aud"]) && claims["name"] == name.to_s &&
            claims["exp"].is_a?(Integer) && claims["exp"] > Time.now.to_i && claims["sub"].is_a?(String)
        end

        def segment(value) = Base64.urlsafe_encode64(JSON.generate(value), padding: false)

        def signature(body, secret)
          Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", secret, body), padding: false)
        end

        def parse(segment)
          JSON.parse(Base64.urlsafe_decode64(segment))
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def audience?(aud) = aud == AUDIENCE || (aud.is_a?(Array) && aud.include?(AUDIENCE))
      end
    end
  end
end
