//! `patchwork` — an agent's native access to the workspace it lives in.
//!
//! It is pre-authenticated inside a run: the runner passes `PATCHWORK_API_BASE`
//! and a run-scoped `PATCHWORK_TOKEN`, so an agent never handles credentials.

use anyhow::{anyhow, bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use patchwork_core::host::RunControlMode;
use patchwork_core::models::*;
use patchwork_core::now_ms;
use patchwork_core::wire::*;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};

#[derive(Parser)]
#[command(
    name = "patchwork",
    version,
    about = "Talk to your Patchwork workspace",
    long_about = "Read the conversation, post updates, manage tasks, ask the user a question, \
attach evidence, expose previews and create automations — from inside an agent run."
)]
struct Cli {
    /// Machine-readable output.
    #[arg(long, global = true)]
    json: bool,

    /// Relay URL. Defaults to $PATCHWORK_API_BASE.
    #[arg(long, global = true, env = "PATCHWORK_API_BASE")]
    api_base: Option<String>,

    /// Defaults to $PATCHWORK_TOKEN.
    #[arg(long, global = true, env = "PATCHWORK_TOKEN", hide_env_values = true)]
    token: Option<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Who you are and what you are working on.
    Whoami,
    /// The full context of this run: task, project, worktree, conversation.
    Context,
    /// Recent messages in a conversation.
    History(HistoryArgs),
    /// Search conversations, tasks and past outcomes.
    Search(SearchArgs),
    /// Post a message in the conversation.
    Say(SayArgs),
    /// Post a concise progress note.
    Status(SayArgs),
    /// List ACP runs that can receive a direct message.
    Runs,
    /// Send information directly to another active ACP run.
    Tell(TellArgs),
    /// Ask the user a question and wait for the answer.
    Ask(AskArgs),
    /// Attach a file as evidence.
    Attach(AttachArgs),
    /// List or remove evidence attached to the current task.
    #[command(subcommand)]
    Evidence(EvidenceCommand),
    /// Post a chart from a Flint chart spec.
    Chart(ChartArgs),
    /// Expose a dev server you started as a task preview.
    Preview(PreviewArgs),
    /// Link a pull request to the current task.
    Pr { url: String },
    /// Read and change workspace settings.
    #[command(subcommand)]
    Workspace(WorkspaceCommand),
    /// Create and manage agents.
    #[command(subcommand)]
    Agent(AgentCommand),
    /// Invite people to the workspace.
    #[command(subcommand)]
    Invite(InviteCommand),
    /// Read and create channels.
    #[command(subcommand)]
    Channel(ChannelCommand),
    /// Call any relay API endpoint.
    Api(ApiArgs),
    /// Read and change tasks.
    #[command(subcommand)]
    Task(TaskCommand),
    /// Read and create automations.
    #[command(subcommand)]
    Automation(AutomationCommand),
}

#[derive(Args)]
struct HistoryArgs {
    /// Channel id or `#slug`. Defaults to this run's conversation.
    #[arg(long)]
    channel: Option<String>,
    #[arg(long, default_value_t = 40)]
    limit: usize,
}

#[derive(Args)]
struct SearchArgs {
    query: Vec<String>,
    #[arg(long, default_value_t = 20)]
    limit: usize,
}

#[derive(Args)]
struct SayArgs {
    /// The message. Multiple words are joined.
    text: Vec<String>,
    /// Post somewhere else: `#deploys`, a channel name, or a channel id.
    #[arg(long)]
    channel: Option<String>,
}

#[derive(Args)]
struct TellArgs {
    /// Active run id or task key, e.g. PW-14.
    target: String,
    /// Plain-text information for that independent run.
    text: Vec<String>,
}

#[derive(Args)]
struct AskArgs {
    /// The question to ask.
    #[arg(long)]
    question: String,
    /// Short chip label, e.g. "Auth method".
    #[arg(long, default_value = "")]
    header: String,
    /// `Label:description`. Repeat for each choice.
    #[arg(long = "option")]
    options: Vec<String>,
    /// Allow selecting more than one option.
    #[arg(long)]
    multi: bool,
    /// Require one of the options.
    #[arg(long)]
    no_free_text: bool,
    /// Cancel the question this run already asked and ask this one instead.
    #[arg(long)]
    replace: bool,
}

#[derive(Args)]
struct AttachArgs {
    path: String,
    #[arg(long, default_value = "")]
    caption: String,
    /// Replace an earlier evidence attachment (its id) with this file.
    #[arg(long)]
    replace: Option<String>,
}

#[derive(Subcommand)]
enum EvidenceCommand {
    /// List evidence attached to the current task.
    List,
    /// Remove an attachment from the current task's review evidence.
    Remove { attachment_id: String },
}

#[derive(Args)]
struct ChartArgs {
    /// File holding the Flint chart spec, or `-` for stdin.
    spec: String,
    /// One line saying what the chart shows.
    #[arg(long, default_value = "")]
    caption: String,
    #[arg(long)]
    channel: Option<String>,
}

#[derive(Args)]
struct PreviewArgs {
    #[arg(long)]
    port: Option<u16>,
    /// Command that starts the dev server. Omit it for an existing server.
    #[arg(long)]
    command: Option<String>,
    #[arg(long)]
    label: Option<String>,
}

#[derive(Subcommand)]
enum WorkspaceCommand {
    Show,
    Update {
        #[arg(long)]
        name: Option<String>,
        /// An emoji. Clears a custom image when supplied.
        #[arg(long)]
        icon: Option<String>,
        /// A PNG or JPEG file, up to 2 MB.
        #[arg(long, conflicts_with = "icon")]
        icon_file: Option<String>,
        #[arg(long)]
        task_prefix: Option<String>,
    },
}

#[derive(Subcommand)]
enum AgentCommand {
    List,
    Create {
        name: String,
        #[arg(long, default_value = "")]
        description: String,
        #[arg(long, default_value = "codex")]
        runtime: String,
        #[arg(long, default_value = "auto")]
        location: String,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        thinking: Option<String>,
        #[arg(long)]
        admin: bool,
    },
    Update {
        /// Id, @handle, or display name.
        reference: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        description: Option<String>,
        #[arg(long)]
        runtime: Option<String>,
        #[arg(long)]
        location: Option<String>,
        #[arg(long)]
        host: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        thinking: Option<String>,
        /// `true` to grant workspace administration, `false` to revoke it.
        #[arg(long)]
        admin: Option<bool>,
    },
    Delete {
        /// Id, @handle, or display name.
        reference: String,
    },
}

#[derive(Subcommand)]
enum InviteCommand {
    List,
    Create {
        #[arg(long)]
        email: Option<String>,
        #[arg(long)]
        admin: bool,
    },
}

#[derive(Args)]
struct ApiArgs {
    /// GET, POST, PATCH, or DELETE.
    method: String,
    /// Relay path, for example `/api/projects`.
    path: String,
    /// JSON, `@file.json`, or `-` for stdin.
    #[arg(long)]
    body: Option<String>,
}

#[derive(Subcommand)]
enum ChannelCommand {
    List,
    Create {
        name: String,
        /// Section name. It is created when it does not exist.
        #[arg(long)]
        section: Option<String>,
        #[arg(long, default_value = "")]
        topic: String,
    },
    Update {
        /// Id, #slug, or name.
        reference: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        section: Option<String>,
        #[arg(long)]
        topic: Option<String>,
    },
    Archive {
        /// Id, #slug, or name.
        reference: String,
    },
}

