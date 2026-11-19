# Installs the parts of "No uploads" (README.md) that live in Ruby, now that
# Action Text and Active Storage are loaded for the Lexxy demo's body.
#
# - Action Text's rich text strips attachments in its body writer, and Lexxy's
#   editor tag renders no upload URLs (app/lib/no_attachments.rb). The editor
#   module is prepended to Lexxy's own tag helper, so it sits in front of it
#   wherever Lexxy puts that (Lexxy prepends it to Action Text's in a
#   to_prepare block of its own).
# - Active Storage's records are read-only, so no blob, attachment, or variant
#   row can be written, whatever calls save. The tables exist because Action
#   Text's rich text declares `has_many_attached :embeds`. They stay empty.
# - The boot stops if Active Storage would draw its routes or use any service
#   other than the refusing one (config/application.rb, config/storage.yml).
Rails.application.config.to_prepare do
  ActionText::RichText.prepend(NoAttachments::RichTextBody)
  Lexxy::TagHelper.prepend(NoAttachments::EditorTag)

  [ActiveStorage::Blob, ActiveStorage::Attachment, ActiveStorage::VariantRecord].each do |model|
    model.define_method(:readonly?) { true }
  end
end

Rails.application.config.after_initialize do |app|
  unless app.config.active_storage.draw_routes == false &&
         ActiveStorage::Blob.service.is_a?(ActiveStorage::Service::RefusingService)
    raise "Active Storage must draw no routes and use the refusing service. See \"No uploads\" in site/README.md."
  end
end
