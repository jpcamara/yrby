# frozen_string_literal: true

# A document whose stored bytes are encrypted with Active Record encryption
# (state here, update payloads via Y::EncryptedDocumentUpdate). Same tables
# as Y::Document; the class you access through decides the cryptography,
# the way ActionText::EncryptedRichText does for rich text. Keep one access
# path per document: rows written encrypted read back as ciphertext through
# the plain classes.
#
# Requires the app to configure Active Record encryption keys. Ciphertext
# is larger than the plaintext (a serialized envelope around Base64), so
# the effective payload cap drops to roughly three quarters of the column
# limit.
class Y::EncryptedDocument < Y::Document
  has_many :updates, class_name: "Y::EncryptedDocumentUpdate",
                     foreign_key: :document_id, dependent: :delete_all,
                     inverse_of: :document

  encrypts :state
end
