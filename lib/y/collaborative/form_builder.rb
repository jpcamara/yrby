# frozen_string_literal: true

module Y
  module Collaborative
    # form.collaborative_document_tag renders the collaboration element for
    # one collaborative attribute: the custom element an editor package
    # supplies (element:), wired with the document id, the channel, the
    # signed token, and the presence identity from
    # Y::Collaborative.identity. Editor-specific helpers build on it and
    # supply only their element name.
    module FormBuilder
      # method:  the collaborative attribute (declared with
      #          has_collaborative_document / has_collaborative_rich_text)
      # element: the custom element tag name the editor package registers
      # channel: the server channel; defaults to
      #          Y::Collaborative.channel_name
      # name:/color: presence overrides; extra attributes pass through to
      #          the element. A block renders inside it.
      # rubocop:disable-next Metrics/ParameterLists -- the wiring knobs are the API
      def collaborative_document_tag(method, element:, channel: nil, name: nil, color: nil, **attrs, &block)
        record = collaborative_document_record!(method)
        identity = Y::Collaborative.identity.call(@template)
        collaborator = name || identity[:name]
        @template.content_tag(element, block ? @template.capture(&block) : "",
                              {
                                # The client-side Yjs binding key, shared by
                                # peers of this attribute. The server never
                                # sees it.
                                "doc-id" => "#{record.model_name.param_key}-#{record.id}-#{method}",
                                "name" => collaborator,
                                "color" => color || identity[:color] || Y::Collaborative.collaborator_color(collaborator),
                                "channel-name" => channel || Y::Collaborative.channel_name,
                                "channel-params" => { sgid: record.collaborative_sgid(method), field: method }.to_json
                              }.merge(attrs))
      end

      private

      def collaborative_document_record!(method)
        record = object
        unless record.respond_to?(:collaborative_document?) && record.collaborative_document?(method)
          raise ArgumentError,
                "#{record.class.name}##{method} is not collaborative (declare has_collaborative_document :#{method})"
        end
        raise ArgumentError, "#{record.class.name} must be persisted to collaborate on it" unless record.persisted?

        record
      end
    end
  end
end
