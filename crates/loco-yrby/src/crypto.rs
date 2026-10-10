//! Encryption at rest, in Active Record Encryption's format.
//!
//! yrby-rails encrypts a document with Active Record encryption
//! (`has_collaborative_document :body, encrypted: true`). This reads and writes
//! the same values, so a Rails app and a Loco app can share one database,
//! encrypted documents included. Configure it with the Rails app's
//! `active_record.encryption` values.
//!
//! A stored value is the JSON Active Record writes (activerecord 8.1):
//!
//! ```json
//! {"p": "<base64 ciphertext>", "h": {"iv": "<base64>", "at": "<base64 tag>", "e": "<base64 encoding>", "c": true}}
//! ```
//!
//! - AES-256-GCM, a random 12-byte IV, no associated data.
//! - The key is PBKDF2-HMAC(`primary_key`, `key_derivation_salt`, 2^16
//!   iterations, 32 bytes), with SHA256, or SHA1 for apps on
//!   `load_defaults` before 7.1. With several primary keys, the last
//!   encrypts and all decrypt, as in Rails.
//! - Payloads over 140 bytes are zlib-deflated first, flagged by `"c": true`.
//!
//! Active Record binds no associated data, so unlike a scheme of our own, a
//! value moved into another document's row still decrypts there. Matching
//! Rails is worth that; database write access is already the threat that
//! would require.
//!
//! A value that is not such a message is plaintext: a document written before
//! it was encrypted. It reads as is, so encryption can be turned on for an
//! existing database (Rails' `support_unencrypted_data`).

use std::io::{Read, Write};

use aes_gcm::aead::{Aead, AeadCore, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use flate2::Compression;
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use serde::{Deserialize, Serialize};
use yrby_core::store::StoreError;

const ITERATIONS: u32 = 1 << 16;
const KEY_LENGTH: usize = 32;
const IV_LENGTH: usize = 12;
const TAG_LENGTH: usize = 16;
const COMPRESSION_THRESHOLD: usize = 140;
// Ruby tags non-UTF-8 strings with their encoding; Yjs updates are binary.
const BINARY_ENCODING: &str = "ASCII-8BIT";

/// The digest Active Record derives keys with (`active_record.encryption.hash_digest_class`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize)]
pub enum HashDigest {
    /// Rails apps on `load_defaults` 7.1 or later.
    #[default]
    #[serde(alias = "sha256", alias = "OpenSSL::Digest::SHA256")]
    SHA256,
    /// Rails apps on earlier `load_defaults`.
    #[serde(alias = "sha1", alias = "OpenSSL::Digest::SHA1")]
    SHA1,
}

#[derive(Serialize, Deserialize)]
struct Message {
    p: String,
    #[serde(default)]
    h: Headers,
}

#[derive(Serialize, Deserialize, Default)]
struct Headers {
    #[serde(default)]
    iv: Option<String>,
    #[serde(default)]
    at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    e: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    c: Option<bool>,
}

/// Active Record encryption keys, derived once.
#[derive(Clone)]
pub struct DocumentCipher {
    /// In configuration order: the last encrypts, all decrypt.
    keys: Vec<Aes256Gcm>,
    compress: bool,
}

impl std::fmt::Debug for DocumentCipher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DocumentCipher")
            .field("keys", &self.keys.len())
            .finish()
    }
}

impl DocumentCipher {
    /// Keys from the Rails app's `active_record.encryption.primary_key` (one
    /// or several) and `key_derivation_salt`.
    ///
    /// # Errors
    /// When there is no primary key.
    pub fn new(
        primary_keys: &[String],
        key_derivation_salt: &str,
        digest: HashDigest,
    ) -> Result<Self, StoreError> {
        if primary_keys.is_empty() || primary_keys.iter().any(|key| key.is_empty()) {
            return Err("encryption needs a non-empty primary_key".into());
        }
        let keys = primary_keys
            .iter()
            .map(|password| {
                let mut key = [0u8; KEY_LENGTH];
                let (password, salt) = (password.as_bytes(), key_derivation_salt.as_bytes());
                match digest {
                    HashDigest::SHA256 => {
                        pbkdf2::pbkdf2_hmac::<sha2::Sha256>(password, salt, ITERATIONS, &mut key)
                    }
                    HashDigest::SHA1 => {
                        pbkdf2::pbkdf2_hmac::<sha1::Sha1>(password, salt, ITERATIONS, &mut key)
                    }
                }
                Aes256Gcm::new(&key.into())
            })
            .collect();
        Ok(Self {
            keys,
            compress: true,
        })
    }

    /// Encrypt a value as Active Record would.
    pub fn encrypt(&self, plaintext: &[u8]) -> Vec<u8> {
        let (body, compressed) = if self.compress && plaintext.len() > COMPRESSION_THRESHOLD {
            let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
            encoder
                .write_all(plaintext)
                .expect("deflating into memory cannot fail");
            (
                encoder.finish().expect("deflating into memory cannot fail"),
                true,
            )
        } else {
            (plaintext.to_vec(), false)
        };
        let iv = Aes256Gcm::generate_nonce(&mut OsRng);
        let mut sealed = self
            .keys
            .last()
            .expect("at least one key")
            .encrypt(&iv, body.as_slice())
            .expect("AES-GCM in memory");
        let tag = sealed.split_off(sealed.len() - TAG_LENGTH);
        let message = Message {
            p: STANDARD.encode(&sealed),
            h: Headers {
                iv: Some(STANDARD.encode(&iv[..])),
                at: Some(STANDARD.encode(&tag)),
                e: Some(STANDARD.encode(BINARY_ENCODING)),
                c: compressed.then_some(true),
            },
        };
        serde_json::to_vec(&message).expect("a message serializes")
    }

