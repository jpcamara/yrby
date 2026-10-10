//! Encryption at rest for document state and updates: AES-256-GCM.
//!
//! Each stored value is
//!
//! ```text
//! 00 00 'Y' 'E' '1' | 12-byte random nonce | ciphertext + 16-byte tag
//! ```
//!
//! sealed with the document key as associated data, so a value copied into
//! another document's rows fails to decrypt instead of opening there.
//!
//! The prefix cannot begin a real Yjs update: an update starting `00 00` has no
//! structs and no deletes and is exactly two bytes long. So a store reads
//! plaintext and encrypted values side by side, which is what turning
//! encryption on for an existing database needs: old rows stay readable, new
//! writes are encrypted, and compaction re-encrypts the snapshot.

use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use yrby_core::store::StoreError;

const MAGIC: &[u8] = b"\x00\x00YE1";
const NONCE_LEN: usize = 12;

/// Seals new values with the primary key; opens values sealed with it or any
/// previous key, so keys can be rotated.
#[derive(Clone)]
pub struct DocumentCipher {
    keys: Vec<Aes256Gcm>,
}

impl std::fmt::Debug for DocumentCipher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DocumentCipher")
            .field("keys", &self.keys.len())
            .finish()
    }
}

impl DocumentCipher {
    /// `primary` and each of `previous` are base64-encoded 32-byte keys. Make
    /// one with `openssl rand -base64 32`.
    ///
    /// # Errors
    /// When a key is not base64, or not 32 bytes.
    pub fn new(primary: &str, previous: &[String]) -> Result<Self, StoreError> {
        let keys = std::iter::once(primary)
            .chain(previous.iter().map(String::as_str))
            .map(|encoded| {
                let bytes = STANDARD
                    .decode(encoded.trim())
                    .map_err(|e| format!("encryption key is not base64: {e}"))?;
                Aes256Gcm::new_from_slice(&bytes).map_err(|_| {
                    format!("encryption key must be 32 bytes, not {}", bytes.len()).into()
                })
            })
            .collect::<Result<Vec<_>, StoreError>>()?;
        Ok(Self { keys })
    }

    /// Encrypt `plaintext` for the document `key`.
    pub fn seal(&self, key: &str, plaintext: &[u8]) -> Vec<u8> {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let payload = Payload {
            msg: plaintext,
            aad: key.as_bytes(),
        };
        let sealed = self.keys[0]
            .encrypt(&nonce, payload)
            .expect("AES-GCM encryption of an in-memory buffer cannot fail");
        [MAGIC, &nonce[..], &sealed].concat()
    }

    /// Decrypt a value of the document `key`.
    ///
    /// # Errors
    /// When the value is not encrypted, or no key opens it (a wrong key, a
    /// tampered value, or one moved from another document).
    pub fn open(&self, key: &str, stored: &[u8]) -> Result<Vec<u8>, StoreError> {
        let rest = stored
            .strip_prefix(MAGIC)
            .ok_or("not an encrypted document value")?;
        if rest.len() < NONCE_LEN {
            return Err("encrypted document value is truncated".into());
        }
        let (nonce, sealed) = rest.split_at(NONCE_LEN);
        let nonce = Nonce::from(<[u8; NONCE_LEN]>::try_from(nonce).expect("split at NONCE_LEN"));
        self.keys
            .iter()
            .find_map(|cipher| {
                let payload = Payload {
                    msg: sealed,
                    aad: key.as_bytes(),
                };
                cipher.decrypt(&nonce, payload).ok()
            })
            .ok_or_else(|| format!("no encryption key opens a value of document {key:?}").into())
    }
}

/// Whether a stored value is encrypted.
pub fn is_encrypted(stored: &[u8]) -> bool {
    stored.starts_with(MAGIC)
}

/// Read a stored value: decrypt it if it is encrypted, pass plaintext through.
pub(crate) fn open(
    cipher: Option<&DocumentCipher>,
    key: &str,
    value: Vec<u8>,
) -> Result<Vec<u8>, StoreError> {
    if !is_encrypted(&value) {
        return Ok(value);
    }
    match cipher {
        Some(cipher) => cipher.open(key, &value),
        None => Err(format!(
            "document {key:?} holds encrypted values, but no encryption key is configured"
        )
        .into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY_A: &str = "q0b3cxVvT6s0w8m3k4b0w2bX8y0pZ8b0YxK2l9p3n1o=";
    const KEY_B: &str = "c2Vjb25kLWtleS0zMi1ieXRlcy1sb25nLWV4YWN0bHk=";

    #[test]
    fn round_trips_and_hides_the_plaintext() {
        let cipher = DocumentCipher::new(KEY_A, &[]).unwrap();
        let sealed = cipher.seal("post/1/body", b"secret text");
        assert!(is_encrypted(&sealed));
        assert!(!sealed.windows(6).any(|w| w == b"secret"));
        assert_eq!(cipher.open("post/1/body", &sealed).unwrap(), b"secret text");
        // A fresh nonce every time.
        assert_ne!(cipher.seal("post/1/body", b"secret text"), sealed);
    }

    #[test]
    fn binds_a_value_to_its_document() {
        let cipher = DocumentCipher::new(KEY_A, &[]).unwrap();
        let sealed = cipher.seal("post/1/body", b"secret text");
        assert!(cipher.open("post/2/body", &sealed).is_err());
    }

    #[test]
    fn rejects_tampering_and_the_wrong_key() {
        let cipher = DocumentCipher::new(KEY_A, &[]).unwrap();
        let mut sealed = cipher.seal("doc", b"secret text");
        let other = DocumentCipher::new(KEY_B, &[]).unwrap();
        assert!(other.open("doc", &sealed).is_err());
        let last = sealed.len() - 1;
        sealed[last] ^= 1;
        assert!(cipher.open("doc", &sealed).is_err());
        assert!(cipher.open("doc", &sealed[..MAGIC.len() + 4]).is_err());
    }

    #[test]
    fn rotates_keys() {
        let old = DocumentCipher::new(KEY_A, &[]).unwrap();
        let sealed = old.seal("doc", b"from before the rotation");
        let rotated = DocumentCipher::new(KEY_B, &[KEY_A.to_string()]).unwrap();
        assert_eq!(
            rotated.open("doc", &sealed).unwrap(),
            b"from before the rotation"
        );
        // New values use the new primary key only.
        assert!(old.open("doc", &rotated.seal("doc", b"after")).is_err());
    }

    #[test]
    fn reads_plaintext_from_before_encryption() {
        let update = [1u8, 1, 200, 1, 0, 4, 0, 1, 116, 1, 97, 0];
        assert_eq!(open(None, "doc", update.to_vec()).unwrap(), update);
        let cipher = DocumentCipher::new(KEY_A, &[]).unwrap();
        assert_eq!(open(Some(&cipher), "doc", update.to_vec()).unwrap(), update);
        // A store without a key refuses encrypted values instead of handing
        // ciphertext to Yjs.
        assert!(open(None, "doc", cipher.seal("doc", b"x")).is_err());
    }

    #[test]
    fn rejects_bad_keys() {
        assert!(DocumentCipher::new("not base64!", &[]).is_err());
        assert!(DocumentCipher::new("c2hvcnQ=", &[]).is_err());
    }
}
