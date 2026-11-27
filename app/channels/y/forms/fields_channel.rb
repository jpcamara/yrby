# frozen_string_literal: true

module Y
  module Forms
    # The channel behind form.collaborative_fields. It is Y::DocumentChannel
    # for a record's field set, and after it saves each change it writes the
    # declared fields' current values into their columns.
    #
    # has_collaborative_fields declares it as the document's channel, so the
    # tag the form helper renders subscribes here. Access works as it does for
    # Y::DocumentChannel: the signed grant opens the document, and an
    # authorize_document block can also check the connected user.
    class FieldsChannel < Y::DocumentChannel
      on_change do |key, update|
        document.append(update)
        # The change is saved, so a failure here is logged and not raised.
        # Raising would make the client resend a change the server already
        # has. The columns catch up on the next change.
        begin
          document.record.refresh_collaborative_fields
        rescue StandardError => e
          logger.error("yrby-forms could not write #{key} to its columns: #{e.class}: #{e.message}")
        end
      end

      private

      # A grant signed for another attribute, or for a model without
      # collaborative fields, opens nothing here.
      def authorized?(key)
        params[:name].to_s == Y::Forms::DOCUMENT_NAME && record.try(:collaborative_fields?) && super
      end
    end
  end
end