#[derive(Subcommand)]
enum TaskCommand {
    List {
        #[arg(long)]
        status: Option<String>,
        /// Only tasks you own.
        #[arg(long)]
        mine: bool,
    },
    Show {
        /// Task id or key, e.g. PW-14.
        reference: String,
    },
    Create {
        /// Optional: derived from the first line of `--outcome` when omitted.
        #[arg(long, default_value = "")]
        title: String,
        #[arg(long, default_value = "")]
        outcome: String,
        /// `@handle` of the owner, or `@me` for yourself. A person, when the
        /// task is for a person.
        #[arg(long)]
        owner: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        project: Option<String>,
        /// `YYYY-MM-DD`. It reaches the owner's Inbox on the day.
        #[arg(long)]
        due: Option<String>,
        /// Your own name for what this is about. Creating it again with the
        /// same key returns the open task instead of making a second one.
        #[arg(long)]
        once: Option<String>,
        /// Create after reviewing the relay's possible-duplicate warning.
        #[arg(long)]
        allow_similar: bool,
        /// Start the owning agent right away (automatic for agent-owned tasks).
        #[arg(long)]
        start: bool,
    },
    Update {
        reference: String,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        outcome: Option<String>,
        #[arg(long)]
        status: Option<String>,
        #[arg(long)]
        owner: Option<String>,
        #[arg(long)]
        project: Option<String>,
        /// `YYYY-MM-DD`, or `none` to clear it.
        #[arg(long)]
        due: Option<String>,
        #[arg(long)]
        pr: Option<String>,
        /// File proving the work is ready to review.
        #[arg(long)]
        evidence: Option<String>,
        /// Exact action a person can approve in review, e.g. "Approve and merge PR".
        #[arg(long)]
        approval: Option<String>,
    },
    /// Hand a long-lived external wait to the relay, then let this run finish.
    Wait {
        /// What the task is waiting for, shown on the board.
        #[arg(long)]
        summary: String,
        /// Relay-side shell command that checks the external work.
        #[arg(long)]
        command: String,
        /// Seconds between checks.
        #[arg(long, default_value_t = 60)]
        every: i64,
        /// Seconds from now before the wait escalates for human action.
        #[arg(long)]
        deadline: i64,
        /// Instruction for the fresh agent run started when the checker is ready.
        #[arg(long)]
        wake: String,
    },
    Delete {
        reference: String,
    },
}

#[derive(Subcommand)]
enum AutomationCommand {
    List,
    Create {
        #[arg(long)]
        name: String,
        /// `@handle` of the agent that should act.
        #[arg(long)]
        agent: String,
        /// `schedule`, `watch`, `message`, `task-status`, `task-assigned`,
        /// `pull-request`, `webhook` or `manual`.
        #[arg(long)]
        trigger: String,
        /// `post-in-chat`, `create-task` or `continue-task`.
        #[arg(long, default_value = "post-in-chat")]
        action: String,
        #[arg(long, default_value = "")]
        instructions: String,
        /// Seconds between runs, for `--trigger schedule` and `--trigger watch`.
        #[arg(long)]
        every: Option<i64>,
        /// Shell command for `--trigger watch`. Exit 0 with no output is a
        /// healthy no-op. Findings must be one JSON object per line with
        /// `event_key`, `condition_key`, task `title`/`outcome`, and `context`.
        /// The command is test-run before the watch is enabled.
        /// `$PATCHWORK_STATE_DIR` is its own directory, kept between polls.
        #[arg(long)]
        command: Option<String>,
        /// Channel for message triggers and for reporting.
        #[arg(long)]
        channel: Option<String>,
        /// Task status for `--trigger task-status`.
        #[arg(long)]
        status: Option<String>,
        /// One task to watch, for `--trigger task-status`. Without it, every
        /// task entering that status fires.
        #[arg(long)]
        task: Option<String>,
    },
    /// Everything about one automation, including its last firings.
    Show {
        /// Id or name.
        reference: String,
    },
    Run {
        id: String,
    },
    /// Run and validate a watch command without firing its action.
    Test {
        /// Id or name.
        reference: String,
    },
    /// Stop it firing, without losing it.
    Pause {
        reference: String,
    },
    Resume {
        reference: String,
    },
    Delete {
        reference: String,
    },
}

struct Client {
    base: String,
    token: String,
    http: reqwest::Client,
    json: bool,
}

impl Client {
    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base.trim_end_matches('/'), path)
    }

    async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let response = self
            .http
            .get(self.url(path))
            .bearer_auth(&self.token)
            .send()
            .await?;
        parse(response).await
    }

    async fn post<T: DeserializeOwned>(&self, path: &str, body: Value) -> Result<T> {
        let response = self
            .http
            .post(self.url(path))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?;
        parse(response).await
    }

    async fn patch<T: DeserializeOwned>(&self, path: &str, body: Value) -> Result<T> {
        let response = self
            .http
            .patch(self.url(path))
            .bearer_auth(&self.token)
            .json(&body)
            .send()
            .await?;
        parse(response).await
    }

    async fn delete<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let response = self
            .http
            .delete(self.url(path))
            .bearer_auth(&self.token)
            .send()
            .await?;
        parse(response).await
    }

    fn print(&self, value: &impl serde::Serialize, human: impl FnOnce()) {
        if self.json {
            println!(
                "{}",
                serde_json::to_string_pretty(value).unwrap_or_else(|_| "null".into())
            );
        } else {
            human();
        }
    }
}

async fn parse<T: DeserializeOwned>(response: reqwest::Response) -> Result<T> {
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        let message = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_else(|| text.clone());
        bail!("{status}: {message}");
    }
    serde_json::from_str(&text).with_context(|| format!("unexpected response: {text}"))
}

#[derive(Clone)]
struct RunContext {
    run_id: Option<String>,
    task_id: Option<String>,
    channel_id: Option<String>,
    agent_id: Option<String>,
}

fn run_context() -> RunContext {
    let get = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
    RunContext {
        run_id: get("PATCHWORK_RUN_ID"),
        task_id: get("PATCHWORK_TASK_ID"),
        channel_id: get("PATCHWORK_CHANNEL_ID"),
        agent_id: get("PATCHWORK_AGENT_ID"),
    }
}

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("patchwork: {err:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let cli = Cli::parse();
    let base = cli
        .api_base
        .clone()
        .ok_or_else(|| anyhow!("no relay URL: set PATCHWORK_API_BASE or pass --api-base"))?;
    let token = cli
        .token
        .clone()
        .ok_or_else(|| anyhow!("no token: set PATCHWORK_TOKEN or pass --token"))?;

    let client = Client {
        base,
        token,
        http: reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(120))
            .build()?,
        json: cli.json,
    };
    let ctx = run_context();

    match cli.command {
        Command::Whoami => whoami(&client, &ctx, false).await,
        Command::Context => whoami(&client, &ctx, true).await,
        Command::History(args) => history(&client, &ctx, args).await,
        Command::Search(args) => search(&client, args).await,
        Command::Say(args) => say(&client, &ctx, args, MessageKind::Text).await,
        Command::Status(args) => say(&client, &ctx, args, MessageKind::Status).await,
        Command::Runs => active_runs(&client).await,
        Command::Tell(args) => tell(&client, args).await,
        Command::Ask(args) => ask(&client, &ctx, args).await,
        Command::Attach(args) => attach(&client, &ctx, args).await,
        Command::Evidence(command) => evidence(&client, &ctx, command).await,
        Command::Chart(args) => chart(&client, &ctx, args).await,
        Command::Preview(args) => preview(&client, &ctx, args).await,
        Command::Pr { url } => link_pr(&client, &ctx, url).await,
        Command::Workspace(command) => workspace(&client, command).await,
        Command::Agent(command) => agent(&client, command).await,
        Command::Invite(command) => invite(&client, command).await,
        Command::Channel(command) => channel(&client, command).await,
        Command::Api(args) => raw_api(&client, args).await,
        Command::Task(command) => task(&client, &ctx, command).await,
        Command::Automation(command) => automation(&client, &ctx, command).await,
    }
}

