//! Signed, expiring grants: which document a page may open.
//!
//! The server that renders a page decides who may edit which document and
//! hands the browser a grant. The channel trusts the grant rather than
//! anything the client names. This is yrby-rails' signed GlobalID
//! (`record.collaborative_sgid(name)`), as a standard JWT (HS256):
//!
//! ```json
//! { "aud": "yrby", "sub": "Post/0192f7b4-…", "name": "body", "exp": 1790000000 }
//! ```
//!
//! - `sub` says which document: an opaque key, or a reference to a record
//!   that the verifier looks up (loco-yrby grants carry `<RecordType>/<pid>`).
//! - `name` is the attribute. A grant for one attribute of a record does not
//!   open another, as the sgid's purpose (`yrby/<name>`) ensures in Rails.
//! - `aud` is always `yrby`, so a grant is never mistaken for another kind of
//!   token: a verifier that expects no audience, or a different one, rejects it.
//!
//! Sign with a secret of its own, not the one that signs logins.

use std::time::{SystemTime, UNIX_EPOCH};

use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

/// The audience every grant carries.
pub const AUDIENCE: &str = "yrby";

#[derive(Serialize, Deserialize)]
struct Claims {
    aud: String,
    sub: String,
    name: String,
    exp: i64,
}

/// Signs and verifies grants with one secret.
#[derive(Clone)]
pub struct GrantSigner {
    encoding: EncodingKey,
    decoding: DecodingKey,
}

impl GrantSigner {
    pub fn new(secret: impl AsRef<[u8]>) -> Self {
        let secret = secret.as_ref();
        Self {
            encoding: EncodingKey::from_secret(secret),
            decoding: DecodingKey::from_secret(secret),
        }
    }

    /// A grant to the document `subject` as attribute `name`, valid for
    /// `ttl_seconds` (negative gives an already-expired grant, for tests).
    pub fn sign(&self, subject: &str, name: &str, ttl_seconds: i64) -> String {
        let claims = Claims {
            aud: AUDIENCE.to_string(),
            sub: subject.to_string(),
            name: name.to_string(),
            exp: now() + ttl_seconds,
        };
        encode(&Header::new(Algorithm::HS256), &claims, &self.encoding)
            .expect("HS256 signing cannot fail")
    }

    /// The subject, if `grant` is authentic, unexpired, a yrby grant, and for `name`.
    pub fn verify(&self, grant: &str, name: &str) -> Option<String> {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.set_audience(&[AUDIENCE]);
        validation.set_required_spec_claims(&["exp", "aud", "sub"]);
        validation.leeway = 0;
        let claims = decode::<Claims>(grant, &self.decoding, &validation)
            .ok()?
            .claims;
        (claims.name == name).then_some(claims.sub)
    }
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(claims: serde_json::Value, secret: &str) -> String {
        encode(
            &Header::new(Algorithm::HS256),
            &claims,
            &EncodingKey::from_secret(secret.as_bytes()),
        )
        .unwrap()
    }

    #[test]
    fn round_trips_a_grant() {
        let signer = GrantSigner::new("s3cret");
        let grant = signer.sign("Post/abc", "body", 60);
        assert_eq!(signer.verify(&grant, "body").as_deref(), Some("Post/abc"));
    }

    #[test]
    fn refuses_other_names_expired_grants_and_other_secrets() {
        let signer = GrantSigner::new("s3cret");
        let grant = signer.sign("Post/abc", "body", 60);
        assert_eq!(signer.verify(&grant, "title"), None);
        assert_eq!(
            signer.verify(&signer.sign("Post/abc", "body", -1), "body"),
            None
        );
        assert_eq!(GrantSigner::new("other").verify(&grant, "body"), None);
    }

    #[test]
    fn refuses_tokens_that_are_not_yrby_grants() {
        let signer = GrantSigner::new("s3cret");
        let exp = now() + 60;
        // Right secret and shape, wrong or missing audience: say, a login token.
        let login = token(
            serde_json::json!({ "sub": "Post/abc", "name": "body", "exp": exp }),
            "s3cret",
        );
        let other = token(
            serde_json::json!({ "aud": "api", "sub": "Post/abc", "name": "body", "exp": exp }),
            "s3cret",
        );
        let forever = token(
            serde_json::json!({ "aud": "yrby", "sub": "Post/abc", "name": "body" }),
            "s3cret",
        );
        assert_eq!(signer.verify(&login, "body"), None);
        assert_eq!(signer.verify(&other, "body"), None);
        assert_eq!(signer.verify(&forever, "body"), None, "a grant must expire");
    }

    #[test]
    fn refuses_tampered_and_malformed_grants() {
        let signer = GrantSigner::new("s3cret");
        let grant = signer.sign("Post/abc", "body", 60);
        let (head, signature) = grant.rsplit_once('.').unwrap();
        let forged = token(
            serde_json::json!({ "aud": "yrby", "sub": "Post/other", "name": "body", "exp": now() + 60 }),
            "guess",
        );
        let (forged_head, _) = forged.rsplit_once('.').unwrap();
        assert_eq!(
            signer.verify(&format!("{forged_head}.{signature}"), "body"),
            None
        );
        assert_eq!(signer.verify(head, "body"), None);
        assert_eq!(signer.verify("", "body"), None);
        assert_eq!(signer.verify("forged--00", "body"), None);
    }

    #[test]
    fn verifies_a_grant_minted_by_yrby_rails() {
        // Y::Collaborative::Grant.encode(subject: "Post/ruby-fixture", name: "body",
        //   expires_at: Time.at(4102444800), secret: "yrby-interop-grant-secret")
        const RUBY_GRANT: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.\
            eyJhdWQiOiJ5cmJ5Iiwic3ViIjoiUG9zdC9ydWJ5LWZpeHR1cmUiLCJuYW1lIjoiYm9keSIsImV4cCI6NDEwMjQ0NDgwMH0.\
            h0aeuF3PHde-M3zJzs4T3-CDo3TABplfNFpwDw-L834";
        let signer = GrantSigner::new("yrby-interop-grant-secret");
        assert_eq!(
            signer.verify(RUBY_GRANT, "body").as_deref(),
            Some("Post/ruby-fixture")
        );
        assert_eq!(signer.verify(RUBY_GRANT, "notes"), None);
        assert_eq!(GrantSigner::new("other").verify(RUBY_GRANT, "body"), None);
    }

    #[test]
    fn refuses_an_unsigned_token() {
        // alg "none": the classic JWT downgrade.
        use base64::Engine;
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"none","typ":"JWT"}"#);
        let claims = URL_SAFE_NO_PAD.encode(format!(
            r#"{{"aud":"yrby","sub":"Post/abc","name":"body","exp":{}}}"#,
            now() + 60
        ));
        assert_eq!(
            GrantSigner::new("s3cret").verify(&format!("{header}.{claims}."), "body"),
            None
        );
    }
}
