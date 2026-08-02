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
import { Avatar, Chip, Field, Modal, useNavigation } from "./common";
import { Dropdown, Empty, FormSelect, Page, Section, Toggle } from "./ui";
import {
  CheckIcon,
  ExternalIcon,
  FolderIcon,
  PlusIcon,
  Spinner,
} from "./icons";
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
    <Page
      title="Agents"
      actions={
        <button className="button" onClick={() => setCreating(true)}>
          <PlusIcon size={15} />
          New agent
        </button>
      }
    >
      {agents.length === 0 ? (
        <Empty
          title="No agents yet"
          hint="An agent is a teammate: a name, a description that defines what it owns, a runtime, and where it runs."
          action={
            <button className="button primary" onClick={() => setCreating(true)}>
              Create the first agent
            </button>
          }
        />
      ) : (
        agents.map((agent) => (
          <button key={agent.id} className="row" onClick={() => setEditing(agent)}>
            <Avatar member={agent} size={30} />
            <span className="grow">
              <span className="name">{agent.display_name}</span>
              <span className="sub">
                @{agent.handle}
                {agent.agent?.description ? ` · ${agent.agent.description}` : ""}
              </span>
            </span>
            <Chip>{agent.agent?.runtime}</Chip>
            <Chip tone={agent.presence === "working" ? "accent" : ""}>
              {locationLabel(agent.agent)}
            </Chip>
          </button>
        ))
      )}

      {(creating || editing) && (
        <AgentModal
          agent={editing}
          onClose={() => {
            setCreating(false);
            setEditing(null);
          }}
        />
      )}
    </Page>
  );
}

function locationLabel(profile?: AgentProfile) {
  switch (profile?.location) {
    case "relay":
      return "on the relay";
    case "desktop":
      return "on a desktop";
    default:
      return "wherever the project is";
  }
}