// ---------------------------------------------------------------------------

async fn whoami(client: &Client, ctx: &RunContext, full: bool) -> Result<()> {
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    let task = match &ctx.task_id {
        Some(id) => Some(
            client
                .get::<TaskDetail>(&format!("/api/tasks/{id}"))
                .await?,
        ),
        None => None,
    };

    // Anyone else working on this task is in the same worktree as you.
    let peers: Vec<&Run> = task
        .as_ref()
        .map(|detail| {
            detail
                .runs
                .iter()
                .filter(|run| !run.status.is_terminal() && Some(&run.id) != ctx.run_id.as_ref())
                .collect()
        })
        .unwrap_or_default();

    let payload = json!({
        "me": bootstrap.me,
        "workspace": bootstrap.workspace.name,
        "autonomy": bootstrap.workspace.autonomy,
        "run_id": ctx.run_id,
        "channel_id": ctx.channel_id,
        "task": task.as_ref().map(|t| &t.task),
        "worktree": task.as_ref().and_then(|t| t.worktree.clone()),
        "cwd": std::env::var("PATCHWORK_CWD").ok(),
        "peers": peers,
    });

    client.print(&payload, || {
        println!(
            "You are {} (@{})",
            bootstrap.me.display_name, bootstrap.me.handle
        );
        println!("Workspace: {}", bootstrap.workspace.name);
        if !bootstrap.workspace.autonomy.trim().is_empty() {
            println!("\nAUTONOMY.md:\n{}", bootstrap.workspace.autonomy.trim());
        }
        if let Some(channel) = bootstrap
            .channels
            .iter()
            .find(|c| Some(&c.id) == ctx.channel_id.as_ref())
        {
            println!("Conversation: {}", channel_label(channel));
        }
        if let Some(detail) = &task {
            println!(
                "Task {} [{}] — {}",
                detail.task.key,
                detail.task.status.as_str(),
                detail.task.title
            );
            if !detail.task.outcome.trim().is_empty() {
                println!("Expected result: {}", detail.task.outcome.trim());
            }
            if let Some(worktree) = &detail.worktree {
                println!("Worktree: {} ({})", worktree.path, worktree.branch);
            }
            if !peers.is_empty() {
                println!("Also working here right now:");
                for run in &peers {
                    let agent = bootstrap
                        .members
                        .iter()
                        .find(|member| member.id == run.agent_id)
                        .map(|member| format!("{} (@{})", member.display_name, member.handle))
                        .unwrap_or_else(|| "another agent".into());
                    println!(
                        "  {agent} — run {} [{}] {}",
                        run.id,
                        run.status.as_str(),
                        run.headline
                    );
                }
                println!("Reach them with `patchwork tell <run-id> \"…\"`.");
            }
            if full {
                for run in detail.runs.iter().take(5) {
                    println!(
                        "  run {} [{}] {}",
                        &run.id[..8],
                        run.status.as_str(),
                        run.headline
                    );
                }
            }
        }
    });
    Ok(())
}

fn channel_label(channel: &Channel) -> String {
    match channel.kind {
        ChannelKind::Channel => format!("#{}", channel.slug),
        ChannelKind::Dm => format!("DM: {}", channel.name),
        ChannelKind::Task => channel.name.clone(),
    }
}

async fn workspace(client: &Client, command: WorkspaceCommand) -> Result<()> {
    match command {
        WorkspaceCommand::Show => {
            let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
            client.print(&bootstrap.workspace, || {
                println!("{}", bootstrap.workspace.name)
            });
        }
        WorkspaceCommand::Update {
            name,
            icon,
            icon_file,
            task_prefix,
        } => {
            let icon_file_id = match icon_file {
                Some(path) => Some(upload_file(client, &path, "", None).await?.id),
                None => None,
            };
            let updated: Workspace = client
                .patch(
                    "/api/workspace",
                    json!({
                        "name": name,
                        "icon": icon,
                        "icon_file_id": icon_file_id,
                        "task_prefix": task_prefix
                    }),
                )
                .await?;
            client.print(&updated, || println!("workspace updated"));
        }
    }
    Ok(())
}

async fn resolve_agent(client: &Client, reference: &str) -> Result<Member> {
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    let wanted = reference.trim_start_matches('@');
    bootstrap
        .members
        .into_iter()
        .find(|member| {
            member.kind == MemberKind::Agent
                && (member.id == reference
                    || member.handle.eq_ignore_ascii_case(wanted)
                    || member.display_name.eq_ignore_ascii_case(wanted))
        })
        .ok_or_else(|| anyhow!("no agent called {reference}"))
}

fn location(value: &str) -> Result<&str> {
    match value {
        "auto" | "relay" | "desktop" => Ok(value),
        _ => bail!("location must be auto, relay, or desktop"),
    }
}

fn optional_value(value: String) -> Value {
    if value.eq_ignore_ascii_case("none") {
        Value::Null
    } else {
        Value::String(value)
    }
}

async fn agent(client: &Client, command: AgentCommand) -> Result<()> {
    match command {
        AgentCommand::List => {
            let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
            let agents: Vec<_> = bootstrap
                .members
                .into_iter()
                .filter(|member| member.kind == MemberKind::Agent)
                .collect();
            client.print(&agents, || {
                for agent in &agents {
                    println!(
                        "@{}{} — {}",
                        agent.handle,
                        if agent.is_admin { " (admin)" } else { "" },
                        agent
                            .agent
                            .as_ref()
                            .map(|p| p.runtime.as_str())
                            .unwrap_or("")
                    );
                }
            });
        }
        AgentCommand::Create {
            name,
            description,
            runtime,
            location: place,
            host,
            model,
            thinking,
            admin,
        } => {
            let created: Member = client
                .post(
                    "/api/agents",
                    json!({
                        "display_name": name,
                        "is_admin": admin,
                        "profile": {
                            "description": description,
                            "runtime": runtime,
                            "location": location(&place)?,
                            "host_id": host,
                            "dm_enabled": true,
                            "default_participation": "mention",
                            "channel_participation": {},
                            "model": model,
                            "thinking": thinking
                        }
                    }),
                )
                .await?;
            client.print(&created, || println!("created @{}", created.handle));
        }
        AgentCommand::Update {
            reference,
            name,
            description,
            runtime,
            location: place,
            host,
            model,
            thinking,
            admin,
        } => {
            let current = resolve_agent(client, &reference).await?;
            let mut profile = serde_json::to_value(current.agent.unwrap_or_default())?;
            if let Some(value) = description {
                profile["description"] = json!(value);
            }
            if let Some(value) = runtime {
                profile["runtime"] = json!(value);
            }
            if let Some(value) = place {
                profile["location"] = json!(location(&value)?);
            }
            if let Some(value) = host {
                profile["host_id"] = optional_value(value);
            }
            if let Some(value) = model {
                profile["model"] = optional_value(value);
            }
            if let Some(value) = thinking {
                profile["thinking"] = optional_value(value);
            }
            let updated: Member = client
                .patch(
                    &format!("/api/agents/{}", current.id),
                    json!({ "display_name": name, "is_admin": admin, "profile": profile }),
                )
                .await?;
            client.print(&updated, || println!("updated @{}", updated.handle));
        }
        AgentCommand::Delete { reference } => {
            let agent = resolve_agent(client, &reference).await?;
            let _: Value = client.delete(&format!("/api/members/{}", agent.id)).await?;
            client.print(&json!({ "deleted": agent.id }), || {
                println!("removed @{}", agent.handle)
            });
        }
    }
    Ok(())
}

