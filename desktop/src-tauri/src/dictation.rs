//! Speaking instead of typing.
//!
//! The recognition itself is Apple's, on this machine, in [`Dictation.swift`].
//! This side is the plumbing: start it, forward what it hears to the window,
//! stop it. Nothing is uploaded and no key is involved, which is the whole
//! reason for using the system engine rather than a hosted API.

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

#[cfg(target_os = "macos")]
extern "C" {
    fn pw_dictation_supported() -> i32;
    fn pw_dictation_start(locale: *const c_char, emit: extern "C" fn(i32, *const c_char)) -> i32;
    fn pw_dictation_stop(emit: extern "C" fn(i32, *const c_char));
}

/// What the recogniser has to say. `volatile` is the tail it is still
/// revising and replaces the last volatile piece; `final` is settled text to
/// append.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Heard {
    Volatile { text: String },
    Final { text: String },
    Error { message: String },
    Stopped,
}

/// Where to send what it hears. Set once, because there is one window and one
/// microphone, and two dictations at a time is not a thing.
fn listener() -> &'static Mutex<Option<AppHandle>> {
    static LISTENER: OnceLock<Mutex<Option<AppHandle>>> = OnceLock::new();
    LISTENER.get_or_init(|| Mutex::new(None))
}

/// Called from Swift, on whatever thread the recogniser is using.
extern "C" fn heard(kind: i32, text: *const c_char) {
    let text = if text.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
    };
    let event = match kind {
        0 => Heard::Volatile { text },
        1 => Heard::Final { text },
        2 => Heard::Error { message: text },
        _ => Heard::Stopped,
    };
    if let Some(app) = listener().lock().ok().and_then(|app| app.clone()) {
        let _ = app.emit("dictation", event);
    }
}

pub fn supported() -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        pw_dictation_supported() == 1
    }
    #[cfg(not(target_os = "macos"))]
    false
}

pub fn start(app: AppHandle, locale: &str) -> Result<(), String> {
    if !supported() {
        return Err("this machine has no on-device dictation".into());
    }
    *listener().lock().map_err(|e| e.to_string())? = Some(app);

    #[cfg(target_os = "macos")]
    {
        let locale = std::ffi::CString::new(locale).map_err(|e| e.to_string())?;
        let started = unsafe { pw_dictation_start(locale.as_ptr(), heard) };
        if started != 1 {
            return Err("could not start dictation".into());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = locale;
    Ok(())
}

pub fn stop() {
    #[cfg(target_os = "macos")]
    unsafe {
        pw_dictation_stop(heard)
    }
}