function AgentModal({ agent, onClose }: { agent: Member | null; onClose: () => void }) {
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
        host.capabilities.runtimes
          .filter((runtime) => runtime.available)
          .map((runtime) => runtime.id),
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
          <button className="button primary" disabled={!name.trim() || busy} onClick={save}>
            {busy ? "Saving…" : "Save"}
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
      <FormSelect
        label="Runtime"
        value={profile.runtime}
        onChange={(runtime) => setProfile({ ...profile, runtime })}
        options={(runtimes.length ? runtimes : ["codex", "claude", "pi"])
          .concat("custom")
          .map((runtime) => ({ value: runtime, label: runtime }))}
        help="Detected on the machines connected to this workspace."
      />
      {profile.runtime === "custom" && (
        <Field
          label="ACP command"
          value={(profile.custom_command ?? []).join(" ")}
          onChange={(value) =>
            setProfile({
              ...profile,
              custom_command: value.split(/\s+/).filter(Boolean),
            })
          }
          placeholder="my-agent --acp"
        />
      )}
      <FormSelect
        label="Runs on"
        value={profile.location}
        onChange={(location) =>
          setProfile({ ...profile, location: location as AgentProfile["location"] })
        }
        options={[
          { value: "auto", label: "Wherever the project is available" },
          { value: "relay", label: "The relay", hint: "keeps working when laptops close" },
          { value: "desktop", label: "A specific desktop" },
        ]}
      />
      {profile.location === "desktop" && (
        <FormSelect
          label="Machine"
          value={profile.host_id ?? ""}
          onChange={(host_id) => setProfile({ ...profile, host_id })}
          options={[
            { value: "", label: "Pick a machine" },
            ...app.hosts
              .filter((host) => host.kind === "desktop")
              .map((host) => ({
                value: host.id,
                label: host.name,
                hint: host.online ? "online" : "offline",
              })),
          ]}
        />
      )}
      <FormSelect
        label="Default participation"
        value={profile.default_participation}
        onChange={(value) =>
          setProfile({ ...profile, default_participation: value as Participation })
        }
        options={[
          { value: "mention", label: "Only when mentioned" },
          { value: "ambient", label: "Ambient", hint: "may chime in when it has something to add" },
          { value: "off", label: "Never speaks on its own" },
        ]}
      />

      <Toggle
        checked={profile.dm_enabled}
        onChange={(dm_enabled) => setProfile({ ...profile, dm_enabled })}
        label="Available in direct messages"
        help="Shows up under Direct messages for everyone."
      />

      {app.channels.some((channel) => channel.kind === "channel") && (
        <Section title="Per-channel participation">
          {app.channels
            .filter((channel) => channel.kind === "channel")
            .map((channel) => (
              <div className="row hoverable" key={channel.id}>
                <span className="grow name">#{channel.name}</span>
                <Dropdown
                  quiet
                  align="right"
                  width={130}
                  value={
                    profile.channel_participation[channel.id] ??
                    profile.default_participation
                  }
                  onChange={(value) =>
                    setProfile({
                      ...profile,
                      channel_participation: {
                        ...profile.channel_participation,
                        [channel.id]: value as Participation,
                      },
                    })
                  }
                  options={[
                    { value: "off", label: "Off" },
                    { value: "mention", label: "Mention" },
                    { value: "ambient", label: "Ambient" },
                  ]}
                />
              </div>
            ))}
        </Section>
      )}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- projects and machines --------------------------------------------------

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
    <Page
      title="Projects and machines"
      actions={
        <button className="button" onClick={() => setCreating(true)}>
          <PlusIcon size={15} />
          New project
        </button>
      }
    >
      <Section title="Projects">
        {app.projects.length === 0 ? (
          <Empty
            title="No projects yet"
            hint="A project connects business context to a git repository or an ordinary folder, on every machine that has it."
            action={
              <button className="button primary" onClick={() => setCreating(true)}>
                Add a project
              </button>
            }
          />
        ) : (
          app.projects.map((project) => (
            <button
              key={project.id}
              className="row"
              onClick={() => setEditing(project)}
            >
              <span style={{ color: "var(--text-muted)", display: "flex" }}>
                <FolderIcon />
              </span>
              <span className="grow">
                <span className="name">{project.name}</span>
                <span className="sub">
                  {project.description ||
                    project.repo_url ||
                    "no description yet"}
                </span>
              </span>
              <Chip>
                {Object.keys(project.paths).length} machine
                {Object.keys(project.paths).length === 1 ? "" : "s"}
              </Chip>
              {project.dev_command && <Chip tone="accent">preview</Chip>}
            </button>
          ))
        )}
      </Section>

      <Section title="Execution machines">
        {app.hosts.map((host) => {
          const ready = host.capabilities.runtimes.filter(
            (runtime) => runtime.available && runtime.id !== "custom",
          );
          return (
            <div className="row hoverable" key={host.id}>
              <span className={`dot ${host.online ? "online" : ""}`} />
              <span className="grow">
                <span className="name">{host.name}</span>
                <span className="sub">
                  {host.platform}
                  {ready.length
                    ? ` · ${ready.map((runtime) => runtime.label).join(", ")}`
                    : " · no agent installations detected"}
                </span>
              </span>
              {host.capabilities.has_gh && (
                <Chip tone={host.capabilities.gh_authenticated ? "positive" : "caution"}>
                  gh
                </Chip>
              )}
              <Chip tone={host.online ? "positive" : ""}>
                {host.online ? "online" : `seen ${relative(host.last_seen)}`}
              </Chip>
            </div>
          );
        })}
      </Section>

      {info && info.capabilities.notes.length > 0 && (
        <Section title="This machine">
          {info.capabilities.notes.map((note) => (
            <div className="row" key={note}>
              <span className="grow sub">{note}</span>
            </div>
          ))}
        </Section>
      )}

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
    </Page>
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

  const otherHosts = app.hosts.filter((host) => host.kind === "relay");

  return (
    <Modal
      title={project ? project.name : "New project"}
      subtitle="Where the code lives, on each machine that has it."
      onClose={onClose}
      actions={
        <>
          {onDelete && (
            <button className="button quiet danger" onClick={onDelete}>
              Delete
            </button>
          )}
          <span className="spacer" />
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

      <Section title="This machine">
        <div className="row hoverable">
          <span className="grow sub" style={{ wordBreak: "break-all" }}>
            {localPath || "not set up here"}
          </span>
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
      </Section>

      {otherHosts.length > 0 && (
        <Section title="On the relay">
          {otherHosts.map((host) => (
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
        </Section>
      )}

      <Section title="Previews">
        <Field
          label="Dev server command"
          value={devCommand}
          onChange={setDevCommand}
          placeholder="npm run dev"
        />
        <Field label="Port" value={devPort} onChange={setDevPort} placeholder="5173" />
      </Section>

      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- members ---------------------------------------------------------------

export function MembersPage() {
  const app = useApp();
  const api = useApi();
  const [invite, setInvite] = useState<string>();
  const [copied, setCopied] = useState(false);
  const humans = app.members.filter((member) => member.kind === "human");

  return (
    <Page
      title="Members"
      actions={
        <button
          className="button"
          onClick={async () => {
            const created = await api.createInvite({ is_admin: false });
            setInvite(created.code);
            setCopied(false);
          }}
        >
          <PlusIcon size={15} />
          Invite someone
        </button>
      }
    >
      {humans.map((member) => (
        <div className="row hoverable" key={member.id}>
          <Avatar member={member} size={30} />
          <span className="grow">
            <span className="name">{member.display_name}</span>
            <span className="sub">
              @{member.handle}
              {member.email ? ` · ${member.email}` : ""}
            </span>
          </span>
          {member.is_admin && <Chip>admin</Chip>}
          <Chip tone={member.presence === "online" ? "positive" : ""}>
            {member.presence}
          </Chip>
        </div>
      ))}

      {invite && (
        <Modal
          title="Invite code"
          subtitle="They enter this and your relay URL in Patchwork Desktop."
          onClose={() => setInvite(undefined)}
          actions={
            <button className="button primary" onClick={() => setInvite(undefined)}>
              Done
            </button>
          }
        >
          <div className="invite-code">
            <code>{invite}</code>
            <button
              className="button quiet"
              onClick={() => {
                void navigator.clipboard.writeText(invite);
                setCopied(true);
              }}
            >
              {copied ? <CheckIcon size={15} /> : null}
              {copied ? "Copied" : "Copy"}
            </button>
          </div>
        </Modal>
      )}
    </Page>
  );
}

// --- automations -----------------------------------------------------------

export function AutomationsPage() {
  const app = useApp();
  const api = useApi();
  const { go } = useNavigation();
  const [creating, setCreating] = useState(false);

  return (
    <Page
      title="Automations"
      actions={
        <button className="button" onClick={() => setCreating(true)}>
          <PlusIcon size={15} />
          New automation
        </button>
      }
    >
      {app.automations.length === 0 ? (
        <Empty
          title="No automations yet"
          hint="An automation says what fires it, which agent acts, where it gets context, and where it reports."
          action={
            <button className="button primary" onClick={() => setCreating(true)}>
              Create an automation
            </button>
          }
        />
      ) : (
        app.automations.map((automation) => {
          const agent = app.members.find(
            (member) => member.id === automation.agent_id,
          );
          return (
            <button
              key={automation.id}
              className="row"
              onClick={() => go({ kind: "automation", id: automation.id })}
            >
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
              <span
                className="button quiet"
                onClick={(event) => {
                  event.stopPropagation();
                  void api.runAutomation(automation.id);
                }}
              >
                Run now
              </span>
            </button>
          );
        })
      )}

      {creating && <AutomationModal onClose={() => setCreating(false)} />}
    </Page>
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
      return "manual only";
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
      <FormSelect
        label="Agent"
        value={agentId}
        onChange={setAgentId}
        options={app.members
          .filter((member) => member.kind === "agent")
          .map((member) => ({
            value: member.id,
            label: member.display_name,
            hint: member.agent?.runtime,
          }))}
      />
      <FormSelect
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
        <FormSelect
          label="Status"
          value={status}
          onChange={setStatus}
          options={["planned", "running", "blocked", "review", "done"].map((value) => ({
            value,
            label: statusLabel(value as never),
          }))}
        />
      )}
      <FormSelect
        label="Channel for context and reporting"
        value={channelId}
        onChange={setChannelId}
        options={[
          { value: "", label: "None" },
          ...app.channels
            .filter((channel) => channel.kind === "channel")
            .map((channel) => ({ value: channel.id, label: `#${channel.name}` })),
        ]}
        help="The automation stays connected to this conversation rather than copying it."
      />
      <FormSelect
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

  if (!debug) return <Empty title="Loading" />;
  const automation = debug.automation;
  const agent = app.members.find((member) => member.id === automation.agent_id);

  return (
    <Page
      wide
      title={automation.name}
      back={{ label: "Automations", onClick: () => go({ kind: "automations" }) }}
      actions={
        <>
          <button
            className="button quiet"
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
            className="button"
            onClick={() => api.runAutomation(automation.id)}
          >
            Run now
          </button>
        </>
      }
    >
      <div className="card-row" style={{ marginTop: 14 }}>
        <Chip>{describeTrigger(automation)}</Chip>
        <Chip>{agent?.display_name ?? "no agent"}</Chip>
        <Chip>{automation.action.replace(/_/g, " ")}</Chip>
        {automation.next_run_at && <Chip>next {relative(automation.next_run_at)}</Chip>}
        <Chip tone={automation.enabled ? "positive" : ""}>
          {automation.enabled ? "on" : "paused"}
        </Chip>
      </div>

      {automation.trigger.type === "webhook" && (
        <div className="card" style={{ maxWidth: "none", marginTop: 14 }}>
          <div className="card-head">Webhook</div>
          <code style={{ wordBreak: "break-all" }}>
            POST {api.baseUrl}/api/webhooks/{automation.trigger.token}
          </code>
        </div>
      )}

      <Section title="Runs">
        {debug.runs.length === 0 ? (
          <Empty
            title="This automation has not fired yet"
            hint="Every firing records its trigger, what it selected, and the context the agent received."
          />
        ) : (
          debug.runs.map((run) => (
            <div className="card" key={run.id} style={{ maxWidth: "none" }}>
              <div className="card-head">
                {run.status === "running" ? <Spinner size={13} /> : null}
                <span>{relative(run.created_at)}</span>
                <span className="spacer" />
                <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
              </div>
              <div className="card-title">{run.trigger_summary}</div>
              {run.error && <div className="error-text">{run.error}</div>}
              {run.selection != null && (
                <details style={{ marginTop: 10 }}>
                  <summary>What it selected</summary>
                  <pre className="code-block">
                    {JSON.stringify(run.selection, null, 2)}
                  </pre>
                </details>
              )}
              {run.context_preview && (
                <details style={{ marginTop: 6 }}>
                  <summary>Context it received</summary>
                  <pre className="code-block">{run.context_preview}</pre>
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
          ))
        )}
      </Section>
    </Page>
  );
}

// --- settings --------------------------------------------------------------

export function SettingsPage({ onSignOut }: { onSignOut: () => void }) {
  const app = useApp();
  const api = useApi();
  const [info, setInfo] = useState<DesktopInfo>();
  const [name, setName] = useState(app.workspace?.name ?? "");
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    void desktopInfo().then(setInfo);
  }, [app.hosts]);

  return (
    <Page title="Settings">
      <Section title="Workspace">
        <Field label="Name" value={name} onChange={setName} />
        <button
          className="button"
          style={{ marginTop: 10 }}
          disabled={!name.trim() || name === app.workspace?.name}
          onClick={async () => {
            await api.renameWorkspace(name);
            setSaved(true);
            window.setTimeout(() => setSaved(false), 1800);
          }}
        >
          {saved ? <CheckIcon size={15} /> : null}
          {saved ? "Saved" : "Save"}
        </button>
      </Section>

      <Section title="This machine">
        <div className="row hoverable">
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
          <div className="row hoverable" key={runtime.id}>
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
      </Section>

      <Section title="Relay">
        <div className="row hoverable">
          <span className={`dot ${app.live ? "online" : "waiting"}`} />
          <span className="grow">
            <span className="name">{info?.settings.relay_url}</span>
            <span className="sub">{app.live ? "connected" : "reconnecting…"}</span>
          </span>
          <button
            className="button quiet"
            onClick={() => openExternal(`${info?.settings.relay_url}/api/health`)}
          >
            <ExternalIcon size={14} />
            Health
          </button>
        </div>
      </Section>

      <Section title="Account">
        <button
          className="button quiet danger"
          onClick={async () => {
            await signOut();
            onSignOut();
          }}
        >
          Sign out of this workspace
        </button>
      </Section>
    </Page>
  );
}
