# frozen_string_literal: true

require "json"

module Y
  # Renders a Trix document kept in a `Y.Text` (the y-trix binding's format)
  # to the HTML Trix itself saves, with no browser.
  #
  #   Y::Trix.new(doc).to_html            # the root named "trix"
  #   Y::Trix.new(doc).to_html("body")    # another root
  #
  # The format: text runs carry Trix's text attributes (bold, italic, strike,
  # href); an attachment is an embed `{ "attachment" => {...} }`; and every
  # block ends in a "\n" whose attributes say `blockBreak: true` and, under
  # `block`, the block's attributes in order (["quote", "bulletList",
  # "bullet"]). A "\n" without blockBreak is a line break inside a block.
  #
  # The document can come from anyone who can write to it, so nothing in it is
  # trusted: text is escaped, only the attributes Trix knows are read, and
  # links and images keep only URLs a browser would not run. The HTML of a
  # content attachment is left out unless you pass `content:`, a callable
  # that takes the stored HTML and returns HTML that is safe to show:
  #
  #   Y::Trix.new(doc, content: ->(html) { sanitize(html) }).to_html
  class Trix
    DEFAULT_ROOT = "trix"

    BLOCKS = {
      "quote" => { tag: "blockquote" },
      "heading1" => { tag: "h1", group: false },
      "code" => { tag: "pre", html: ["language"], plaintext: true },
      "bulletList" => { tag: "ul" },
      "bullet" => { tag: "li", group: false },
      "numberList" => { tag: "ol" },
      "number" => { tag: "li", group: false },
      "attachmentGallery" => { tag: "div", group: false }
    }.freeze
    LISTS = %w[bulletList numberList].freeze
    MARKS = { "bold" => "strong", "italic" => "em", "strike" => "del" }.freeze
    PREVIEWABLE = %r{\Aimage(/(gif|png|webp|jpe?g)|\z)}
    SIZES = %w[Bytes KB MB GB TB PB].freeze
    NBSP = "\u00A0"
    BAD_EMBED = "\uFFFD"
    PIECE_STRINGS = %w[caption presentation].freeze
    URL_KEYS = %w[url href previewURL].freeze
    STRING_KEYS = %w[content contentType filename alt].freeze
    NUMBER_KEYS = %w[filesize width height].freeze
    # What DOMPurify, which Trix uses, lets through as a link or a source.
    SAFE_URL = /\A(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|\z))/i
    URL_NOISE = /[\u0000-\u0020\u00A0\u1680\u180E\u2000-\u2029\u205F\u3000]/
    RTL = /\p{Hebrew}|\p{Arabic}|\p{Syriac}|\p{Thaana}|\p{Nko}/
    STRONG = /\p{L}/

    Piece = Struct.new(:string, :attachment, :attrs)
    Block = Struct.new(:pieces, :attributes, :html) do
      def text = pieces.map { |piece| piece.attachment ? "\uFFFC" : piece.string }.join
      def empty? = pieces.empty?

      def direction
        @direction ||= begin
          first = text[STRONG]
          first && RTL.match?(first) ? "rtl" : "ltr"
        end
      end
    end
    Group = Struct.new(:objects, :depth)

    # `doc` is a Y::Doc. `content:` renders the HTML of content attachments
    # (see the class comment); without it they keep their frame and caption
    # and show nothing inside.
    def initialize(doc, content: nil)
      @doc = doc
      @content = content
    end

    # The document's HTML, or nil when the doc has no such text root.
    def to_html(root = DEFAULT_ROOT)
      json = @doc.read_text_delta(root.to_s)
      json && self.class.render(JSON.parse(json), content: @content)
    end

    # Renders a delta that is already parsed: an array of
    # `{ "insert" => ..., "attributes" => {...} }`, as `read_text_delta` and
    # Yjs's `toDelta()` give it.
    def self.render(delta, content: nil)
      new(nil, content: content).render(delta)
    end

    def render(delta)
      blocks = blocks_of(delta)
      return "" if blocks.empty? || (blocks.size == 1 && blocks[0].empty? && blocks[0].attributes.empty?)

      group(blocks, 0).map { |object| render_object(object) }.join
    end

    private

    # ---- the delta, as Trix's blocks of pieces ------------------------------

    def blocks_of(delta)
      blocks = []
      pieces = []
      Array(delta).each do |op|
        next unless op.is_a?(Hash)

        attrs = op["attributes"].is_a?(Hash) ? op["attributes"] : {}
        insert = op["insert"]
        if insert.is_a?(String) && attrs["blockBreak"] == true
          # (one "\n" each: equal breaks in a row come as one run)
          insert.each_char do |char|
            next add_text(pieces, char, attrs) unless char == "\n"

            blocks << Block.new(pieces, block_attributes(attrs["block"]), attrs["html"])
            pieces = []
          end
        elsif insert.is_a?(String) then add_text(pieces, insert, attrs)
        elsif !insert.nil? then add_embed(pieces, insert, attrs)
        end
      end
      # (text after the last block break: Trix would end it with one)
      blocks << Block.new(pieces, [], nil) unless pieces.empty?
      blocks
    end

    def add_embed(pieces, embed, attrs)
      attachment = clean_attachment(embed)
      return add_text(pieces, BAD_EMBED, {}) unless attachment

      pieces << Piece.new(nil, attachment, piece_attrs(attrs, attachment: true))
    end

    def add_text(pieces, string, attrs)
      string = string.gsub("\r\n", "\n").tr("\r", "\n")
      return if string.empty?

      attrs = piece_attrs(attrs)
      last = pieces.last
      if last && last.attachment.nil? && last.attrs == attrs
        last.string += string
      else
        pieces << Piece.new(+string, nil, attrs)
      end
    end

    # The text attributes Trix knows, by name, as it nests them. (y-trix
    # takes true, a string or a number as a format being on, so this does.)
    def piece_attrs(attrs, attachment: false)
      attrs.keys.sort.each_with_object({}) do |key, out|
        value = piece_value(key, attrs[key], attachment)
        out[key] = value unless value.nil?
      end
    end

    def piece_value(key, value, attachment)
      if MARKS.key?(key) then true if value == true || value.is_a?(String) || value.is_a?(Numeric)
      elsif key == "href" then value if value.is_a?(String) && safe_url?(value)
      elsif attachment && PIECE_STRINGS.include?(key) then value if value.is_a?(String)
      end
    end

    def block_attributes(block)
      return [] unless block.is_a?(::Array)

      block.select { |name| name.is_a?(String) && BLOCKS.key?(name) }
    end

    def clean_attachment(embed)
      return nil unless embed.is_a?(Hash) && embed["attachment"].is_a?(Hash)

      embed["attachment"].keys.sort.each_with_object({}) do |key, out|
        value = embed["attachment"][key]
        out[key] = value if attachment_value?(key, value)
      end
    end

    def attachment_value?(key, value)
      if URL_KEYS.include?(key) then value.is_a?(String) && safe_url?(value)
      elsif STRING_KEYS.include?(key) then value.is_a?(String)
      elsif NUMBER_KEYS.include?(key) then value.is_a?(Numeric) && value.finite?
      else value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end
    end

    def safe_url?(url)
      SAFE_URL.match?(url.gsub(URL_NOISE, ""))
    end

    # ---- blocks, grouped the way Trix groups them ---------------------------

    def group(blocks, depth)
      objects = []
      current = nil
      blocks.each do |block|
        if current
          if block.attributes[depth] && groups_with?(current.last, block, depth)
            current << block
            next
          end
          objects << Group.new(group(current, depth + 1), depth)
          current = nil
        end
        if block.attributes[depth]
          current = [block]
        else
          objects << block
        end
      end
      objects << Group.new(group(current, depth + 1), depth) if current
      objects
    end

    def groups_with?(block, other, depth)
      attribute = block.attributes[depth]
      return false unless attribute == other.attributes[depth]
      return false if BLOCKS[attribute][:group] == false && !LISTS.include?(other.attributes[depth + 1])

      block.direction == other.direction || other.empty?
    end

    def render_object(object)
      return render_block(object) unless object.is_a?(Group)

      first = object
      first = first.objects.first while first.is_a?(Group)
      open, close = container(first, object.depth)
      "#{open}#{object.objects.map { |child| render_object(child) }.join}#{close}"
    end

    def container(block, depth)
      name = block.attributes[depth]
      config = BLOCKS[name]
      attributes = +""
      if name == "attachmentGallery"
        attributes << %( class="attachment-gallery attachment-gallery--#{block.text.length}")
      end
      attributes << %( dir="rtl") if depth.zero? && block.direction == "rtl"
      if block.html.is_a?(Hash)
        block.html.keys.sort.each do |key|
          value = block.html[key]
          next unless Array(config[:html]).include?(key) && (value.is_a?(String) || value.is_a?(Numeric))

          attributes << %( #{key}="#{escape_attribute(value.to_s)}")
        end
      end
      ["<#{config[:tag]}#{attributes}>", "</#{config[:tag]}>"]
    end

    def render_block(block)
      inner =
        if block.empty?
          "<br>"
        else
          plaintext = BLOCKS.dig(block.attributes.last, :plaintext) == true
          html = render_text(block.pieces, plaintext)
          html << "<br>" if block.text.end_with?("\n")
          html
        end
      return inner unless block.attributes.empty?

      block.direction == "rtl" ? %(<div dir="rtl">#{inner}</div>) : "<div>#{inner}</div>"
    end

    # ---- the text of a block --------------------------------------------------

    # Pieces in a row with one href share one <a>, and what Trix decides by a
    # piece's place in the text (see spaces) it decides by the link's place.
    def render_text(pieces, plaintext)
      runs = pieces.chunk_while { |a, b| a.attrs["href"] && a.attrs["href"] == b.attrs["href"] }.to_a
      runs.each_with_index.map do |run, index|
        context = { first: index.zero?, last: index == runs.size - 1,
                    follows_whitespace: index.positive? && ends_in_whitespace?(runs[index - 1]) }
        inner = run.map { |piece| render_piece(piece, plaintext, context) }.join
        href = run[0].attrs["href"]
        href ? %(<a href="#{escape_attribute(href)}">#{inner}</a>) : inner
      end.join
    end

    # (Trix asks a link, not its text, and a link or an attachment is no whitespace)
    def ends_in_whitespace?(run)
      piece = run[0]
      run.size == 1 && piece.attrs["href"].nil? && piece.attachment.nil? && piece.string.match?(/\s\z/)
    end

    def render_piece(piece, plaintext, context)
      inner = piece.attachment ? render_attachment(piece) : render_string(piece.string, plaintext, context)
      tags = piece.attrs.keys.filter_map { |key| MARKS[key] }
      "#{tags.map { |tag| "<#{tag}>" }.join}#{inner}#{tags.reverse.map { |tag| "</#{tag}>" }.join}"
    end

    def render_string(string, plaintext, context)
      return escape_text(string) if plaintext

      string.split("\n", -1).each_with_index.map do |line, index|
        "#{"<br>" if index.positive?}#{escape_text(spaces(line, context)) unless line.empty?}"
      end.join
    end

    # Runs of spaces would collapse in HTML, so Trix alternates them with
    # no-break spaces, and keeps one at either end of the text.
    def spaces(string, context)
      string = string.sub(/ \z/, NBSP) if context[:last]
      string = string.gsub(/(\S) {3}(\S)/, "\\1 #{NBSP} \\2").gsub(/ {2}/, "#{NBSP} ").gsub(/ {2}/, " #{NBSP}")
      string = string.sub(/\A /, NBSP) if context[:first] || context[:follows_whitespace]
      string
    end

    # ---- attachments -----------------------------------------------------------

    def render_attachment(piece)
      attachment = piece.attachment
      content = attachment["content"]
      type = attachment_type(attachment)
      inner = +""
      if content
        inner << @content.call(content).to_s if @content
      elsif type == "preview"
        inner << image(attachment)
      end
      inner << caption(piece, type)
      href = attachment["href"]
      # (Trix leaves the link off when the content has one of its own)
      inner = %(<a href="#{escape_attribute(href)}">#{inner}</a>) if href && !content.to_s.match?(/<a[\s>]/i)
      "#{figure(piece, type)}#{inner}</figure>"
    end

    def figure(piece, type)
      attachment = piece.attachment
      classes = ["attachment", "attachment--#{type}"]
      extension = attachment["filename"].to_s[/\.(\w+)\z/, 1]
      classes << "attachment--#{extension.downcase}" if extension
      data = { "data-trix-attachment" => JSON.generate(attachment),
               "data-trix-content-type" => attachment.fetch("contentType", "undefined").to_s }
      data["data-trix-attributes"] = JSON.generate(piece.attrs) unless piece.attrs.empty?
      data["class"] = classes.join(" ")
      "<figure#{data.map { |name, value| %( #{name}="#{escape_attribute(value)}") }.join}>"
    end

    def attachment_type(attachment)
      return "content" if attachment.key?("content")

      previewable =
        if attachment.key?("previewable") then attachment["previewable"]
        else PREVIEWABLE.match?(attachment["contentType"].to_s)
        end
      previewable ? "preview" : "file"
    end

    def image(attachment)
      html = %(<img src="#{escape_attribute(attachment["url"].to_s)}")
      %w[width height alt].each do |name|
        html << %( #{name}="#{escape_attribute(attachment[name].to_s)}") unless attachment[name].nil?
      end
      html << ">"
    end

    def caption(piece, type)
      edited = piece.attrs["caption"]
      if edited && !edited.empty?
        klass = "attachment__caption attachment__caption--edited"
        return %(<figcaption class="#{klass}">#{escape_text(edited)}</figcaption>)
      end

      attachment = piece.attachment
      name = attachment["filename"].to_s if %w[preview file].include?(type)
      size = filesize(attachment["filesize"]) if %w[preview file].include?(type)
      parts = []
      parts << %(<span class="attachment__name">#{escape_text(name)}</span>) if name && !name.empty?
      parts << %(<span class="attachment__size">#{escape_text(size)}</span>) if size && !size.empty?
      %(<figcaption class="attachment__caption">#{parts.join(" ")}</figcaption>)
    end

    def filesize(number)
      return "" unless number.is_a?(Numeric)
      return "0 Bytes" if number.zero?
      return "1 Byte" if number == 1

      exponent = (Math.log(number) / Math.log(1024)).floor
      exponent = exponent.clamp(0, SIZES.size - 1)
      human = format("%.2f", number / (1024.0**exponent)).sub(/0*\z/, "").sub(/\.\z/, "")
      "#{human} #{SIZES[exponent]}"
    end

    # ---- escaping, as a browser serializes -------------------------------------

    def escape_text(string)
      string.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(NBSP, "&nbsp;")
    end

    def escape_attribute(string)
      string.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;").gsub(NBSP, "&nbsp;")
    end
  end
end
