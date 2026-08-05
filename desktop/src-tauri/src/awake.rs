//! Keeping the machine awake while an agent is working.
//!
//! An agent running on this laptop stops the moment the lid closes or the
//! machine idles out, and the run just dies — halfway through, with no useful
//! error. macOS already has the right tool for this: `caffeinate` holds a power
//! assertion for as long as it is alive, and releases it when killed, including
//! if this app crashes. That last part is why this spawns a child process
//! rather than taking an IOKit assertion directly: a leaked assertion would
//! keep somebody's laptop awake until they rebooted.

use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AwakePolicy {
    /// Never hold the machine awake. The default: it is the user's battery.
    #[default]
    Never,
    /// Only while this machine is actually running an agent.
    WhileRunning,
    /// For as long as Patchwork is open.
    WhileOpen,
}

#[derive(Default)]
pub struct Keeper {
    inner: Mutex<State>,
}

#[derive(Default)]
struct State {
    policy: AwakePolicy,
    running: usize,
    process: Option<Child>,
}

impl Keeper {
    pub fn set_policy(&self, policy: AwakePolicy) {
        let mut state = self.inner.lock().unwrap();
        state.policy = policy;
        Self::apply(&mut state);
    }

    /// Called whenever the number of active runs on this machine changes.
    pub fn set_running(&self, running: usize) {
        let mut state = self.inner.lock().unwrap();
        if state.running == running {
            return;
        }
        state.running = running;
        Self::apply(&mut state);
    }

    pub fn shutdown(&self) {
        let mut state = self.inner.lock().unwrap();
        Self::stop(&mut state);
    }

    fn wanted(state: &State) -> bool {
        match state.policy {
            AwakePolicy::Never => false,
            AwakePolicy::WhileOpen => true,
            AwakePolicy::WhileRunning => state.running > 0,
        }
    }

    fn apply(state: &mut State) {
        if Self::wanted(state) {
            Self::start(state);
        } else {
            Self::stop(state);
        }
    }

    fn start(state: &mut State) {
        // A dead child is as good as none — the machine is not being held.
        if let Some(child) = &mut state.process {
            match child.try_wait() {
                Ok(None) => return,
                _ => state.process = None,
            }
        }
        if !cfg!(target_os = "macos") {
            return;
        }
        // `-i` idle, `-m` disk, `-s` system. Deliberately *not* `-d`: nobody
        // wants the display on all night because an agent is compiling.
        match Command::new("caffeinate")
            .args(["-i", "-m", "-s"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => state.process = Some(child),
            Err(err) => tracing::warn!(?err, "could not keep this machine awake"),
        }
    }

    fn stop(state: &mut State) {
        if let Some(mut child) = state.process.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for Keeper {
    fn drop(&mut self) {
        if let Ok(mut state) = self.inner.lock() {
            Self::stop(&mut state);
        }
    }
}
