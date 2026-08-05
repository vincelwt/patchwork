//! Which models the Patchwork agent can think with, and how it is paid for.
//!
//! Every other runtime is somebody else's product: it was installed, signed in
//! and configured before Patchwork ever saw it. Ours is not installed at all —
//! it is Pi, fetched on demand — so Patchwork has to answer the two questions
//! an agent runtime normally answers for itself: whose models, and with whose
//! credentials.
//!
//! The credentials never enter the workspace. An API key lives in the desktop's
//! own settings on the machine that will use it, and reaches the agent as an
//! environment variable for the length of one process. A subscription is not
//! ours to hold at all: Pi signs in on that machine and keeps its own token.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// A place to get models from, as the user thinks of it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderInfo {
    /// Matches Pi's provider id, because the model ids we hand back to Pi are
    /// `provider/model`.
    pub id: &'static str,
    pub label: &'static str,
    /// The environment variable Pi reads the key from. Empty for providers you
    /// sign into instead.
    pub env_var: &'static str,
    /// Signed in with an existing subscription rather than paid per token.
    pub subscription: bool,
    pub hint: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recommended_model: Option<&'static str>,
}

/// Deliberately short. Pi speaks to dozens of providers; these are the ones
/// worth putting in front of someone who just wants an agent that works, and
/// anything missing is still reachable by pointing the runtime at Pi itself.
pub const PROVIDERS: &[ProviderInfo] = &[
    ProviderInfo {
        id: "openrouter",
        label: "OpenRouter",
        env_var: "OPENROUTER_API_KEY",
        subscription: false,
        hint: "One key, every model. Recommended: DeepSeek V4 Flash costs cents per task.",
        recommended_model: Some("openrouter/deepseek/deepseek-v4-flash"),
    },
    ProviderInfo {
        id: "anthropic-oauth",
        label: "Claude subscription",
        env_var: "",
        subscription: true,
        hint: "Use a Claude Pro or Max plan instead of paying per token.",
        recommended_model: Some("anthropic/claude-fable-5"),
    },
    ProviderInfo {
        id: "openai-codex",
        label: "ChatGPT subscription",
        env_var: "",
        subscription: true,
        hint: "Use a ChatGPT Plus or Pro plan through Codex.",
        recommended_model: Some("openai-codex/gpt-5.6-terra"),
    },
    ProviderInfo {
        id: "anthropic",
        label: "Anthropic",
        env_var: "ANTHROPIC_API_KEY",
        subscription: false,
        hint: "Claude models, billed to an Anthropic API key.",
        recommended_model: Some("anthropic/claude-fable-5"),
    },
    ProviderInfo {
        id: "openai",
        label: "OpenAI",
        env_var: "OPENAI_API_KEY",
        subscription: false,
        hint: "GPT models, billed to an OpenAI API key.",
        recommended_model: Some("openai/gpt-5.6"),
    },
    ProviderInfo {
        id: "google",
        label: "Google",
        env_var: "GEMINI_API_KEY",
        subscription: false,
        hint: "Gemini models, billed to a Google AI Studio key.",
        recommended_model: Some("google/gemini-3-pro"),
    },
    ProviderInfo {
        id: "xai",
        label: "xAI",
        env_var: "XAI_API_KEY",
        subscription: false,
        hint: "Grok models, billed to an xAI key.",
        recommended_model: None,
    },
    ProviderInfo {
        id: "deepseek",
        label: "DeepSeek",
        env_var: "DEEPSEEK_API_KEY",
        subscription: false,
        hint: "DeepSeek's own API, cheaper still than through a router.",
        recommended_model: None,
    },
    ProviderInfo {
        id: "groq",
        label: "Groq",
        env_var: "GROQ_API_KEY",
        subscription: false,
        hint: "Open models at very high speed.",
        recommended_model: None,
    },
    ProviderInfo {
        id: "mistral",
        label: "Mistral",
        env_var: "MISTRAL_API_KEY",
        subscription: false,
        hint: "Mistral's own API.",
        recommended_model: None,
    },
    ProviderInfo {
        id: "zai",
        label: "Z.ai",
        env_var: "ZAI_API_KEY",
        subscription: false,
        hint: "GLM coding plans.",
        recommended_model: None,
    },
    ProviderInfo {
        id: "together",
        label: "Together",
        env_var: "TOGETHER_API_KEY",
        subscription: false,
        hint: "Open models hosted by Together AI.",
        recommended_model: None,
    },
];

