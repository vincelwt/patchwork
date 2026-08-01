import { useEffect, useState } from "react";
import { useApi, useApp } from "../lib/store";
import { relative, statusLabel, statusTone } from "../lib/format";
import {
  desktopInfo,
  openExternal,
  pickDirectory,
  setProjectPaths,
  signOut,
} from "../lib/desktop";
import type { DesktopInfo } from "../lib/desktop";
import { Avatar, Chip, Field, Modal, Select, useNavigation } from "./common";
import type {
  AgentProfile,
  Automation,
  AutomationDebug,
  Member,
  Participation,
  Project,
} from "../lib/types";

// --- agents ----------------------------------------------------------------

export function AgentsPage() {
  const app = useApp();
  const [editing, setEditing] = useState<Member | null>(null);
  const [creating, setCreating] = useState(false);
  const agents = app.members.filter((member) => member.kind === "agent");

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Agents</span>
        <span className="spacer" />
        <button className="button primary" onClick={() => setCreating(true)}>
          New agent
        </button>
      </div>
      <div className="page">
        <div className="page-inner">
          {agents.length === 0 && (
            <div className="empty">
              No agents yet. An agent is a teammate with a name, a personality and
              a runtime.
            </div>
          )}
          {agents.map((agent) => (
            <button
              key={agent.id}
              className="row"
              style={{ width: "100%" }}
              onClick={() => setEditing(agent)}
            >
              <Avatar member={agent} size={26} />
              <span className="grow">
                <span className="name">{agent.display_name}</span>
                <span className="sub">
                  @{agent.handle} · {agent.agent?.description || "no description yet"}
                </span>
              </span>
              <Chip>{agent.agent?.runtime}</Chip>
              <Chip>{agent.agent?.location}</Chip>
            </button>
          ))}
        </div>
      </div>
      {(creating || editing) && (
        <AgentModal
          agent={editing}
          onClose={() => {
            setCreating(false);
            setEditing(null);
          }}
        />
      )}
    </div>
  );
}

