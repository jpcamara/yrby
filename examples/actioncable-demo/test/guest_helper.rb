# frozen_string_literal: true

# The guest tests load the peers and the party without booting Rails: they
# need yrby, nothing of the app's.
#
#   bundle exec ruby -Itest test/guest_test.rb
#   bundle exec ruby -Itest test/guest_party_test.rb
require "minitest/autorun"
require "y"
require "json"
require "logger"
require "stringio"
require_relative "../app/lib/guest"

# A real Y document with a narrow cable seam, and a mind whose answers the
# test hands out one at a time. That is enough to time a reply against an
# edit exactly.
module GuestFixture
  class Peer
    attr_reader :doc, :presence, :unsubscribed

    def initialize
      @doc = Y::Doc.new
      @presence = Y::Awareness.new
    end

    def on_update(&block) = @on_update = block
    def on_awareness(&block) = @on_awareness = block
    def subscribe = self
    def unsubscribe = @unsubscribed = true
    def send_awareness(frame) = @presence.apply_update(frame)
    def send_update(update) = update && @on_update&.call(update, doc, [])

    # An edit from a browser: applied to the doc, then reported like the cable does.
    def human(&)
      update = doc.diff(&)
      @on_update&.call(update, doc, [])
    end

    def sign(id, text, left: 10, top: 10)
      human { |doc| doc.get_map("signs")[id] = { "x" => left, "y" => top, "text" => text } }
    end

    def retext(id, text) = human { |doc| doc.get_map("signs").get_map(id)["text"] = text }

    def move(id, left, top)
      human do |doc|
        sign = doc.get_map("signs").get_map(id)
        sign["x"] = left
        sign["y"] = top
      end
    end

    def unsign(id) = human { |doc| doc.get_map("signs").delete(id) }
    def person(frame) = @on_awareness&.call(frame)
    def state = presence.states.values.compact.find { |s| s["guest"] }
  end

  class Mind
    attr_reader :calls, :responses

    def initialize
      @calls = Queue.new
      @responses = Queue.new
    end

    def model = "test/jev"

    def call(persona:, signs:, current:, briefing: {})
      @calls << { persona: persona, signs: signs, current: current, briefing: briefing }
      response = @responses.pop
      raise response if response.is_a?(Exception)

      response
    end
  end

  PERSONA = Guest::Persona.new(name: "Snack Goblin", trait: "lives for free food", color: "#d97706", home: [60, 60],
                               personality: "lives for free food and will cross any room for a snack")
end