async fn invite(client: &Client, command: InviteCommand) -> Result<()> {
    match command {
        InviteCommand::List => {
            let invites: Vec<Invite> = client.get("/api/invites").await?;
            client.print(&invites, || {
                for invite in &invites {
                    println!(
                        "{}{}{}",
                        invite.code,
                        invite
                            .email
                            .as_ref()
                            .map(|email| format!(" — {email}"))
                            .unwrap_or_default(),
                        if invite.is_admin { " (admin)" } else { "" }
                    );
                }
            });
        }
        InviteCommand::Create { email, admin } => {
            let created: Invite = client
                .post("/api/invites", json!({ "email": email, "is_admin": admin }))
                .await?;
            client.print(&created, || {
                let relay = client.base.split("/w/").next().unwrap_or(&client.base);
                println!("Relay URL: {relay}\nInvite code: {}", created.code);
            });
        }
    }
    Ok(())
}

async fn raw_api(client: &Client, args: ApiArgs) -> Result<()> {
    use std::io::Read;

    let path = if args.path.starts_with('/') {
        args.path
    } else {
        format!("/{}", args.path)
    };
    let body = match args.body {
        Some(value) if value == "-" => {
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input)?;
            serde_json::from_str(&input)?
        }
        Some(value) if value.starts_with('@') => {
            serde_json::from_str(&std::fs::read_to_string(&value[1..])?)?
        }
        Some(value) => serde_json::from_str(&value)?,
        None => json!({}),
    };
    let result: Value = match args.method.to_ascii_uppercase().as_str() {
        "GET" => client.get(&path).await?,
        "POST" => client.post(&path, body).await?,
        "PATCH" => client.patch(&path, body).await?,
        "DELETE" => client.delete(&path).await?,
        _ => bail!("method must be GET, POST, PATCH, or DELETE"),
    };
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}

async fn resolve_public_channel(client: &Client, reference: &str) -> Result<Channel> {
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    let wanted = reference.trim_start_matches('#');
    bootstrap
        .channels
        .into_iter()
        .find(|channel| {
            channel.kind == ChannelKind::Channel
                && (channel.id == reference
                    || channel.slug == wanted
                    || channel.name.eq_ignore_ascii_case(wanted))
        })
        .ok_or_else(|| anyhow!("no channel called {reference}"))
}

async fn section_id(client: &Client, name: &str) -> Result<String> {
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    if let Some(section) = bootstrap
        .sections
        .into_iter()
        .find(|section| section.name.eq_ignore_ascii_case(name))
    {
        return Ok(section.id);
    }
    let section: Section = client
        .post("/api/sections", json!({ "name": name }))
        .await?;
    Ok(section.id)
}

async fn channel(client: &Client, command: ChannelCommand) -> Result<()> {
    match command {
        ChannelCommand::List => {
            let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
            let channels: Vec<_> = bootstrap
                .channels
                .iter()
                .filter(|channel| channel.kind == ChannelKind::Channel)
                .cloned()
                .collect();
            client.print(&channels, || {
                for channel in &channels {
                    let section = channel
                        .section_id
                        .as_ref()
                        .and_then(|id| bootstrap.sections.iter().find(|section| &section.id == id))
                        .map(|section| format!(" ({})", section.name))
                        .unwrap_or_default();
                    println!("#{}{}", channel.slug, section);
                }
            });
        }
        ChannelCommand::Create {
            name,
            section,
            topic,
        } => {
            let created: Channel = client
                .post(
                    "/api/channels",
                    json!({ "name": name, "section_name": section, "topic": topic }),
                )
                .await?;
            client.print(&created, || println!("created #{}", created.slug));
        }
        ChannelCommand::Update {
            reference,
            name,
            section,
            topic,
        } => {
            let channel = resolve_public_channel(client, &reference).await?;
            let section_id = match section {
                Some(value) if value.eq_ignore_ascii_case("none") => Some(String::new()),
                Some(value) => Some(section_id(client, &value).await?),
                None => None,
            };
            let updated: Channel = client
                .patch(
                    &format!("/api/channels/{}", channel.id),
                    json!({ "name": name, "section_id": section_id, "topic": topic }),
                )
                .await?;
            client.print(&updated, || println!("updated #{}", updated.slug));
        }
        ChannelCommand::Archive { reference } => {
            let channel = resolve_public_channel(client, &reference).await?;
            let _: Value = client
                .delete(&format!("/api/channels/{}", channel.id))
                .await?;
            client.print(&json!({ "archived": channel.id }), || {
                println!("archived #{}", channel.slug)
            });
        }
    }
    Ok(())
}

/// A conversation by whatever an agent is likely to have: `#deploys`, the
/// name on its own, a DM partner's `@handle`, or an id copied from a link.
/// Being strict here meant an agent that wanted to post an update in another
/// channel got a "not found" for writing the name the way people write it.
/// `YYYY-MM-DD` at local midnight, which is what a due date means.
fn parse_due(value: &str) -> Result<i64> {
    use chrono::TimeZone;
    let value = value.trim();
    if value.is_empty() || value.eq_ignore_ascii_case("none") {
        return Ok(0);
    }
    let parts: Vec<&str> = value.split('-').collect();
    let [year, month, day] = parts.as_slice() else {
        bail!("a due date looks like 2026-08-14, not `{value}`");
    };
    let date = chrono::NaiveDate::from_ymd_opt(year.parse()?, month.parse()?, day.parse()?)
        .ok_or_else(|| anyhow!("there is no such date as {value}"))?;
    let naive = date.and_hms_opt(0, 0, 0).unwrap();
    Ok(chrono::Local
        .from_local_datetime(&naive)
        .single()
        .ok_or_else(|| anyhow!("ambiguous local date {value}"))?
        .timestamp_millis())
}

async fn resolve_channel(
    client: &Client,
    ctx: &RunContext,
    given: Option<String>,
) -> Result<String> {
    let Some(reference) = given else {
        return ctx
            .channel_id
            .clone()
            .ok_or_else(|| anyhow!("no conversation in context: pass --channel"));
    };

    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    if bootstrap.channels.iter().any(|c| c.id == reference) {
        return Ok(reference);
    }

    let wanted = reference.trim_start_matches('#').trim_start_matches('@');
    if let Some(channel) = bootstrap.channels.iter().find(|c| {
        c.kind == ChannelKind::Channel && (c.slug == wanted || c.name.eq_ignore_ascii_case(wanted))
    }) {
        return Ok(channel.id.clone());
    }

    // A DM, named by who is in it.
    let partner = bootstrap.members.iter().find(|m| {
        m.handle.eq_ignore_ascii_case(wanted) || m.display_name.eq_ignore_ascii_case(wanted)
    });
    if let Some(partner) = partner {
        if let Some(channel) = bootstrap
            .channels
            .iter()
            .find(|c| c.kind == ChannelKind::Dm && c.member_ids.contains(&partner.id))
        {
            return Ok(channel.id.clone());
        }
        let channel: Channel = client
            .post("/api/channels/dm", json!({ "member_id": partner.id }))
            .await?;
        return Ok(channel.id);
    }

    Err(anyhow!("no conversation called {reference}"))
}

async fn history(client: &Client, ctx: &RunContext, args: HistoryArgs) -> Result<()> {
    let channel_id = resolve_channel(client, ctx, args.channel).await?;
    let page: MessagePage = client
        .get(&format!(
            "/api/channels/{channel_id}/messages?limit={}",
            args.limit
        ))
        .await?;
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    let names: std::collections::HashMap<_, _> = bootstrap
        .members
        .iter()
        .map(|m| (m.id.clone(), m.display_name.clone()))
        .collect();

    client.print(&page, || {
        for message in &page.messages {
            let author = names
                .get(&message.author_id)
                .cloned()
                .unwrap_or_else(|| "unknown".into());
            match message.kind {
                MessageKind::Card => {
                    if let Some(card) = &message.card {
                        println!("[{author}] ({})", card_label(card));
                    }
                }
                _ => println!("[{author}] {}", message.body),
            }
        }
    });
    Ok(())
}

