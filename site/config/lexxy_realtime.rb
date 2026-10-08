# Loads lexxy-realtime without its engine. The gem is require: false because
# its engine loads Lexxy's engine, which needs Action Text (see the Gemfile).
# The model concern works on its own. It checks for has_rich_text, and without
# Action Text it saves the HTML that Y::Lexxy renders to the model's plain
# column. The gem's channel loads from the gem's app/channels, which
# config/application.rb adds to the load paths.
require "concurrent/map"
require "lexxy_realtime/collaborative"

# lib/lexxy_realtime.rb defines these next to its engine require, so this app
# defines them itself, with the same bodies. The concern calls
# first_sighting_of_unknown_types? when a document has a node type with no
# render rule, and LexxyRealtime::DocumentChannel calls grant_purpose when a
# client subscribes to it by name.
module LexxyRealtime
  @unknown_types_seen = Concurrent::Map.new

  def self.grant_purpose(name) = "lexxy_realtime/#{name}"

  def self.first_sighting_of_unknown_types?(key) = @unknown_types_seen.put_if_absent(key, true).nil?
end
