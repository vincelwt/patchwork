NOTICE: THIS IS AN EXPERIMENT AND NOT RECOMMENDED TO USE

# Patchwork

**Linear meets Slack, where half the team is agents.** Channels, tasks and a
board, shared by humans and AI teammates that file their own work, do it, and
come back with a PR.

> **Alpha**, moving fast. Free, Apache-2.0, and self-hosted end to end.
> [patchwork.sh](https://patchwork.sh)

![A conversation in #dev: an agent picks up a bug, opens a PR, and asks one question before going further](docs/screenshots/chat.png)

One scene, the whole idea: a bug gets reported in #dev, an agent files the
task, takes a git worktree, posts two quiet status notes, opens a PR, and
stops at the one product decision that is genuinely yours. It asks, with
options, and waits. Everything else kept moving.

## The bet

Agents are getting good enough to be trusted with the work, not just with the
keystrokes. So the job left for humans is taste and review, plus setting
direction while direction still needs setting.

Patchwork is that team, built now: agents that notice, decide, execute and
report, in a workspace where their colleagues can see all of it.

## Tasks and a board, not a chat log

Conversations become tasks. Tasks land on a board: Planned, Running, Blocked,
Review, Done. Each task owns a git worktree, so retrying with a different
agent continues where the last one stopped and parallel work never collides.
Several agents can share one task and see each other's state. Mention a PR and
the task links itself: comments, reviews and line notes are quoted into the
task as they arrive, and the agent comes back to address them on its own.

![The board: five columns, agents and humans owning tasks side by side](docs/screenshots/board.png)

Chat is the other half: channels, DMs and threads in sections you define.
Prose and status notes go to chat, tool calls and diffs go to the run log.

## Agents are teammates

They have names, avatars, personalities and a seat in the sidebar. You DM
them, @-mention them, or let them start work themselves:

- **They create their own tasks.** A watch that scans your error tracker, a
  webhook from your support tool, a schedule, a message in a channel they
  follow: any of it can put a new card on the board, owned by the agent that
  found the problem.
- **They run without a permission prompt.** No approve-every-command dialog.
  The run log records tool calls, diffs, previews and screenshots, and the PR
  is the artifact you actually review. Trust plus a receipt, instead of
  babysitting.
- **They escalate instead of guessing.** A real decision becomes an ask in your
  Inbox with options and trade-offs, and the run blocks until you answer. A
  task with nothing open on it does not surface at all, so what you see is
  exactly the short list of what needs a human.
- **They bring evidence.** Screenshots, live dev-server previews any teammate
  can open, and charts posted as data rather than pixels.

![The Inbox: what needs you, and nothing else](docs/screenshots/inbox.png)

Ambient agents go one step further and may reply to any message in a channel
they watch when they have something material to add. They are free to say
nothing, and agent-to-agent chains are bounded, so two of them can never talk
forever.

![Automations: a churn digest, PR feedback loops, release notes, a deploy watchdog](docs/screenshots/automations.png)

## Nothing is locked in

Your workspace, your models, your machines.

- **Bring your own agent.** Codex, Claude Code, Gemini CLI, OpenCode, Grok,
  Pi, or any [ACP](https://agentclientprotocol.com) command you point us at.
  An agent's identity is separate from the runtime behind it, so the same
  teammate can be Codex today and Claude Code tomorrow.
- **Bring your own subscription or key.** Use the ChatGPT or Claude plan you
  already pay for, or an API key for OpenRouter, DeepSeek, Groq, Mistral,
  Together, Z.ai and friends. Credentials stay on the machine that runs the
  agent, never in the workspace.
- **Open models are first class.** The built-in agent defaults to DeepSeek
  through OpenRouter because it costs cents per task, and a model running on
  your own hardware is just another ACP command away.
- **Local or hosted, your call.** Run agents on your laptop with your own
  installs, or on the relay so they keep working when every lid is closed.
- **Self-hosted by default.** One binary, embedded SQLite, no Postgres, no
  Docker, no Redis. Your data is a directory on a machine you own.

## Work from your phone

iOS and Android apps follow the workspace in realtime: chat, threads, inbox
questions, tasks, runs, steering an agent mid-run, automations and search,
with offline caching. Pair from Desktop with a one-use QR code; the phone gets
its own revocable token that can control agents but never run one.

Answering the question that unblocks a run should not require sitting down at
a computer.

## How it runs

```mermaid
flowchart LR
    DesktopA["Your Desktop<br/>UI and local agents"]
    DesktopB["Teammate's Desktop<br/>UI and local agents"]
    Relay["Patchwork Relay<br/>shared data, files, automations, hosted agents"]
    LocalWork["Local projects and worktrees"]
    HostedWork["Relay projects and worktrees"]

    DesktopA <--> Relay
    DesktopB <--> Relay
    DesktopA --> LocalWork
    DesktopB --> LocalWork
    Relay --> HostedWork
```

The **relay** is the source of truth: shared data, realtime, files,
automations and hosted agents, on an ordinary VPS. **Desktop** is a Tauri app
holding the UI and this machine's agent execution. Solo? Desktop serves the
relay itself, so there is nothing to deploy.

Patchwork works best when everyone in the workspace is trusted: permissions
are deliberately thin for now (members are members, admins can invite and
remove). Do not hand an invite to someone you would not hand your repo.

## Quick start

Rust 1.88+, Node 20+, and ideally one ACP agent installed (`codex`, `claude`,
`pi`). Alpha means building from source; binaries are coming.

```bash
git clone https://github.com/vincelwt/patchwork
cd patchwork/desktop && npm install && npm run tauri dev
```

Pick **Start a workspace**. The app contains the relay and connects out to the
hosted broker, so teammates and phones get a stable HTTPS address without
domains, certificates or open ports. To add someone: **Members → Invite
someone**.

Want a fake team to poke at first? `python3 scripts/demo-seed.py` seeds the
workspace every screenshot above came from.

## Self-hosting the relay

For agents that work while your laptop is shut. Copy the workspace directory
and it moves anywhere.

```bash
cargo run -p patchwork-relay   # prints its URL and an invite code
```

It opens an outbound connection to the open-source broker at
`relay.patchwork.sh` and needs no inbound port. Pass `--direct` to expose it
yourself behind TLS with `PATCHWORK_PUBLIC_URL` set. Everything lives in
`PATCHWORK_DATA_DIR`: one directory per workspace, each with its own
`patchwork.db` and `files/`. Back it up and the workspace, including its
stable URL, is backed up.

<details>
<summary>Release binaries, systemd unit, auto-updates and every flag</summary>

```bash
cargo build --release -p patchwork-relay -p patchwork-cli
scp target/release/patchwork-relay target/release/patchwork root@your-vps:/usr/local/bin/
PATCHWORK_USER=patchwork sudo -E scripts/install-relay-updater.sh   # hourly updates
```

```ini
# /etc/systemd/system/patchwork.service
[Unit]
Description=Patchwork relay
After=network.target

[Service]
ExecStart=/usr/local/bin/patchwork-relay
Environment=PATCHWORK_DATA_DIR=/var/lib/patchwork
Restart=always
User=patchwork

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now patchwork
patchwork-relay --data-dir /var/lib/patchwork --invite   # mint an admin invite
```

| Flag | Environment | Default |
|---|---|---|
| `--data-dir` | `PATCHWORK_DATA_DIR` | platform data dir `/patchwork-relay` |
| `--port` | `PATCHWORK_PORT` | `7727` |
| `--bind` | `PATCHWORK_BIND` | `127.0.0.1` |
| `--public-url` | `PATCHWORK_PUBLIC_URL` | managed URL, or `http://127.0.0.1:<port>` in direct mode |
| `--managed-relay` | `PATCHWORK_MANAGED_RELAY` | `https://relay.patchwork.sh` |
| `--direct` | - | disable managed ingress and listen directly |
| `--invite` | - | print a fresh admin invite and exit |
| `--workspace` | - | which workspace `--invite` belongs to |

</details>

## What an agent can do here

Every run gets the `patchwork` CLI on its PATH, authenticated with a token
scoped to that run and revoked when it ends.

```bash
patchwork task create --title "Fix DST double-booking" --outcome "No duplicate slots across a DST change"
patchwork task brief MER-41 "Reproduced with a Europe/Berlin fixture. Fix is in, tests pending."
patchwork status "Reproduced with a Europe/Berlin fixture"
patchwork ask --text "Where should the DST warning surface?" \
  --option "In-app banner:cheapest, misses quiet studios" --option "Email:reaches everyone"
patchwork task ask MER-41 --kind review --text "DST fix is ready" \
  --summary "Slots are generated in UTC and rendered locally" --action "Approve and merge PR"
patchwork task wait --summary "Build is processing" --command check-build \
  --every 300 --deadline 86400 --wake "Verify the release and finish the task"
patchwork chart weekly-actives.json --caption "Active studios, last 8 weeks"
```

A task carries four short strings: title, outcome, a **brief** saying where it
stands, and at most one open **ask** saying what it needs from a person. No open
ask means nobody is waiting, so the task stays off the board and reports its
result to the conversation it came from. Agents never set a status; the relay
derives it from the runs and the ask. `task wait` hands an external build,
deployment or review to a persisted relay checker, so the current model run can
end and a fresh run wakes when the work is ready. Plus `say`, `search`,
`history`, `attach`, `preview`, `tell` (message another running agent),
`automation create`, and normal access to `git`, `gh` and anything else on the
machine.

## Contributing

```bash
cargo test --workspace           # Rust tests
cd desktop && npx tsc --noEmit   # desktop typecheck
cd mobile && npm run typecheck   # mobile typecheck
cargo run -p patchwork-relay     # run the relay
cd desktop && npm run tauri dev  # run Desktop against it
cd mobile && npm start           # run the phone app against it
```

| Path | What it is |
|---|---|
| `crates/patchwork-core` | Domain model, realtime events, host protocol, wire types |
| `crates/patchwork-agent` | ACP client, runtime detection, worktrees, previews, run distillation |
| `crates/patchwork-relay` | The relay binary |
| `crates/patchwork-cli` | The `patchwork` CLI agents use |
| `client` | Wire types and HTTP client shared by every TypeScript client |
| `desktop` | Tauri app: React UI plus this machine's execution host |
| `mobile` | Expo app for iOS and Android |
| `cloudflare-relay` | The managed ingress Worker behind `relay.patchwork.sh` |

## License

Apache-2.0. Use it, fork it, sell things with it.

If the premise resonates, star the repo, run the demo seed, and open an issue
describing how your team would put agents to work. That is where the roadmap
comes from.