fn card_label(card: &MessageCard) -> &'static str {
    match card {
        MessageCard::Task { .. } => "task card",
        MessageCard::Run { .. } => "run card",
        MessageCard::Question { .. } => "question",
        MessageCard::Artifact { .. } => "artifact",
        MessageCard::Preview { .. } => "preview",
        MessageCard::PullRequest { .. } => "pull request",
        MessageCard::Chart { .. } => "chart",
    }
}

async fn search(client: &Client, args: SearchArgs) -> Result<()> {
    let query = args.query.join(" ");
    if query.trim().is_empty() {
        bail!("what should I search for?");
    }
    let results: SearchResults = client
        .get(&format!(
            "/api/search?q={}&limit={}",
            urlencode(&query),
            args.limit
        ))
        .await?;
    client.print(&results, || {
        if !results.tasks.is_empty() {
            println!("Tasks:");
            for task in &results.tasks {
                println!("  {} [{}] {}", task.key, task.status.as_str(), task.title);
            }
        }
        if !results.messages.is_empty() {
            println!("Messages:");
            for hit in &results.messages {
                println!(
                    "  {} in {}: {}",
                    hit.author_name, hit.channel_name, hit.snippet
                );
            }
        }
        if results.tasks.is_empty() && results.messages.is_empty() {
            println!("nothing found");
        }
    });
    Ok(())
}

async fn active_runs(client: &Client) -> Result<()> {
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    client.print(&bootstrap.active_runs, || {
        for run in &bootstrap.active_runs {
            let agent = bootstrap
                .members
                .iter()
                .find(|member| member.id == run.agent_id)
                .map(|member| member.display_name.as_str())
                .unwrap_or("agent");
            let task = run
                .task_id
                .as_deref()
                .and_then(|id| bootstrap.tasks.iter().find(|task| task.id == id));
            match task {
                Some(task) => println!("{}  {}  {}: {}", run.id, agent, task.key, task.title),
                None => println!("{}  {}  {}", run.id, agent, run.headline),
            }
        }
    });
    Ok(())
}

async fn tell(client: &Client, args: TellArgs) -> Result<()> {
    let prompt = args.text.join(" ");
    if prompt.trim().is_empty() {
        bail!("nothing to tell the other run");
    }
    let bootstrap: Bootstrap = client.get("/api/bootstrap").await?;
    // A task key reaches everyone working on that task, because several agents
    // can be in it at once and the news is about the task, not about one of
    // them. A run id reaches exactly that run.
    let targets: Vec<String> = if let Some(run) = bootstrap
        .active_runs
        .iter()
        .find(|run| run.id == args.target)
    {
        vec![run.id.clone()]
    } else if let Some(task) = bootstrap
        .tasks
        .iter()
        .find(|task| task.key.eq_ignore_ascii_case(&args.target))
    {
        let runs: Vec<String> = bootstrap
            .active_runs
            .iter()
            .filter(|run| run.task_id.as_deref() == Some(task.id.as_str()))
            .map(|run| run.id.clone())
            .collect();
        if runs.is_empty() {
            bail!("{} has no active run", task.key);
        }
        runs
    } else {
        bail!(
            "no active run or task called `{}`; use `patchwork runs`",
            args.target
        );
    };
    let mut responses = Vec::new();
    for run_id in &targets {
        let response: SteerRunResponse = client
            .post(
                &format!("/api/runs/{run_id}/steer"),
                serde_json::to_value(SteerRun {
                    prompt: prompt.clone(),
                    mode: RunControlMode::Queue,
                    attachment_ids: Vec::new(),
                })?,
            )
            .await?;
        responses.push(response);
    }
    client.print(&responses, || match targets.len() {
        1 => println!("sent"),
        n => println!("sent to {n} runs"),
    });
    Ok(())
}

async fn say(client: &Client, ctx: &RunContext, args: SayArgs, kind: MessageKind) -> Result<()> {
    let body = args.text.join(" ");
    if body.trim().is_empty() {
        bail!("nothing to say");
    }
    let channel_id = resolve_channel(client, ctx, args.channel).await?;
    let message: Message = client
        .post(
            &format!("/api/channels/{channel_id}/messages"),
            json!({ "body": body, "kind": kind, "run_id": ctx.run_id }),
        )
        .await?;
    client.print(&message, || println!("posted"));
    Ok(())
}

/// A chart is data plus what the data means, not a picture: the workspace
/// renders it, so it stays legible on any screen and can be read back later by
/// whoever asks what the numbers actually were.
async fn chart(client: &Client, ctx: &RunContext, args: ChartArgs) -> Result<()> {
    let raw = if args.spec == "-" {
        use std::io::Read;
        let mut buffer = String::new();
        std::io::stdin().read_to_string(&mut buffer)?;
        buffer
    } else {
        std::fs::read_to_string(&args.spec).with_context(|| format!("cannot read {}", args.spec))?
    };

    // Charts ride inside a message row. A spec big enough to matter here is a
    // file the agent should have attached instead.
    const LIMIT: usize = 512 * 1024;
    if raw.len() > LIMIT {
        bail!(
            "that spec is {}KB; summarise or aggregate the data first (limit {}KB)",
            raw.len() / 1024,
            LIMIT / 1024
        );
    }

    let spec: Value = serde_json::from_str(&raw).context("the chart spec is not valid JSON")?;
    if spec
        .get("chart_spec")
        .and_then(|s| s.get("chartType"))
        .is_none()
    {
        bail!("a chart spec needs `chart_spec.chartType` (see the Flint chart format)");
    }
    if spec.get("data").is_none() {
        bail!("a chart spec needs `data.values` or `data.url`");
    }

    let channel_id = resolve_channel(client, ctx, args.channel).await?;
    let card = MessageCard::Chart {
        spec,
        caption: Some(args.caption.clone()).filter(|c| !c.trim().is_empty()),
    };
    let message: Message = client
        .post(
            &format!("/api/channels/{channel_id}/messages"),
            json!({ "body": args.caption, "kind": MessageKind::Card, "card": card, "run_id": ctx.run_id }),
        )
        .await?;
    client.print(&message, || println!("posted"));
    Ok(())
}

async fn ask(client: &Client, ctx: &RunContext, args: AskArgs) -> Result<()> {
    let run_id = ctx
        .run_id
        .clone()
        .ok_or_else(|| anyhow!("`ask` only works inside a run"))?;

    let options: Vec<QuestionOption> = args
        .options
        .iter()
        .map(|raw| match raw.split_once(':') {
            Some((label, description)) => QuestionOption {
                label: label.trim().to_string(),
                description: description.trim().to_string(),
            },
            None => QuestionOption {
                label: raw.trim().to_string(),
                description: String::new(),
            },
        })
        .collect();

    let item = QuestionItem {
        id: "q1".to_string(),
        header: args.header.clone(),
        question: args.question.clone(),
        options,
        allow_free_text: !args.no_free_text,
        multi_select: args.multi,
    };

    let question: Question = client
        .post(
            "/api/questions",
            json!({
                "run_id": run_id,
                "headline": args.header,
                "items": [item],
                "replace": args.replace,
            }),
        )
        .await?;

    // Hold here until a human answers. The relay long-polls in 90s slices.
    let answered = loop {
        let current: Question = client
            .get(&format!("/api/questions/{}/wait", question.id))
            .await?;
        match current.status {
            QuestionStatus::Answered => break current,
            QuestionStatus::Cancelled => bail!("the question was cancelled"),
            QuestionStatus::Open => continue,
        }
    };

    client.print(&answered, || {
        for answer in answered.answers.iter().flatten() {
            let mut parts = answer.values.clone();
            if !answer.note.trim().is_empty() {
                parts.push(answer.note.clone());
            }
            println!("{}", parts.join(", "));
        }
    });
    Ok(())
}

