# frozen_string_literal: true

module Y
  # Ruby-side conveniences over the native live handle.
  class XmlText
    # Insert a block with `attributes` before the `ordinal`-th embedded
    # block and return a live handle to it. A negative `ordinal` counts from
    # the end, so -1 adds it after the last. `content` is written into the
    # block in the same transaction, so no one sees the block before what it
    # holds. It is an Array of Strings (text), Hashes (embeds, such as the
    # marker Lexical puts before a text node's characters), and
    # `[attributes, content]` pairs (blocks of their own).
    def insert_xml_text(ordinal, attributes, content = [])
      native_insert_xml_text(ordinal, attributes, content)
    end

    # Append a block with `attributes` holding `content` (see
    # `insert_xml_text`) and return a live handle to it.
    def push_xml_text(attributes, content = [])
      insert_xml_text(-1, attributes, content)
    end

    # The Yjs relative position of character `index`: the `{type, tname,
    # item, assoc}` hash editors carry in awareness as `anchorPos`/`focusPos`.
    # `assoc:` is `:after` (the default) or `:before`.
    def relative_position(index, assoc: :after)
      native_relative_position(index, assoc.to_s)
    end

    # This block's `Anchor`: a value that names the block itself, with the
    # root's name, so the document can say where the block is later.
    def anchor
      Anchor.new(position: native_block_position, root: root_name)
    end
  end
end