function AgentModal({
  agent,
  onClose,
}: {
  agent: Member | null;
  onClose: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const [name, setName] = useState(agent?.display_name ?? "");
  const [profile, setProfile] = useState<AgentProfile>(
    agent?.agent ?? {
      description: "",
      runtime: "codex",
      location: "auto",
      dm_enabled: true,
      default_participation: "mention",
      channel_participation: {},
    },
  );
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const runtimes = Array.from(
    new Set(
      app.hosts.flatMap((host) =>
        host.capabilities.runtimes.map((runtime) => runtime.id),
      ),
    ),
  );

  const save = async () => {
    setBusy(true);
    setError("");
    try {
      if (agent) {
        await api.updateAgent(agent.id, { display_name: name, profile });
      } else {
        await api.createAgent({ display_name: name, profile });
      }
      onClose();
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  return (
    <Modal
      title={agent ? agent.display_name : "New agent"}
      subtitle="An identity is separate from the runtime that powers it."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={!name.trim() || busy}
            onClick={save}
          >
            Save
          </button>
        </>
      }
    >
      <Field label="Name" value={name} onChange={setName} autoFocus />
      <Field
        label="Description and working style"
        value={profile.description}
        onChange={(description) => setProfile({ ...profile, description })}
        textarea
        placeholder="Who is this teammate, what do they own, and what will they decline?"
      />
      <Select
        label="Runtime"
        value={profile.runtime}
        onChange={(runtime) => setProfile({ ...profile, runtime })}
        options={(runtimes.length ? runtimes : ["codex", "claude", "pi", "custom"]).map(
          (runtime) => ({ value: runtime, label: runtime }),
        )}
      />
      {profile.runtime === "custom" && (
        <Field
          label="ACP command"
          value={(profile.custom_command ?? []).join(" ")}
          onChange={(value) =>
            setProfile({ ...profile, custom_command: value.split(/\s+/).filter(Boolean) })
          }
          placeholder="my-agent --acp"
        />
      )}
      <Select
        label="Runs on"
        value={profile.location}
        onChange={(location) =>
          setProfile({ ...profile, location: location as AgentProfile["location"] })
        }
        options={[
          { value: "auto", label: "Wherever the project is available" },
          { value: "relay", label: "The relay (keeps working when laptops close)" },
          { value: "desktop", label: "A specific desktop" },
        ]}
      />
      {profile.location === "desktop" && (
        <Select
          label="Machine"
          value={profile.host_id ?? ""}
          onChange={(host_id) => setProfile({ ...profile, host_id })}
          options={[
            { value: "", label: "Pick a machine" },
            ...app.hosts
              .filter((host) => host.kind === "desktop")
              .map((host) => ({ value: host.id, label: host.name })),
          ]}
        />
      )}
      <Select
        label="Default participation"
        value={profile.default_participation}
        onChange={(value) =>
          setProfile({
            ...profile,
            default_participation: value as Participation,
          })
        }
        options={[
          { value: "mention", label: "Only when mentioned" },
          { value: "ambient", label: "Ambient — may chime in when useful" },
          { value: "off", label: "Never speaks on its own" },
        ]}
      />

      <div className="section-title">Per-channel participation</div>
      {app.channels
        .filter((channel) => channel.kind === "channel")
        .map((channel) => (
          <div className="row" key={channel.id}>
            <span className="grow">#{channel.name}</span>
            <select
              className="field"
              style={{ width: 150 }}
              value={
                profile.channel_participation[channel.id] ??
                profile.default_participation
              }
              onChange={(event) =>
                setProfile({
                  ...profile,
                  channel_participation: {
                    ...profile.channel_participation,
                    [channel.id]: event.target.value as Participation,
                  },
                })
              }
            >
              <option value="off">Off</option>
              <option value="mention">Mention</option>
              <option value="ambient">Ambient</option>
            </select>
          </div>
        ))}

      <label className="form-row" style={{ flexDirection: "row", gap: 8 }}>
        <input
          type="checkbox"
          checked={profile.dm_enabled}
          onChange={(event) =>
            setProfile({ ...profile, dm_enabled: event.target.checked })
          }
        />
        <span>Available in direct messages</span>
      </label>
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- projects and hosts ----------------------------------------------------

export function ProjectsPage() {
  const app = useApp();
  const api = useApi();
  const [editing, setEditing] = useState<Project | null>(null);
  const [creating, setCreating] = useState(false);
  const [info, setInfo] = useState<DesktopInfo>();

  useEffect(() => {
    void desktopInfo().then(setInfo);
  }, [app.hosts]);

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Projects and machines</span>
        <span className="spacer" />
        <button className="button primary" onClick={() => setCreating(true)}>
          New project
        </button>
      </div>
      <div className="page">
        <div className="page-inner">
          <div className="section-title">Projects</div>
          {app.projects.length === 0 && (
            <div className="empty">
              A project connects business context to a git repository or an
              ordinary folder.
            </div>
          )}
          {app.projects.map((project) => (
            <button
              key={project.id}
              className="row"
              style={{ width: "100%" }}
              onClick={() => setEditing(project)}
            >
              <span className="grow">
                <span className="name">{project.name}</span>
                <span className="sub">
                  {Object.keys(project.paths).length} machine
                  {Object.keys(project.paths).length === 1 ? "" : "s"} ·{" "}
                  {project.description || project.repo_url || project.kind}
                </span>
              </span>
              {project.dev_command && <Chip>preview ready</Chip>}
            </button>
          ))}

          <div className="section-title">Execution machines</div>
          {app.hosts.map((host) => (
            <div className="row" key={host.id}>
              <span className={`dot ${host.online ? "online" : ""}`} />
              <span className="grow">
                <span className="name">{host.name}</span>
                <span className="sub">
                  {host.platform} ·{" "}
                  {host.capabilities.runtimes
                    .filter((runtime) => runtime.available && runtime.id !== "custom")
                    .map((runtime) => runtime.label)
                    .join(", ") || "no agent installations detected"}
                </span>
              </span>
              {host.capabilities.has_gh && (
                <Chip tone={host.capabilities.gh_authenticated ? "positive" : "caution"}>
                  gh
                </Chip>
              )}
              {!host.online && <Chip>offline</Chip>}
            </div>
          ))}

          {info && info.capabilities.notes.length > 0 && (
            <>
              <div className="section-title">This machine</div>
              {info.capabilities.notes.map((note) => (
                <div className="row" key={note}>
                  <span className="sub">{note}</span>
                </div>
              ))}
            </>
          )}
        </div>
      </div>
      {(creating || editing) && (
        <ProjectModal
          project={editing}
          onClose={() => {
            setCreating(false);
            setEditing(null);
          }}
          onDelete={
            editing
              ? async () => {
                  await api.deleteProject(editing.id);
                  setEditing(null);
                }
              : undefined
          }
        />
      )}
    </div>
  );
}

function ProjectModal({
  project,
  onClose,
  onDelete,
}: {
  project: Project | null;
  onClose: () => void;
  onDelete?: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const [name, setName] = useState(project?.name ?? "");
  const [description, setDescription] = useState(project?.description ?? "");
  const [repoUrl, setRepoUrl] = useState(project?.repo_url ?? "");
  const [branch, setBranch] = useState(project?.default_branch ?? "main");
  const [devCommand, setDevCommand] = useState(project?.dev_command ?? "");
  const [devPort, setDevPort] = useState(String(project?.dev_port ?? ""));
  const [paths, setPaths] = useState<Record<string, string>>(project?.paths ?? {});
  const [localPath, setLocalPath] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    void desktopInfo().then((info) => {
      if (project) setLocalPath(info.settings.project_paths[project.id] ?? "");
    });
  }, [project]);

  const save = async () => {
    setError("");
    try {
      const body = {
        name,
        description,
        repo_url: repoUrl || undefined,
        default_branch: branch,
        paths,
        dev_command: devCommand || undefined,
        dev_port: devPort ? Number(devPort) : undefined,
      };
      const saved = project
        ? await api.updateProject(project.id, body)
        : await api.createProject(body);

      // Remember where this project lives on this machine so tasks can run here.
      if (localPath) {
        const info = await desktopInfo();
        await setProjectPaths({
          ...info.settings.project_paths,
          [saved.id]: localPath,
        });
      }
      onClose();
    } catch (err) {
      setError(String((err as Error).message ?? err));
    }
  };

  return (
    <Modal
      title={project ? project.name : "New project"}
      subtitle="Where the code lives, on each machine that has it."
      onClose={onClose}
      actions={
        <>
          {onDelete && (
            <button className="button quiet" onClick={onDelete}>
              Delete
            </button>
          )}
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button className="button primary" disabled={!name.trim()} onClick={save}>
            Save
          </button>
        </>
      }
    >
      <Field label="Name" value={name} onChange={setName} autoFocus />
      <Field label="What it is" value={description} onChange={setDescription} />
      <Field
        label="Repository URL"
        value={repoUrl}
        onChange={setRepoUrl}
        placeholder="https://github.com/acme/app"
      />
      <Field label="Default branch" value={branch} onChange={setBranch} />
      <Field
        label="Dev server command"
        value={devCommand}
        onChange={setDevCommand}
        placeholder="npm run dev"
      />
      <Field label="Dev server port" value={devPort} onChange={setDevPort} />

      <div className="section-title">On this machine</div>
      <div className="row">
        <span className="grow sub">{localPath || "not set up here"}</span>
        <button
          className="button"
          onClick={async () => {
            const chosen = await pickDirectory();
            if (chosen) setLocalPath(chosen);
          }}
        >
          Choose folder
        </button>
      </div>

      <div className="section-title">On other machines</div>
      {app.hosts.map((host) => (
        <div className="form-row" key={host.id}>
          <label>{host.name}</label>
          <input
            className="field"
            value={paths[host.id] ?? ""}
            placeholder="/absolute/path"
            onChange={(event) =>
              setPaths({ ...paths, [host.id]: event.target.value })
            }
          />
        </div>
      ))}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- members ---------------------------------------------------------------

export function MembersPage() {
  const app = useApp();
  const api = useApi();
  const [invite, setInvite] = useState<string>();
  const humans = app.members.filter((member) => member.kind === "human");

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Members</span>
        <span className="spacer" />
        <button
          className="button primary"
          onClick={async () => {
            const created = await api.createInvite({ is_admin: false });
            setInvite(created.code);
          }}
        >
          Invite someone
        </button>
      </div>
      <div className="page">
        <div className="page-inner">
          {humans.map((member) => (
            <div className="row" key={member.id}>
              <Avatar member={member} size={26} />
              <span className="grow">
                <span className="name">{member.display_name}</span>
                <span className="sub">
                  @{member.handle}
                  {member.email ? ` · ${member.email}` : ""}
                </span>
              </span>
              {member.is_admin && <Chip>admin</Chip>}
              <span className={`dot ${member.presence}`} />
            </div>
          ))}
        </div>
      </div>
      {invite && (
        <Modal
          title="Invite code"
          subtitle="They enter this and the relay URL in Patchwork Desktop."
          onClose={() => setInvite(undefined)}
          actions={
            <button className="button primary" onClick={() => setInvite(undefined)}>
              Done
            </button>
          }
        >
          <div className="card" style={{ marginTop: 12 }}>
            <code style={{ fontSize: 16 }}>{invite}</code>
          </div>
        </Modal>
      )}
    </div>
  );
}

// --- automations -----------------------------------------------------------

export function AutomationsPage() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [creating, setCreating] = useState(false);

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Automations</span>
        <span className="spacer" />
        <button className="button primary" onClick={() => setCreating(true)}>
          New automation
        </button>
      </div>
      <div className="page">
        <div className="page-inner">
          {app.automations.length === 0 && (
            <div className="empty">
              An automation tells an agent when to act, where to act, and where to
              report the result.
            </div>
          )}
          {app.automations.map((automation) => {
            const agent = app.members.find(
              (member) => member.id === automation.agent_id,
            );
            return (
              <div className="row" key={automation.id}>
                <span className="grow">
                  <span className="name">{automation.name}</span>
                  <span className="sub">
                    {describeTrigger(automation)} · {agent?.display_name ?? "no agent"}
                  </span>
                </span>
                {automation.failure_count > 0 && (
                  <Chip tone="danger">{automation.failure_count} failed</Chip>
                )}
                <Chip tone={automation.enabled ? "positive" : ""}>
                  {automation.enabled ? "on" : "paused"}
                </Chip>
                <button
                  className="button quiet"
                  onClick={() => api.runAutomation(automation.id)}
                >
                  Run now
                </button>
                <button
                  className="button quiet"
                  onClick={() => go({ kind: "automation", id: automation.id })}
                >
                  Debug
                </button>
              </div>
            );
          })}
        </div>
      </div>
      {creating && <AutomationModal onClose={() => setCreating(false)} />}
    </div>
  );
}

function describeTrigger(automation: Automation) {
  const trigger = automation.trigger;
  switch (trigger.type) {
    case "schedule":
      return `every ${Math.round(trigger.every_seconds / 60)} min`;
    case "message":
      return "on new messages";
    case "task_status":
      return `when a task enters ${trigger.status}`;
    case "task_assigned":
      return "when a task is assigned";
    case "pull_request":
      return "on pull request activity";
    case "webhook":
      return "on webhook";
    case "manual":
      return "manual";
  }
}

function AutomationModal({ onClose }: { onClose: () => void }) {
  const app = useApp();
  const api = useApi();
  const [name, setName] = useState("");
  const [agentId, setAgentId] = useState(
    app.members.find((member) => member.kind === "agent")?.id ?? "",
  );
  const [triggerKind, setTriggerKind] = useState("schedule");
  const [minutes, setMinutes] = useState("60");
  const [channelId, setChannelId] = useState(
    app.channels.find((channel) => channel.kind === "channel")?.id ?? "",
  );
  const [pattern, setPattern] = useState("");
  const [status, setStatus] = useState("review");
  const [action, setAction] = useState("post_in_chat");
  const [instructions, setInstructions] = useState("");
  const [error, setError] = useState("");

  const trigger = () => {
    switch (triggerKind) {
      case "schedule":
        return { type: "schedule", every_seconds: Number(minutes) * 60 };
      case "message":
        return {
          type: "message",
          channel_id: channelId,
          pattern,
          include_agents: false,
        };
      case "task_status":
        return { type: "task_status", status };
      case "task_assigned":
        return { type: "task_assigned" };
      case "pull_request":
        return {
          type: "pull_request",
          on_review_comment: true,
          on_checks_failed: true,
        };
      case "webhook":
        return { type: "webhook", token: crypto.randomUUID() };
      default:
        return { type: "manual" };
    }
  };

  const save = async () => {
    setError("");
    try {
      await api.createAutomation({
        name,
        trigger: trigger(),
        agent_id: agentId,
        action,
        instructions,
        context_channel_id: channelId || undefined,
        report_channel_id: channelId || undefined,
        enabled: true,
      });
      onClose();
    } catch (err) {
      setError(String((err as Error).message ?? err));
    }
  };

  return (
    <Modal
      title="New automation"
      subtitle="What fires it, which agent acts, and where the result lands."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={!name.trim() || !agentId}
            onClick={save}
          >
            Create
          </button>
        </>
      }
    >
      <Field label="Name" value={name} onChange={setName} autoFocus />
      <Select
        label="Agent"
        value={agentId}
        onChange={setAgentId}
        options={app.members
          .filter((member) => member.kind === "agent")
          .map((member) => ({ value: member.id, label: member.display_name }))}
      />
      <Select
        label="Trigger"
        value={triggerKind}
        onChange={setTriggerKind}
        options={[
          { value: "schedule", label: "On a schedule" },
          { value: "message", label: "On a new message" },
          { value: "task_status", label: "When a task changes status" },
          { value: "task_assigned", label: "When a task is assigned to it" },
          { value: "pull_request", label: "On pull request activity" },
          { value: "webhook", label: "On an incoming webhook" },
          { value: "manual", label: "Only when run manually" },
        ]}
      />
      {triggerKind === "schedule" && (
        <Field label="Every (minutes)" value={minutes} onChange={setMinutes} />
      )}
      {triggerKind === "message" && (
        <Field
          label="Only messages matching (optional)"
          value={pattern}
          onChange={setPattern}
          placeholder="refund|cancel"
        />
      )}
      {triggerKind === "task_status" && (
        <Select
          label="Status"
          value={status}
          onChange={setStatus}
          options={["planned", "running", "blocked", "review", "done"].map((value) => ({
            value,
            label: value,
          }))}
        />
      )}
      <Select
        label="Channel for context and reporting"
        value={channelId}
        onChange={setChannelId}
        options={[
          { value: "", label: "None" },
          ...app.channels
            .filter((channel) => channel.kind === "channel")
            .map((channel) => ({ value: channel.id, label: `#${channel.name}` })),
        ]}
      />
      <Select
        label="What it does"
        value={action}
        onChange={setAction}
        options={[
          { value: "post_in_chat", label: "Post in chat" },
          { value: "create_task", label: "Create a task and work on it" },
          { value: "continue_task", label: "Continue the task that triggered it" },
        ]}
      />
      <Field
        label="Instructions"
        value={instructions}
        onChange={setInstructions}
        textarea
        placeholder="What should the agent do when this fires?"
      />
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

/// The debugger exists for understanding failures: what fired, what it picked,
/// what context it got, and what happened.
export function AutomationDebugPage({ automationId }: { automationId: string }) {
  const api = useApi();
  const app = useApp();
  const { inspect, go } = useNavigation();
  const [debug, setDebug] = useState<AutomationDebug>();

  useEffect(() => {
    void api.automationDebug(automationId).then(setDebug);
  }, [automationId, app.automations, app.runs]);

  if (!debug) return <div className="empty">Loading…</div>;
  const automation = debug.automation;
  const agent = app.members.find((member) => member.id === automation.agent_id);

  return (
    <div className="column">
      <div className="topbar">
        <button className="button quiet" onClick={() => go({ kind: "automations" })}>
          ‹ Automations
        </button>
        <span className="title">{automation.name}</span>
        <span className="spacer" />
        <button
          className="button"
          onClick={() =>
            api.updateAutomation(automation.id, {
              ...automation,
              enabled: !automation.enabled,
            })
          }
        >
          {automation.enabled ? "Pause" : "Resume"}
        </button>
        <button
          className="button primary"
          onClick={() => api.runAutomation(automation.id)}
        >
          Run again
        </button>
      </div>

      <div className="page">
        <div className="page-inner wide">
          <div className="card-row">
            <Chip>{describeTrigger(automation)}</Chip>
            <Chip>{agent?.display_name ?? "no agent"}</Chip>
            <Chip>{automation.action.replace(/_/g, " ")}</Chip>
            {automation.next_run_at && (
              <Chip>next {relative(automation.next_run_at)}</Chip>
            )}
          </div>
          {automation.trigger.type === "webhook" && (
            <div className="card" style={{ marginTop: 10 }}>
              <div className="card-head">Webhook</div>
              <code style={{ wordBreak: "break-all" }}>
                POST {api.baseUrl}/api/webhooks/{automation.trigger.token}
              </code>
            </div>
          )}

          <div className="section-title">Runs</div>
          {debug.runs.length === 0 && (
            <div className="card-sub">This automation has not fired yet.</div>
          )}
          {debug.runs.map((run) => (
            <div className="card" key={run.id} style={{ maxWidth: "none" }}>
              <div className="card-head">
                <span>{relative(run.created_at)}</span>
                <span className="spacer" />
                <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
              </div>
              <div className="card-title">{run.trigger_summary}</div>
              {run.error && <div className="error-text">{run.error}</div>}
              {run.selection != null && (
                <details style={{ marginTop: 8 }}>
                  <summary className="card-sub">What it selected</summary>
                  <pre className="run-event text" style={{ whiteSpace: "pre-wrap" }}>
                    {JSON.stringify(run.selection, null, 2)}
                  </pre>
                </details>
              )}
              {run.context_preview && (
                <details style={{ marginTop: 4 }}>
                  <summary className="card-sub">Context it received</summary>
                  <pre className="run-event text" style={{ whiteSpace: "pre-wrap" }}>
                    {run.context_preview}
                  </pre>
                </details>
              )}
              <div className="card-row">
                {run.run_id && (
                  <button
                    className="button quiet"
                    onClick={() => inspect({ kind: "run", runId: run.run_id! })}
                  >
                    Open run log
                  </button>
                )}
                {run.task_id && (
                  <button
                    className="button quiet"
                    onClick={() => go({ kind: "task", id: run.task_id! })}
                  >
                    Open task
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

// --- settings --------------------------------------------------------------

export function SettingsPage({ onSignOut }: { onSignOut: () => void }) {
  const app = useApp();
  const api = useApi();
  const [info, setInfo] = useState<DesktopInfo>();
  const [name, setName] = useState(app.workspace?.name ?? "");

  useEffect(() => {
    void desktopInfo().then((loaded) => setInfo(loaded));
  }, [app.hosts]);

  return (
    <div className="column">
      <div className="topbar">
        <span className="title">Settings</span>
      </div>
      <div className="page">
        <div className="page-inner">
          <div className="section-title">Workspace</div>
          <Field label="Name" value={name} onChange={setName} />
          <button
            className="button"
            style={{ marginTop: 8 }}
            onClick={() => api.renameWorkspace(name)}
          >
            Save
          </button>

          <div className="section-title">This machine</div>
          <div className="row">
            <span className={`dot ${info?.host.connected ? "online" : ""}`} />
            <span className="grow">
              <span className="name">{info?.host.host_name || "not connected"}</span>
              <span className="sub">
                {info?.platform}
                {info?.host.last_error ? ` · ${info.host.last_error}` : ""}
              </span>
            </span>
          </div>
          {info?.capabilities.runtimes.map((runtime) => (
            <div className="row" key={runtime.id}>
              <span className="grow">
                <span className="name">{runtime.label}</span>
                <span className="sub">
                  {runtime.problem ?? runtime.version ?? runtime.command.join(" ")}
                </span>
              </span>
              <Chip tone={runtime.available ? "positive" : "caution"}>
                {runtime.available ? "ready" : "unavailable"}
              </Chip>
            </div>
          ))}

          <div className="section-title">Relay</div>
          <div className="row">
            <span className="grow">
              <span className="name">{info?.settings.relay_url}</span>
              <span className="sub">
                {app.live ? "connected" : "reconnecting…"}
              </span>
            </span>
            <button
              className="button quiet"
              onClick={() => openExternal(`${info?.settings.relay_url}/api/health`)}
            >
              Health
            </button>
          </div>

          <div className="section-title">Account</div>
          <button
            className="button"
            onClick={async () => {
              await signOut();
              onSignOut();
            }}
          >
            Sign out of this workspace
          </button>
        </div>
      </div>
    </div>
  );
}
