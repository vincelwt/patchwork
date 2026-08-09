use std::time::{SystemTime, UNIX_EPOCH};

/// Identifiers are time-ordered UUID v7 strings so that natural sort order is
/// also creation order — useful for message and event pagination.
pub type Id = String;

/// Milliseconds since the Unix epoch. Timestamps are integers everywhere
/// (SQLite, JSON, UI) so no format negotiation is ever needed.
pub type Millis = i64;

pub fn new_id() -> Id {
    uuid::Uuid::now_v7().to_string()
}

pub fn now_ms() -> Millis {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// A short, human-typable handle derived from a display name (`Support Agent`
/// becomes `support-agent`).
pub fn slugify(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut last_dash = true;
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        out.push_str("item");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_time_ordered() {
        let a = new_id();
        let b = new_id();
        assert!(a < b, "uuid v7 ids must sort by creation time: {a} {b}");
    }

    #[test]
    fn slugify_handles_punctuation() {
        assert_eq!(
            slugify("Vince's developer agent"),
            "vince-s-developer-agent"
        );
        assert_eq!(slugify("  # infra  "), "infra");
        assert_eq!(slugify("!!!"), "item");
    }
}
