//! The relay as a command: the same service Desktop can host, run standalone
//! on a VPS.

use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;
use patchwork_relay::{default_data_dir, mint_invite, start, Config};

#[derive(Parser, Debug)]
#[command(name = "patchwork-relay", version, about = "The Patchwork relay")]
struct Args {
    /// Where the databases, uploaded files and worktrees live.
    #[arg(long, env = "PATCHWORK_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// 7717 belongs to an older, unrelated Patchwork; stay off it.
    #[arg(long, env = "PATCHWORK_PORT", default_value_t = 7727)]
    port: u16,

    #[arg(long, env = "PATCHWORK_BIND", default_value = "0.0.0.0")]
    bind: String,

    /// The URL desktops and agents should call back on.
    #[arg(long, env = "PATCHWORK_PUBLIC_URL")]
    public_url: Option<String>,

    /// Name used the first time a workspace is created.
    #[arg(long, default_value = "Patchwork")]
    workspace_name: String,

    /// Print a fresh admin invite code and exit.
    #[arg(long)]
    invite: bool,

    /// Which workspace `--invite` belongs to. Defaults to the oldest one.
    #[arg(long)]
    workspace: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "patchwork_relay=info,patchwork_agent=info,warn".into()),
        )
        .with_target(false)
        .init();

    let args = Args::parse();
    let config = Config {
        data_dir: args.data_dir.clone().unwrap_or_else(default_data_dir),
        bind: args.bind.clone(),
        port: args.port,
        public_url: args.public_url.clone(),
        // A standalone relay inherits its own environment, so agents it runs
        // read the keys it was started with.
        agent_env: Vec::new(),
    };

    // `--invite` never takes the port: it is normally run while the relay it
    // mints for is already serving.
    if args.invite {
        println!(
            "{}",
            mint_invite(&config.data_dir, args.workspace.as_deref())?
        );
        return Ok(());
    }

    let handle = start(config).await?;

    if handle.relay.is_empty().await {
        let (state, code) = handle.relay.create(&args.workspace_name).await?;
        let workspace = state.store.workspace()?;
        println!();
        println!("  Patchwork is ready.");
        println!();
        println!("  Relay URL:   {}", handle.public_url);
        println!("  Workspace:   {} ({})", workspace.name, workspace.id);
        println!("  Invite code: {code}");
        println!();
        println!("  Open the Desktop app and join with the URL and the code.");
        println!();
    }

    shutdown_signal().await;
    handle.shutdown().await;
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.ok();
    };
    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            signal.recv().await;
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    tracing::info!("shutting down");
}