async fn upload_file(
    client: &Client,
    path: &str,
    caption: &str,
    task_id: Option<&str>,
) -> Result<Attachment> {
    let file_name = std::path::Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());
    let size = tokio::fs::metadata(path)
        .await
        .with_context(|| format!("cannot read {path}"))?
        .len();
    let attachment: Attachment = if size > 8 * 1024 * 1024 {
        use tokio::io::AsyncReadExt;

        let upload: UploadSession = client
            .post(
                "/api/uploads",
                json!({
                    "file_name": file_name,
                    "mime": "",
                    "size": size,
                    "caption": caption,
                    "task_id": task_id,
                }),
            )
            .await?;
        let mut file = tokio::fs::File::open(path).await?;
        let mut offset = 0u64;
        loop {
            let mut chunk = vec![0; upload.chunk_size];
            let read = file.read(&mut chunk).await?;
            if read == 0 {
                break;
            }
            chunk.truncate(read);
            let response = client
                .http
                .put(client.url(&format!("/api/uploads/{}?offset={offset}", upload.id)))
                .bearer_auth(&client.token)
                .body(chunk)
                .send()
                .await?;
            let _: Value = parse(response).await?;
            offset += read as u64;
        }
        client
            .post(&format!("/api/uploads/{}/complete", upload.id), json!({}))
            .await?
    } else {
        let bytes = tokio::fs::read(path).await?;
        let mut form = reqwest::multipart::Form::new().part(
            "file",
            reqwest::multipart::Part::bytes(bytes).file_name(file_name),
        );
        if let Some(task_id) = task_id {
            form = form.text("task_id", task_id.to_string());
        }
        if !caption.is_empty() {
            form = form.text("caption", caption.to_string());
        }
        let response = client
            .http
            .post(client.url("/api/files"))
            .bearer_auth(&client.token)
            .multipart(form)
            .send()
            .await?;
        parse(response).await?
    };
    Ok(attachment)
}

async fn upload_attachment(
    client: &Client,
    ctx: &RunContext,
    path: &str,
    caption: &str,
) -> Result<Attachment> {
    let attachment = upload_file(client, path, caption, ctx.task_id.as_deref()).await?;
    if let Some(channel_id) = &ctx.channel_id {
        let _: Message = client
            .post(
                &format!("/api/channels/{channel_id}/messages"),
                json!({
                    "body": caption,
                    "kind": "card",
                    "card": { "type": "artifact", "attachment_id": attachment.id, "caption": caption },
                    "run_id": ctx.run_id,
                }),
            )
            .await?;
    }
    Ok(attachment)
}

async fn attach(client: &Client, ctx: &RunContext, args: AttachArgs) -> Result<()> {
    if let Some(replaced) = &args.replace {
        let task_id = ctx
            .task_id
            .as_deref()
            .ok_or_else(|| anyhow!("replacement evidence belongs to a task; this run has none"))?;
        let detail: TaskDetail = client.get(&format!("/api/tasks/{task_id}")).await?;
        if !detail.attachments.iter().any(|item| item.id == *replaced) {
            bail!("attachment {replaced} is not evidence on this task");
        }
    }
    let attachment = upload_attachment(client, ctx, &args.path, &args.caption).await?;
    if let Some(replaced) = &args.replace {
        let _: Attachment = client
            .delete(&format!("/api/files/{replaced}/evidence"))
            .await?;
    }
    client.print(&attachment, || {
        println!(
            "attached {} ({} bytes)",
            attachment.file_name, attachment.size
        )
    });
    Ok(())
}

async fn evidence(client: &Client, ctx: &RunContext, command: EvidenceCommand) -> Result<()> {
    match command {
        EvidenceCommand::List => {
            let task_id = ctx
                .task_id
                .as_deref()
                .ok_or_else(|| anyhow!("evidence belongs to a task; this run has none"))?;
            let detail: TaskDetail = client.get(&format!("/api/tasks/{task_id}")).await?;
            client.print(&detail.attachments, || {
                for attachment in &detail.attachments {
                    println!(
                        "{}\t{}\t{}",
                        attachment.id, attachment.file_name, attachment.caption
                    );
                }
            });
        }
        EvidenceCommand::Remove { attachment_id } => {
            let attachment: Attachment = client
                .delete(&format!("/api/files/{attachment_id}/evidence"))
                .await?;
            client.print(&attachment, || {
                println!("removed {} from review evidence", attachment.file_name)
            });
        }
    }
    Ok(())
}

async fn preview(client: &Client, ctx: &RunContext, args: PreviewArgs) -> Result<()> {
    let task_id = ctx
        .task_id
        .clone()
        .ok_or_else(|| anyhow!("previews belong to a task; this run has none"))?;
    let mut preview: Preview = client
        .post(
            "/api/previews",
            json!({
                "task_id": task_id,
                "label": args.label,
                "command": args.command,
                "port": args.port,
            }),
        )
        .await?;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(65);
    while preview.status == PreviewStatus::Starting && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(350)).await;
        preview = client
            .get::<Vec<Preview>>("/api/previews")
            .await?
            .into_iter()
            .find(|candidate| candidate.id == preview.id)
            .ok_or_else(|| anyhow!("preview disappeared while starting"))?;
    }
    if preview.status != PreviewStatus::Live {
        bail!("preview did not become live (status: {:?})", preview.status);
    }
    client.print(&preview, || {
        println!("preview live on port {}", preview.port)
    });
    Ok(())
}

async fn link_pr(client: &Client, ctx: &RunContext, url: String) -> Result<()> {
    let task_id = ctx
        .task_id
        .clone()
        .ok_or_else(|| anyhow!("this run has no task to attach a pull request to"))?;
    let task: Task = client
        .patch(&format!("/api/tasks/{task_id}"), json!({ "pr_url": url }))
        .await?;
    client.print(&task, || {
        println!("linked {}", task.pr_url.as_deref().unwrap_or_default())
    });
    Ok(())
}

