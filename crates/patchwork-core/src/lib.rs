//! Shared domain model and wire protocol for Patchwork.
//!
//! Everything in this crate is transport-agnostic: the relay, the desktop app,
//! and the agent-facing CLI all speak these types.

pub mod events;
pub mod host;
pub mod ids;
pub mod models;
pub mod wire;

pub use ids::{new_id, now_ms, Id, Millis};
