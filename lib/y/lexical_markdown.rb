# frozen_string_literal: true

module Y
  class Lexical
    # The subset of Markdown a model writes: headings, paragraphs, bulleted
    # and numbered lists, quotes, fenced code, and inline bold, italic, code,
    # and links. Appended as Lexical blocks, so model output arrives looking
    # like what a person would have typed.
    module Markdown
      HEADING = /\A(\#{1,6})\s+(.*)\z/
      BULLET = /\A[-*]\s+(.*)\z/
      NUMBERED = /\A\d+[.)]\s+(.*)\z/
      QUOTE = /\A>\s?(.*)\z/
      FENCE = /\A```\s*(\S*)\s*\z/
      INLINE = /(\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|(?<![*\w])\*([^*]+)\*(?!\w)|(?<!\w)_([^_]+)_(?!\w))/

      module_function

      # Append `markdown` to `doc` through `flavor` (Y::Lexical or Y::Lexxy).
      def append(flavor, doc, markdown, root: "root")
        blocks(markdown.to_s).each do |kind, payload, extra|
          case kind
          when :heading then flavor.append_heading(doc, runs(payload), tag: "h#{extra}", root: root)
          when :paragraph then flavor.append_paragraph(doc, runs(payload), root: root)
          when :quote then flavor.append_quote(doc, runs(payload), root: root)
          when :code then flavor.append_code(doc, payload, language: extra, root: root)
          when :list then flavor.append_list(doc, payload.map { |line| runs(line) }, ordered: extra, root: root)
          end
        end
      end

      # Lines into [kind, payload, extra] blocks.
      def blocks(text)
        parser = Blocks.new
        text.each_line(chomp: true) { |line| parser.feed(line) }
        parser.finish
      end

      # A line-by-line parser. Prose lines gather into a paragraph and list
      # lines into a list until something else ends them; a fence gathers
      # lines verbatim until it closes.
      class Blocks
        def initialize
          @out = []
          @para = []
          @list = nil
          @fence = nil
        end

        def feed(line)
          return fenced(line) if @fence

          if (m = FENCE.match(line)) then open_fence(m[1])
          elsif (m = HEADING.match(line)) then block(:heading, m[2], m[1].length)
          elsif (m = BULLET.match(line)) then item(m[1], ordered: false)
          elsif (m = NUMBERED.match(line)) then item(m[1], ordered: true)
          elsif (m = QUOTE.match(line)) then block(:quote, m[1])
          elsif line.strip.empty? then close_all
          else
            close_list
            @para << line.strip
          end
        end

        def finish
          close_fence if @fence
          close_all
          @out
        end

        private

        def fenced(line)
          return close_fence if line.start_with?("```")

          @fence[:lines] << line
        end

        def open_fence(lang)
          close_all
          @fence = { lang: lang.empty? ? "plain" : lang, lines: [] }
        end

        def close_fence
          @out << [:code, @fence[:lines].join("\n"), @fence[:lang]]
          @fence = nil
        end

        def block(kind, payload, extra = nil)
          close_all
          @out << [kind, payload, extra]
        end

        def item(payload, ordered:)
          close_para
          close_list if @list && @list[:ordered] != ordered
          (@list ||= { ordered: ordered, items: [] })[:items] << payload
        end

        def close_para
          @out << [:paragraph, @para.join(" ")] unless @para.empty?
          @para = []
        end

        def close_list
          @out << [:list, @list[:items], @list[:ordered]] if @list
          @list = nil
        end

        def close_all
          close_para
          close_list
        end
      end

      # Inline markdown into runs: strings and { text:, bold:/italic:/code:/link: }.
      def runs(line)
        out = []
        rest = line
        while (m = INLINE.match(rest))
          out << m.pre_match unless m.pre_match.empty?
          out << if m[2] then { text: m[2], bold: true }
                 elsif m[3] then { text: m[3], code: true }
                 elsif m[4] then { text: m[4], link: m[5] }
                 else { text: m[6] || m[7], italic: true }
                 end
          rest = m.post_match
        end
        out << rest unless rest.empty?
        out
      end
    end

    # Append a subset of Markdown as Lexical blocks. Call it on the flavor that
    # matches the editor (`Y::Lexxy.append_markdown` for a Lexxy editor).
    def self.append_markdown(doc, markdown, root: "root")
      Markdown.append(self, doc, markdown, root: root)
    end
  end
end
