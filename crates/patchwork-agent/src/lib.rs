//! Agent execution for Patchwork.
//!
//! One code path drives every agent run, whether it happens on a user's
//! desktop or on the relay: detect a compatible ACP installation, prepare the
//! task's folder or git worktree, talk ACP over stdio, and translate the
//! runtime's chatter into a concise chat update plus a detailed run log.

pub mod acp;
pub mod detect;
pub mod preview;
pub mod runner;
pub mod worktree;

pub use detect::{detect_capabilities, detect_runtimes, refresh_capabilities, runtime_command};
pub use runner::{RunHandle, Runner, RunnerConfig, Sink};