async fn task(client: &Client, ctx: &RunContext, command: TaskCommand) -> Result<()> {
    match command {
        TaskCommand::List { status, mine } => {
            let tasks: Vec<Task> = client.get("/api/tasks").await?;
            let filtered: Vec<Task> = tasks
                .into_iter()
                .filter(|t| {
                    status
                        .as_deref()
                        .and_then(TaskStatus::parse)
                        .map(|s| t.status == s)
                        .unwrap_or(true)
                })
                .filter(|t| !mine || t.owner_id == ctx.agent_id)
                .collect();
            client.print(&filtered, || {
                for task in &filtered {
                    println!("{} [{}] {}", task.key, task.status.as_str(), task.title);
                }
            });
        }
        TaskCommand::Show { reference } => {
            let detail: TaskDetail = client.get(&format!("/api/tasks/{reference}")).await?;
            client.print(&detail, || {
                println!(
                    "{} [{}] {}",
                    detail.task.key,
                    detail.task.status.as_str(),
                    detail.task.title
                );
                if !detail.task.outcome.trim().is_empty() {
                    println!("Expected result: {}", detail.task.outcome.trim());
                }
                if let Some(worktree) = &detail.worktree {
                    println!("Worktree: {} ({})", worktree.path, worktree.branch);
                }
                if let Some(pr) = &detail.task.pr_url {
                    println!("Pull request: {pr}");
                }
                if let Some(action) = &detail.task.review_action {
                    println!("Approval: {action}");
                }
                if let Some(continuation) = &detail.task.active_continuation {
                    println!(
                        "Active obligation [{}]: {}",
                        continuation.status.as_str(),
                        continuation.summary
                    );
                }
                for run in detail.runs.iter().take(5) {
                    println!("  run [{}] {}", run.status.as_str(), run.headline);
                }
            });
        }
        TaskCommand::Create {
            title,
            outcome,
            owner,
            status,
            project,
            due,
            once,
            allow_similar,
            start,
        } => {
            let owner_id = match owner {
                Some(handle) => Some(resolve_member(client, ctx, &handle).await?),
                None => None,
            };
            let created: Task = client
                .post(
                    "/api/tasks",
                    json!({
                        "title": title,
                        "outcome": outcome,
                        "owner_id": owner_id,
                        "status": status.as_deref().and_then(TaskStatus::parse),
                        "project_id": project,
                        "due_at": due.as_deref().map(parse_due).transpose()?,
                        "once_key": once,
                        "allow_similar": allow_similar,
                        "source_channel_id": ctx.channel_id,
                        "start": start,
                    }),
                )
                .await?;
            client.print(&created, || println!("{} created", created.key));
        }
        TaskCommand::Update {
            reference,
            title,
            outcome,
            status,
            owner,
            project,
            due,
            pr,
            evidence,
            approval,
        } => {
            let owner_id = match owner {
                Some(handle) => Some(resolve_member(client, ctx, &handle).await?),
                None => None,
            };
            if let Some(path) = evidence {
                let detail: TaskDetail = client.get(&format!("/api/tasks/{reference}")).await?;
                let mut evidence_ctx = ctx.clone();
                evidence_ctx.task_id = Some(detail.task.id);
                evidence_ctx.channel_id = Some(detail.task.discussion_channel_id);
                upload_attachment(client, &evidence_ctx, &path, "Review evidence").await?;
            }
            let updated: Task = client
                .patch(
                    &format!("/api/tasks/{reference}"),
                    json!({
                        "title": title,
                        "outcome": outcome,
                        "status": status.as_deref().and_then(TaskStatus::parse),
                        "owner_id": owner_id,
                        "project_id": project,
                        "due_at": due.as_deref().map(parse_due).transpose()?,
                        "pr_url": pr,
                        "review_action": approval,
                    }),
                )
                .await?;
            client.print(&updated, || {
                println!("{} is now {}", updated.key, updated.status.as_str())
            });
        }
        TaskCommand::Wait {
            summary,
            command,
            every,
            deadline,
            wake,
        } => {
            let task_id = ctx
                .task_id
                .as_deref()
                .ok_or_else(|| anyhow!("task wait only works inside a task run"))?;
            if deadline <= 0 {
                bail!("--deadline must be a positive number of seconds");
            }
            let deadline_at = now_ms()
                .checked_add(
                    deadline
                        .checked_mul(1000)
                        .ok_or_else(|| anyhow!("--deadline is too large"))?,
                )
                .ok_or_else(|| anyhow!("--deadline is too large"))?;
            let task: Task = client
                .post(
                    &format!("/api/tasks/{task_id}/continuation"),
                    json!({
                        "summary": summary,
                        "command": command,
                        "every_seconds": every,
                        "deadline_at": deadline_at,
                        "wake_prompt": wake,
                    }),
                )
                .await?;
            client.print(&task, || {
                println!("Patchwork will keep checking {}", task.key)
            });
        }
        TaskCommand::Delete { reference } => {
            let _: Value = client.delete(&format!("/api/tasks/{reference}")).await?;
            client.print(&json!({ "deleted": reference }), || {
                println!("task deleted")
            });
        }
    }
    Ok(())
}

async fn resolve_member(client: &Client, ctx: &RunContext, handle: &str) -> Result<String> {
    let handle = handle.trim_start_matches('@');
    if handle == "me" {
        if let Some(agent_id) = ctx.agent_id.clone() {
            return Ok(agent_id);
        }
    }
    let members: Vec<Member> = client.get("/api/members").await?;
    members
        .into_iter()
        .find(|m| m.handle == handle || m.id == handle)
        .map(|m| m.id)
        .ok_or_else(|| anyhow!("no member called @{handle}"))
}

async fn automation(client: &Client, ctx: &RunContext, command: AutomationCommand) -> Result<()> {
    match command {
        AutomationCommand::List => {
            let automations: Vec<Automation> = client.get("/api/automations").await?;
            client.print(&automations, || {
                for automation in &automations {
                    println!(
                        "{} [{}] {}",
                        automation.name,
                        if automation.enabled { "on" } else { "off" },
                        automation.description
                    );
                }
            });
        }
        AutomationCommand::Create {
            name,
            agent,
            trigger,
            action,
            instructions,
            every,
            command,
            channel,
            status,
            task,
        } => {
            let agent_id = resolve_member(client, ctx, &agent).await?;
            let channel_id = match channel {
                Some(reference) => Some(resolve_channel(client, ctx, Some(reference)).await?),
                None => ctx.channel_id.clone(),
            };
            let task_id = match task {
                Some(reference) => {
                    let detail: TaskDetail = client.get(&format!("/api/tasks/{reference}")).await?;
                    Some(detail.task.id)
                }
                None => None,
            };
            let trigger = build_trigger(
                &trigger,
                every,
                command,
                channel_id.clone(),
                status,
                task_id,
            )?;
            let action = match action.as_str() {
                "create-task" => "create_task",
                "continue-task" => "continue_task",
                _ => "post_in_chat",
            };
            let is_watch = trigger.get("type").and_then(Value::as_str) == Some("watch");
            let created: Automation = client
                .post(
                    "/api/automations",
                    json!({
                        "name": name,
                        "trigger": trigger,
                        "agent_id": agent_id,
                        "action": action,
                        "instructions": instructions,
                        // Context stays a reference to the conversation this
                        // was created from, not a copied-in prompt.
                        "context_channel_id": ctx.channel_id,
                        "report_channel_id": channel_id,
                        "enabled": !is_watch,
                    }),
                )
                .await?;
            let created = if is_watch {
                let result = test_watch_command(client, &created).await?;
                if !result.ok {
                    bail!(
                        "watch validation failed; `{}` remains paused: {}",
                        created.name,
                        result.error.unwrap_or_else(|| "unknown error".into())
                    );
                }
                set_enabled(client, &created.id, true).await?
            } else {
                created
            };
            client.print(&created, || {
                println!("created automation {}", created.name);
                // The URL is the whole automation for a webhook trigger, and
                // it is not knowable without being told.
                if let AutomationTrigger::Webhook { token } = &created.trigger {
                    println!("POST {}/api/webhooks/{token}", client.base);
                    println!("  add ?once=<your-key> so a repeated delivery does not act twice");
                }
            });
        }
        AutomationCommand::Run { id } => {
            let automation = resolve_automation(client, &id).await?;
            let run: AutomationRun = client
                .post(
                    &format!("/api/automations/{}/run", automation.id),
                    json!({}),
                )
                .await?;
            client.print(&run, || println!("automation fired"));
        }
        AutomationCommand::Test { reference } => {
            let automation = resolve_automation(client, &reference).await?;
            let result = test_watch_command(client, &automation).await?;
            if !result.ok {
                bail!(
                    "watch validation failed: {}",
                    result.error.unwrap_or_else(|| "unknown error".into())
                );
            }
            client.print(&result, || {
                println!(
                    "watch validated; {} event{} would fire",
                    result.event_count,
                    if result.event_count == 1 { "" } else { "s" }
                )
            });
        }
        AutomationCommand::Show { reference } => {
            let automation = resolve_automation(client, &reference).await?;
            let debug: AutomationDebug = client
                .get(&format!("/api/automations/{}/debug", automation.id))
                .await?;
            client.print(&debug, || {
                println!(
                    "{} [{}] {}",
                    debug.automation.name,
                    if debug.automation.enabled {
                        "on"
                    } else {
                        "off"
                    },
                    debug.automation.description
                );
                if !debug.automation.instructions.trim().is_empty() {
                    println!("Instructions: {}", debug.automation.instructions.trim());
                }
                if let Some(at) = debug.automation.last_success_at {
                    println!("Last success: {}", display_millis(at));
                }
                if let Some(error) = &debug.automation.last_error {
                    let at = debug
                        .automation
                        .last_error_at
                        .map(display_millis)
                        .unwrap_or_else(|| "unknown time".into());
                    println!("Last error: {at} · {error}");
                }
                for run in debug.runs.iter().take(10) {
                    println!(
                        "  {} [{}] {}",
                        run.trigger_summary,
                        run.status.as_str(),
                        run.error.clone().unwrap_or_default()
                    );
                }
            });
        }
        AutomationCommand::Pause { reference } => {
            let updated = set_enabled(client, &reference, false).await?;
            client.print(&updated, || println!("{} paused", updated.name));
        }
        AutomationCommand::Resume { reference } => {
            let updated = set_enabled(client, &reference, true).await?;
            client.print(&updated, || println!("{} resumed", updated.name));
        }
        AutomationCommand::Delete { reference } => {
            let automation = resolve_automation(client, &reference).await?;
            let _: Value = client
                .delete(&format!("/api/automations/{}", automation.id))
                .await?;
            client.print(&json!({ "deleted": automation.id }), || {
                println!("{} deleted", automation.name)
            });
        }
    }
    Ok(())
}