pub fn provider(id: &str) -> Option<&'static ProviderInfo> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// The default when nobody has chosen: cheap enough that a runaway agent is an
/// annoyance rather than an incident.
pub const DEFAULT_PROVIDER: &str = "openrouter";
pub const DEFAULT_MODEL: &str = "deepseek/deepseek-v4-flash";

/// Pi's config directory for the Patchwork agent — deliberately *not* the
/// user's own `~/.pi`. Their agent's settings, packages and logins are theirs;
/// ours are an implementation detail of this app and must not be able to
/// change how their `pi` behaves.
pub fn pi_home() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("patchwork-desktop")
        .join("pi")
}

/// Prepare that directory and return the environment a run needs.
///
/// Pi installs anything listed in `packages` the first time it starts, so the
/// two extensions we depend on — a Claude subscription login, and web access —
/// arrive without us shipping a package manager.
pub fn pi_env(provider_id: Option<&str>, model: Option<&str>) -> Vec<(String, String)> {
    let home = pi_home();
    let _ = std::fs::create_dir_all(&home);

    // `model` arrives as Pi names it: `provider/model-id`, where the model id
    // may itself contain slashes (`openrouter/deepseek/deepseek-v4-flash`).
    let (from_model, model_id) = match model.and_then(|m| m.split_once('/')) {
        Some((p, rest)) => (Some(p.to_string()), Some(rest.to_string())),
        None => (None, None),
    };
    let provider = provider_id
        .filter(|p| !p.is_empty())
        .map(|p| p.to_string())
        .or(from_model)
        .unwrap_or_else(|| DEFAULT_PROVIDER.to_string());
    let model_id = model_id.unwrap_or_else(|| DEFAULT_MODEL.to_string());

    // A subscription is a way of paying, not a provider Pi knows by that name.
    let pi_provider = match provider.as_str() {
        "anthropic-oauth" => "anthropic",
        other => other,
    };

    let settings = serde_json::json!({
        "defaultProvider": pi_provider,
        "defaultModel": model_id,
        "quietStartup": true,
        // pi-anthropic-auth is what makes a Claude subscription usable here;
        // pi-web-access is the one capability an agent in a worktree cannot
        // improvise for itself.
        "packages": ["npm:@gotgenes/pi-anthropic-auth", "npm:pi-web-access"],
    });
    // Rewritten every run on purpose: the agent's provider is workspace state,
    // and a stale file here would quietly outrank it.
    let _ = std::fs::write(
        home.join("settings.json"),
        serde_json::to_string_pretty(&settings).unwrap_or_default(),
    );

    vec![(
        "PI_CODING_AGENT_DIR".into(),
        home.to_string_lossy().to_string(),
    )]
}

/// The command that signs Pi into a subscription on this machine. It has to be
/// run in a terminal because the flow is a browser login and a pasted code —
/// there is nothing here we could do for the user in the background. It opens
/// Pi itself, where `/login` does the rest; that is the adapter's own blessed
/// path for exactly this, rather than a flow we invented and have to maintain.
pub fn login_command(_provider_id: &str) -> String {
    format!(
        "PI_CODING_AGENT_DIR={} npx -y --package pi-acp --package {} -- pi-acp --terminal-login",
        pi_home().to_string_lossy(),
        "@earendil-works/pi-coding-agent",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn written(env: &[(String, String)]) -> serde_json::Value {
        let home = std::path::Path::new(&env[0].1);
        serde_json::from_str(&std::fs::read_to_string(home.join("settings.json")).unwrap())
            .unwrap()
    }

    /// One test, not two: both write the same file, and a second thread
    /// rewriting it mid-assert is a flake nobody would enjoy chasing.
    #[test]
    fn a_model_id_carries_its_provider() {
        let env = pi_env(None, Some("openrouter/deepseek/deepseek-v4-flash"));
        assert_eq!(env[0].0, "PI_CODING_AGENT_DIR");
        let settings = written(&env);
        assert_eq!(settings["defaultProvider"], "openrouter");
        assert_eq!(settings["defaultModel"], "deepseek/deepseek-v4-flash");

        // A subscription is a way of paying for a provider, not one of its own.
        let settings = written(&pi_env(Some("anthropic-oauth"), None));
        assert_eq!(settings["defaultProvider"], "anthropic");
        assert_eq!(settings["defaultModel"], DEFAULT_MODEL);
    }
}
