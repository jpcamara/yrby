# Stops the boot if an upload framework is loaded, in every environment.
#
# Active Storage mounts direct-upload and blob routes and stores whatever it's
# given, and Action Text brings it along for attachments. config/application.rb
# requires only the frameworks this site needs, and the Gemfile doesn't list
# either one. Both gems are still in the lockfile, because lexxy-realtime
# depends on the rails meta-gem, so a later `require "rails/all"` or a gem
# that requires them would load them without any other sign. This makes that
# a failed boot instead of a public file host. See "No uploads" in README.md.
module NoUploadFrameworks
  FRAMEWORKS = {
    "ActiveStorage::Engine" => "Active Storage",
    "ActionText::Engine" => "Action Text"
  }.freeze

  # The upload frameworks that are loaded, by name. `loaded` answers whether a
  # constant is defined, so the tests can pass their own.
  def self.loaded(loaded = ->(name) { Object.const_defined?(name) })
    FRAMEWORKS.filter_map { |constant, name| name if loaded.call(constant) }
  end

  def self.check!(...)
    names = loaded(...)
    return if names.empty?

    raise <<~MSG
      #{names.join(" and ")} #{names.one? ? "is" : "are"} loaded, and this site accepts no uploads.
      Require only the frameworks the app uses in config/application.rb (no
      "rails/all"), and remove whatever requires #{names.join(" or ")}. See
      "No uploads" in site/README.md.
    MSG
  end
end

NoUploadFrameworks.check!