    /// Decrypt an Active Record encrypted value.
    ///
    /// # Errors
    /// When the value is not an encrypted message, or no key opens it.
    pub fn decrypt(&self, stored: &[u8]) -> Result<Vec<u8>, StoreError> {
        let message = parse(stored).ok_or("not an Active Record encrypted value")?;
        let decode = |field: Option<&String>, name: &str| -> Result<Vec<u8>, StoreError> {
            let field = field.ok_or_else(|| format!("encrypted value has no {name:?} header"))?;
            Ok(STANDARD
                .decode(field)
                .map_err(|e| format!("encrypted value's {name:?} is not base64: {e}"))?)
        };
        let iv = decode(message.h.iv.as_ref(), "iv")?;
        let tag = decode(message.h.at.as_ref(), "at")?;
        if iv.len() != IV_LENGTH || tag.len() != TAG_LENGTH {
            return Err("encrypted value has a malformed iv or auth tag".into());
        }
        let sealed = [
            STANDARD
                .decode(&message.p)
                .map_err(|e| format!("encrypted payload is not base64: {e}"))?,
            tag,
        ]
        .concat();
        let iv = Nonce::from(<[u8; IV_LENGTH]>::try_from(iv.as_slice()).expect("length checked"));
        let body = self
            .keys
            .iter()
            .rev()
            .find_map(|key| key.decrypt(&iv, sealed.as_slice()).ok())
            .ok_or("no encryption key opens this value")?;
        if message.h.c == Some(true) {
            let mut plaintext = Vec::new();
            ZlibDecoder::new(body.as_slice())
                .read_to_end(&mut plaintext)
                .map_err(|e| format!("cannot inflate: {e}"))?;
            Ok(plaintext)
        } else {
            Ok(body)
        }
    }
}

fn parse(stored: &[u8]) -> Option<Message> {
    // Cheap reject first: a Yjs update is binary and never starts a JSON object.
    if stored.first() != Some(&b'{') {
        return None;
    }
    serde_json::from_slice(stored).ok()
}

/// Whether a stored value is an Active Record encrypted message.
pub fn is_encrypted(stored: &[u8]) -> bool {
    parse(stored).is_some()
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
        Some(cipher) => cipher
            .decrypt(&value)
            .map_err(|e| format!("document {key:?}: {e}").into()),
        None => Err(format!(
            "document {key:?} holds encrypted values, but no encryption key is configured"
        )
        .into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cipher(keys: &[&str]) -> DocumentCipher {
        let keys: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
        DocumentCipher::new(&keys, "salt", HashDigest::SHA256).unwrap()
    }

    #[test]
    fn round_trips_short_and_long_values() {
        let c = cipher(&["primary"]);
        let short = b"\x01\x02 secret text".to_vec();
        let long: Vec<u8> = b"secret ".repeat(40);
        for value in [short, long.clone(), Vec::new()] {
            let sealed = c.encrypt(&value);
            assert!(is_encrypted(&sealed));
            assert!(!sealed.windows(6).any(|w| w == b"secret"));
            assert_eq!(c.decrypt(&sealed).unwrap(), value);
        }
        // Long values are compressed, as Active Record does past 140 bytes.
        let message: Message = serde_json::from_slice(&c.encrypt(&long)).unwrap();
        assert_eq!(message.h.c, Some(true));
        assert_eq!(
            STANDARD.decode(message.h.e.unwrap()).unwrap(),
            b"ASCII-8BIT"
        );
    }

    #[test]
    fn rotates_like_rails() {
        // Rails encrypts with the last primary key and decrypts with any.
        let old = cipher(&["old"]);
        let rotated = cipher(&["old", "new"]);
        let before = old.encrypt(b"from before");
        assert_eq!(rotated.decrypt(&before).unwrap(), b"from before");
        assert!(old.decrypt(&rotated.encrypt(b"after")).is_err());
    }

    #[test]
    fn rejects_tampering_wrong_keys_and_digests() {
        let c = cipher(&["primary"]);
        let sealed = c.encrypt(b"value");
        assert!(cipher(&["other"]).decrypt(&sealed).is_err());
        let sha1 = DocumentCipher::new(&["primary".into()], "salt", HashDigest::SHA1).unwrap();
        assert!(
            sha1.decrypt(&sealed).is_err(),
            "SHA1 and SHA256 derive different keys"
        );

        let mut message: serde_json::Value = serde_json::from_slice(&sealed).unwrap();
        message["p"] = STANDARD.encode(b"forged").into();
        assert!(c.decrypt(&serde_json::to_vec(&message).unwrap()).is_err());
    }

    #[test]
    fn passes_plaintext_through_and_refuses_ciphertext_without_a_key() {
        let update = vec![1u8, 1, 200, 1, 0, 4, 0, 1, 116, 1, 97, 0];
        assert!(!is_encrypted(&update));
        assert_eq!(open(None, "doc", update.clone()).unwrap(), update);
        let sealed = cipher(&["primary"]).encrypt(&update);
        assert!(open(None, "doc", sealed).is_err());
    }

    #[test]
    fn requires_a_primary_key() {
        assert!(DocumentCipher::new(&[], "salt", HashDigest::SHA256).is_err());
        assert!(DocumentCipher::new(&[String::new()], "salt", HashDigest::SHA256).is_err());
    }
}
