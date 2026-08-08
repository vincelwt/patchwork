//! `patchwork` — an agent's native access to the workspace it lives in.
//!
//! It is pre-authenticated inside a run: the runner passes `PATCHWORK_API_BASE`
//! and a run-scoped `PATCHWORK_TOKEN`, so an agent never handles credentials.

use anyhow::{anyhow, bail, Context, Result};
use clap::{Args, Parser, Subcommand};
use patchwork_core::host::RunControlMode;
use patchwork_core::models::*;
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
    /// Post a chart from a Flint chart spec.
    Chart(ChartArgs),
    /// Expose a dev server you started as a task preview.
    Preview(PreviewArgs),
    /// Link a pull request to the current task.
    Pr { url: String },
    /// Read and create channels.
    #[command(subcommand)]
    Channel(ChannelCommand),
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
}

#[derive(Args)]
struct AttachArgs {
    path: String,
    #[arg(long, default_value = "")]
    caption: String,
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
    /// Command that starts the dev server.
    #[arg(long)]
    command: String,
    #[arg(long)]
    label: Option<String>,
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
        /// `@handle` of the owner. A person, when the task is for a person.
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
        /// Start the owning agent right away.
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
        /// Shell command for `--trigger watch`. It runs on the relay every
        /// `--every` seconds and only fires the agent when it prints
        /// something new. `$PATCHWORK_STATE_DIR` is its own directory, kept
        /// between polls, for whatever it needs to remember.
        #[arg(long)]
        command: Option<String>,
        /// Channel for message triggers and for reporting.
        #[arg(long)]
        channel: Option<String>,
        /// Task status for `--trigger task-status`.
        #[arg(long)]
        status: Option<String>,
    },
    /// Everything about one automation, including its last firings.
    Show {
        /// Id or name.
        reference: String,
    },
    Run {
        id: String,
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
        Command::Chart(args) => chart(&client, &ctx, args).await,
        Command::Preview(args) => preview(&client, &ctx, args).await,
        Command::Pr { url } => link_pr(&client, &ctx, url).await,
        Command::Channel(command) => channel(&client, command).await,
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

    let payload = json!({
        "me": bootstrap.me,
        "workspace": bootstrap.workspace.name,
        "run_id": ctx.run_id,
        "channel_id": ctx.channel_id,
        "task": task.as_ref().map(|t| &t.task),
        "worktree": task.as_ref().and_then(|t| t.worktree.clone()),
        "cwd": std::env::var("PATCHWORK_CWD").ok(),
    });

    client.print(&payload, || {
        println!(
            "You are {} (@{})",
            bootstrap.me.display_name, bootstrap.me.handle
        );
        println!("Workspace: {}", bootstrap.workspace.name);
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
    let run_id = if let Some(run) = bootstrap
        .active_runs
        .iter()
        .find(|run| run.id == args.target)
    {
        run.id.clone()
    } else if let Some(task) = bootstrap
        .tasks
        .iter()
        .find(|task| task.key.eq_ignore_ascii_case(&args.target))
    {
        task.current_run_id
            .clone()
            .filter(|id| bootstrap.active_runs.iter().any(|run| run.id == *id))
            .ok_or_else(|| anyhow!("{} has no active run", task.key))?
    } else {
        bail!(
            "no active run or task called `{}`; use `patchwork runs`",
            args.target
        );
    };
    let response: SteerRunResponse = client
        .post(
            &format!("/api/runs/{run_id}/steer"),
            serde_json::to_value(SteerRun {
                prompt,
                mode: RunControlMode::Queue,
                attachment_ids: Vec::new(),
            })?,
        )
        .await?;
    client.print(&response, || println!("sent"));
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
            json!({ "run_id": run_id, "headline": args.header, "items": [item] }),
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

async fn attach(client: &Client, ctx: &RunContext, args: AttachArgs) -> Result<()> {
    let bytes = tokio::fs::read(&args.path)
        .await
        .with_context(|| format!("cannot read {}", args.path))?;
    let file_name = std::path::Path::new(&args.path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".into());

    let mut form = reqwest::multipart::Form::new().part(
        "file",
        reqwest::multipart::Part::bytes(bytes).file_name(file_name.clone()),
    );
    if let Some(task_id) = &ctx.task_id {
        form = form.text("task_id", task_id.clone());
    }

    let response = client
        .http
        .post(client.url("/api/files"))
        .bearer_auth(&client.token)
        .multipart(form)
        .send()
        .await?;
    let attachment: Attachment = parse(response).await?;

    if let Some(channel_id) = &ctx.channel_id {
        let _: Message = client
            .post(
                &format!("/api/channels/{channel_id}/messages"),
                json!({
                    "body": args.caption,
                    "kind": "card",
                    "card": { "type": "artifact", "attachment_id": attachment.id, "caption": args.caption },
                    "run_id": ctx.run_id,
                }),
            )
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

async fn preview(client: &Client, ctx: &RunContext, args: PreviewArgs) -> Result<()> {
    let task_id = ctx
        .task_id
        .clone()
        .ok_or_else(|| anyhow!("previews belong to a task; this run has none"))?;
    let preview: Preview = client
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
    client.print(&preview, || {
        println!("preview starting on port {}", preview.port)
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
            start,
        } => {
            let owner_id = match owner {
                Some(handle) => Some(resolve_member(client, &handle).await?),
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
        } => {
            let owner_id = match owner {
                Some(handle) => Some(resolve_member(client, &handle).await?),
                None => None,
            };
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
                    }),
                )
                .await?;
            client.print(&updated, || {
                println!("{} is now {}", updated.key, updated.status.as_str())
            });
        }
    }
    Ok(())
}

async fn resolve_member(client: &Client, handle: &str) -> Result<String> {
    let handle = handle.trim_start_matches('@');
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
        } => {
            let agent_id = resolve_member(client, &agent).await?;
            let channel_id = match channel {
                Some(reference) => Some(resolve_channel(client, ctx, Some(reference)).await?),
                None => ctx.channel_id.clone(),
            };
            let trigger = build_trigger(&trigger, every, command, channel_id.clone(), status)?;
            let action = match action.as_str() {
                "create-task" => "create_task",
                "continue-task" => "continue_task",
                _ => "post_in_chat",
            };
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
                        "enabled": true,
                    }),
                )
                .await?;
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
            "status": status.unwrap_or_else(|| "review".into())
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
    fn schedule_triggers_need_an_interval() {
        assert!(build_trigger("schedule", None, None, None, None).is_err());
        assert_eq!(
            build_trigger("schedule", Some(3600), None, None, None).unwrap()["every_seconds"],
            3600
        );
    }

    #[test]
    fn watch_triggers_need_a_command_and_default_their_interval() {
        assert!(build_trigger("watch", Some(60), None, None, None).is_err());
        assert!(build_trigger("watch", Some(60), Some("  ".into()), None, None).is_err());
        let watch = build_trigger("watch", None, Some("scan.sh".into()), None, None).unwrap();
        assert_eq!(watch["command"], "scan.sh");
        assert_eq!(watch["every_seconds"], 300);
    }
}
