# frozen_string_literal: true

require "y"
require "y/collaborative"

module Y
  # Collaborative form fields over yrby: a model macro
  # (has_collaborative_fields), form helpers rendering the
  # <collaborative-form> / <collaborative-field> elements, and an install
  # generator for the channel. One Y::Document per record holds the whole
  # field set: LWW fields in a "fields" map share, text-tier fields in one
  # "fields/<name>" text share each.
  #
  # The document lifecycle, the signed-GlobalID flow, and the presence
  # identity come from yrby-rails' Y::Collaborative; this gem supplies the
  # tier detection, the materializer, and the field elements.
  module Forms
    # The channel the installer generates and the form helper points elements at.
    CHANNEL_NAME = "FormFieldsChannel"

    # The Y::Document name for a record's field set: one document per record.
    DOCUMENT_NAME = "fields"
  end
end

require "y/forms/collaborative_fields"
require "y/forms/form_builder"
