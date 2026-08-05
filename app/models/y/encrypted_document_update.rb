# frozen_string_literal: true

# The encrypted tail row: Y::DocumentUpdate with the payload encrypted.
# Written and read through Y::EncryptedDocument's updates association.
class Y::EncryptedDocumentUpdate < Y::DocumentUpdate
  belongs_to :document, class_name: "Y::EncryptedDocument"

  encrypts :payload
end