async fn test_watch_command(client: &Client, automation: &Automation) -> Result<WatchTestResult> {
    client
        .post(
            &format!("/api/automations/{}/test", automation.id),
            json!({}),
        )
        .await
}

fn display_millis(at: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at)
        .map(|time| time.to_rfc3339())
        .unwrap_or_else(|| at.to_string())
}

/// An automation by id or by name, because a person tells an agent to pause
/// "the morning sweep", not to pause `019fd8…`.
async fn resolve_automation(client: &Client, reference: &str) -> Result<Automation> {
    let automations: Vec<Automation> = client.get("/api/automations").await?;
    automations
        .iter()
        .find(|a| a.id == reference)
        .or_else(|| {
            automations
                .iter()
                .find(|a| a.name.eq_ignore_ascii_case(reference.trim()))
        })
        .cloned()
        .ok_or_else(|| anyhow!("no automation called {reference}"))
}

/// The relay takes a whole automation on update, so pausing one means sending
/// back what it already was with `enabled` flipped.
async fn set_enabled(client: &Client, reference: &str, enabled: bool) -> Result<Automation> {
    let automation = resolve_automation(client, reference).await?;
    let mut body = serde_json::to_value(&automation)?;
    body["enabled"] = json!(enabled);
    let updated: Automation = client
        .patch(&format!("/api/automations/{}", automation.id), body)
        .await?;
    Ok(updated)
}

fn build_trigger(
    kind: &str,
    every: Option<i64>,
    command: Option<String>,
    channel_id: Option<String>,
    status: Option<String>,
    task_id: Option<String>,
) -> Result<Value> {
    Ok(match kind {
        "schedule" => json!({
            "type": "schedule",
            "every_seconds": every.ok_or_else(|| anyhow!("--every is required for a schedule"))?
        }),
        "watch" => json!({
            "type": "watch",
            "command": command.filter(|c| !c.trim().is_empty())
                .ok_or_else(|| anyhow!("--command is required for a watch"))?,
            "every_seconds": every.unwrap_or(300)
        }),
        "message" => json!({
            "type": "message",
            "channel_id": channel_id.ok_or_else(|| anyhow!("--channel is required for a message trigger"))?,
            "pattern": ""
        }),
        "task-status" => json!({
            "type": "task_status",
            "status": status.unwrap_or_else(|| "review".into()),
            "task_id": task_id
        }),
        "task-assigned" => json!({ "type": "task_assigned" }),
        "pull-request" => json!({
            "type": "pull_request",
            "on_review_comment": true,
            "on_checks_failed": true
        }),
        "webhook" => json!({ "type": "webhook", "token": patchwork_core::new_id() }),
        "manual" => json!({ "type": "manual" }),
        other => bail!("unknown trigger `{other}`"),
    })
}

fn urlencode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            b' ' => "+".to_string(),
            other => format!("%{other:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_are_encoded_for_urls() {
        assert_eq!(urlencode("checkout totals"), "checkout+totals");
        assert_eq!(urlencode("a&b=c"), "a%26b%3Dc");
    }

    #[test]
    fn a_channel_can_create_its_section() {
        let cli = Cli::try_parse_from([
            "patchwork",
            "channel",
            "create",
            "dev",
            "--section",
            "Product",
        ])
        .unwrap();
        let Command::Channel(ChannelCommand::Create { name, section, .. }) = cli.command else {
            panic!("channel create was not parsed");
        };
        assert_eq!(name, "dev");
        assert_eq!(section.as_deref(), Some("Product"));
    }

    #[test]
    fn admin_commands_are_discoverable() {
        let cli =
            Cli::try_parse_from(["patchwork", "workspace", "update", "--icon", "🚀"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Workspace(WorkspaceCommand::Update { icon: Some(_), .. })
        ));
        let cli = Cli::try_parse_from([
            "patchwork",
            "workspace",
            "update",
            "--icon-file",
            "logo.png",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::Workspace(WorkspaceCommand::Update {
                icon_file: Some(_),
                ..
            })
        ));

        let cli = Cli::try_parse_from([
            "patchwork",
            "agent",
            "update",
            "@manager",
            "--admin",
            "true",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Command::Agent(AgentCommand::Update {
                admin: Some(true),
                ..
            })
        ));
    }

    #[test]
    fn schedule_triggers_need_an_interval() {
        assert!(build_trigger("schedule", None, None, None, None, None).is_err());
        assert_eq!(
            build_trigger("schedule", Some(3600), None, None, None, None).unwrap()["every_seconds"],
            3600
        );
    }

    #[test]
    fn watch_test_command_is_discoverable() {
        let cli =
            Cli::try_parse_from(["patchwork", "automation", "test", "Release watch"]).unwrap();
        assert!(matches!(
            cli.command,
            Command::Automation(AutomationCommand::Test { reference }) if reference == "Release watch"
        ));
    }

    #[test]
    fn watch_triggers_need_a_command_and_default_their_interval() {
        assert!(build_trigger("watch", Some(60), None, None, None, None).is_err());
        assert!(build_trigger("watch", Some(60), Some("  ".into()), None, None, None).is_err());
        let watch = build_trigger("watch", None, Some("scan.sh".into()), None, None, None).unwrap();
        assert_eq!(watch["command"], "scan.sh");
        assert_eq!(watch["every_seconds"], 300);
    }

    #[test]
    fn task_status_triggers_can_name_one_task() {
        let any =
            build_trigger("task-status", None, None, None, Some("done".into()), None).unwrap();
        assert_eq!(any["status"], "done");
        assert!(any["task_id"].is_null());
        let one = build_trigger(
            "task-status",
            None,
            None,
            None,
            Some("done".into()),
            Some("task-1".into()),
        )
        .unwrap();
        assert_eq!(one["task_id"], "task-1");
    }
}
