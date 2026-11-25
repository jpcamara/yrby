# frozen_string_literal: true

module Y
  module Forms
    # form.collaborative_fields wraps a block of inputs in the <yrby-document>
    # element for the record's field set. form.collaborative_field wraps one
    # input in <collaborative-field>.
    module FormBuilder
      # Renders collaborative_document_tag for the field set, with the presence
      # name and color from Y::Forms.identity as data attributes. Options go
      # through to the tag, so expires_in: and refresh: work as they do there.
      def collaborative_fields(**options, &)
        record = collaborative_record!
        identity = Y::Forms.identity.call(@template)
        name = identity[:name]
        user = { user_name: name, user_color: identity[:color] || Y::Forms.collaborator_color(name) }
        @template.collaborative_document_tag(record, Y::Forms::DOCUMENT_NAME,
                                             **options, data: user.merge(options.fetch(:data, {})), &)
      end

      # Renders the stock input for the attribute's type inside the wrapper.
      # Pass a block to render your own input instead.
      def collaborative_field(method, &block)
        record = collaborative_record!
        tier = record.collaborative_field_tiers[method.to_sym]
        unless tier
          raise ArgumentError,
                "#{record.class.name}##{method} is not collaborative (declare has_collaborative_fields :#{method})"
        end

        input = block ? @template.capture(&block) : default_collaborative_input(method)
        @template.content_tag("collaborative-field", input, "name" => method, "tier" => tier)
      end

      private

      def collaborative_record!
        record = object
        unless record.respond_to?(:collaborative_fields?) && record.collaborative_fields?
          raise ArgumentError, "#{record.class.name} has no collaborative fields (declare has_collaborative_fields)"
        end
        raise ArgumentError, "#{record.class.name} must be persisted to collaborate on it" unless record.persisted?

        record
      end

      def default_collaborative_input(method)
        enums = object.class.defined_enums
        return select(method, enums[method.to_s].keys) if enums.key?(method.to_s)

        case object.class.type_for_attribute(method).type
        when :text then text_area(method)
        when :boolean then check_box(method)
        when :date then date_field(method)
        when :datetime, :time then datetime_field(method)
        when :integer, :decimal, :float then number_field(method)
        else text_field(method)
        end
      end
    end
  end
end
