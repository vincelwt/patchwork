//! Tokens.
//!
//! Humans get a device token when they redeem an invite; agents get a token
//! scoped to a single run, which is revoked the moment that run ends.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use base64::Engine;
use patchwork_core::models::{Member, MemberKind};
use patchwork_core::Id;
use rand::RngCore;
use sha2::{Digest, Sha256};

use crate::error::ApiError;
use crate::state::Shared;

pub fn generate_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn generate_invite_code() -> String {
    let mut bytes = [0u8; 9];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

pub fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

/// The authenticated caller: a human on a device, or an agent inside a run.
#[derive(Clone, Debug)]
pub struct Caller {
    pub member: Member,
    pub run_id: Option<Id>,
    pub token_hash: String,
    pub token_kind: String,
}

impl Caller {
    pub fn is_agent(&self) -> bool {
        self.member.kind == MemberKind::Agent
    }

    pub fn can_host(&self) -> bool {
        self.token_kind != "mobile"
    }

    pub fn require_device(&self) -> Result<(), ApiError> {
        if self.member.kind == MemberKind::Human
            && matches!(self.token_kind.as_str(), "device" | "mobile")
        {
            Ok(())
        } else {
            Err(ApiError::forbidden("only a human device can do that"))
        }
    }

    pub fn require_admin(&self) -> Result<(), ApiError> {
        if self.member.is_admin {
            Ok(())
        } else {
            Err(ApiError::forbidden("this needs an admin"))
        }
    }
}

impl FromRequestParts<Shared> for Caller {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &Shared) -> Result<Self, Self::Rejection> {
        let token = bearer_token(parts).ok_or_else(|| ApiError::unauthorized("missing token"))?;
        authenticate(state, &token).ok_or_else(|| ApiError::unauthorized("invalid token"))
    }
}

pub fn authenticate(state: &Shared, token: &str) -> Option<Caller> {
    let token_hash = hash_token(token);
    let (member_id, token_kind, run_id) = state.store.lookup_token(&token_hash).ok()??;
    let member = state.store.member(&member_id).ok()??;
    Some(Caller {
        member,
        run_id,
        token_hash,
        token_kind,
    })
}

fn bearer_token(parts: &Parts) -> Option<String> {
    let header = parts
        .headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?;
    header
        .strip_prefix("Bearer ")
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashing_is_stable_and_tokens_are_not_stored_raw() {
        let token = generate_token();
        assert_eq!(hash_token(&token), hash_token(&token));
        assert_ne!(hash_token(&token), token);
        assert_ne!(generate_token(), generate_token());
    }

    #[test]
    fn agent_run_tokens_cannot_pair_devices() {
        let caller = Caller {
            member: Member {
                id: "agent".into(),
                kind: MemberKind::Agent,
                handle: "agent".into(),
                display_name: "Agent".into(),
                email: None,
                avatar: None,
                is_admin: false,
                created_at: 0,
                agent: None,
                presence: Default::default(),
            },
            run_id: Some("run".into()),
            token_hash: "hash".into(),
            token_kind: "run".into(),
        };
        assert!(caller.require_device().is_err());
        assert!(caller.can_host());

        let mut mobile = caller;
        mobile.member.kind = MemberKind::Human;
        mobile.token_kind = "mobile".into();
        mobile.run_id = None;
        assert!(mobile.require_device().is_ok());
        assert!(!mobile.can_host());
    }
}
