//! Keys derived from an AnyCable application secret (`--secret`).
//!
//! When only the application secret is configured, anycable-go derives each
//! component's key as `hex(HMAC-SHA256(secret, <purpose>))`. This computes the
//! same value, so the app and anycable-go can share a single secret.

use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

/// The key a publisher must send to anycable-go's `/_broadcast` endpoint when
/// `--broadcast_key` is not set explicitly.
pub fn broadcast_key(application_secret: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(application_secret.as_bytes())
        .expect("HMAC accepts any key length");
    mac.update(b"broadcast-cable");
    hex::encode(mac.finalize().into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_documented_openssl_derivation() {
        // echo -n 'broadcast-cable' | openssl dgst -sha256 -hmac 'secret'
        assert_eq!(
            broadcast_key("secret"),
            "fc20575eaa046c555be789f7a9df5111d64eb17e4956597597c3220c1ad14739"
        );
    }
}
