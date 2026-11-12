# Keeps files out of Action Text. The site accepts no uploads, but the Lexxy
# demo's body is an Action Text field, and Action Text turns an
# <action-text-attachment> into a record lookup (a signed GlobalID), a remote
# image, or a blob. A client that skips the page can put any node it likes in
# the Yjs document, so the body is cleaned on the way in, whatever wrote it.
#
# - .strip removes attachment elements, Trix attachments, and media elements,
#   and drops any attribute that names a record (sgid, gid) or loads a file
#   (src, srcset, poster, a data: or blob: URL, a CSS url()).
# - RichTextBody runs .strip in ActionText::RichText#body=, so a rich text
#   never holds an attachment, even in memory before a save. Action Text finds
#   embeds in a before_validation callback, and by then there's none to find.
# - EditorTag replaces Lexxy's editor tag, which would render the direct
#   upload and blob URLs (routes this site doesn't draw) and look up the
#   body's attachments. It renders attachments="false" on every editor.
#
# config/initializers/no_uploads.rb installs both modules.
module NoAttachments
  # Elements that are a file or point at one. Action Text canonicalizes Trix
  # attachments (figure[data-trix-attachment]) to action-text-attachment
  # before this runs, and the selector covers both in case it didn't.
  FILE_ELEMENTS = "action-text-attachment, action-text-attachment-gallery, [data-trix-attachment], " \
                  "img, picture, video, audio, source, track, embed, object, iframe, frame, svg, math".freeze
  REFERENCE_ATTRIBUTES = %w[sgid gid src srcset poster data-trix-attachment].freeze

  class << self
    # Returns the HTML without attachments, as a string. nil stays nil.
    def strip(html)
      return if html.nil?

      html = html.to_html if html.is_a?(ActionText::Content)
      source = ActionText::Content.new(html.to_s).fragment.source
      source.css(FILE_ELEMENTS).each(&:remove)
      source.css("*").each do |element|
        element.attribute_nodes.each { |attribute| attribute.remove if file_reference?(attribute) }
      end
      source.to_html
    end

    private

    # Browsers ignore whitespace and control characters inside a URL scheme,
    # so "da\tta:" is a data: URL. CSS escapes can spell url( in a style.
    def file_reference?(attribute)
      return true if REFERENCE_ATTRIBUTES.include?(attribute.name.downcase)

      value = attribute.value.gsub(/[\x00-\x20]/, "").downcase
      value.start_with?("data:", "blob:") || value.include?("url(") ||
        (attribute.name.casecmp?("style") && value.include?("\\"))
    end
  end

  module RichTextBody
    def body=(value)
      super(NoAttachments.strip(value))
    end
  end

  module EditorTag
    UPLOAD_DATA = %w[direct_upload_url blob_url_template].freeze

    # Lexxy's lexxy_rich_textarea_tag, which collaborative_rich_textarea
    # calls, without the upload URLs or the attachment rendering. The value is
    # the stored HTML, which RichTextBody already cleaned.
    def lexxy_rich_textarea_tag(name, value = nil, options = {}, &)
      options = options.symbolize_keys
      value = value.body&.to_html if value.is_a?(ActionText::RichText)
      options[:name] ||= name
      options[:value] ||= value
      options[:class] ||= "lexxy-content"
      options[:attachments] = false
      options[:data] = options[:data].to_h.reject { |key, _| UPLOAD_DATA.include?(key.to_s.tr("-", "_")) }
      content_tag("lexxy-editor", "", options, &)
    end
  end
end
