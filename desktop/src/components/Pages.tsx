import { useEffect, useMemo, useRef, useState } from "react";
import { useApi, useApp, useWorkspaces } from "../lib/store";
import { relative, statusLabel, statusTone } from "../lib/format";
import {
  desktopBoot,
  desktopInfo,
  inTauri,
  openExternal,
  pickDirectory,
  piLogin,
  providerCatalog,
  setAwakePolicy,
  setProjectPaths,
  setProviderKey,
} from "../lib/desktop";
import { leave, signOutOfEverything, switchTo } from "../lib/session";
import type { AwakePolicy } from "../lib/desktop";
import type { DesktopInfo, ProviderInfo } from "../lib/desktop";
import {
  Avatar,
  Chip,
  Field,
  Modal,
  plainText,
  useAsync,
  useNavigation,
  WorkspaceMark,
} from "./common";
import {
  Dropdown,
  Empty,
  FormSelect,
  MenuButton,
  Page,
  Section,
  Toggle,
} from "./ui";
import {
  CheckIcon,
  ChevronIcon,
  ExternalIcon,
  FolderIcon,
  MoreIcon,
  PencilIcon,
  PlusIcon,
  Spinner,
  TrashIcon,
} from "./icons";
import { RuntimeIcon } from "./RuntimeIcon";
import { PairDeviceModal } from "./PairDeviceModal";
import { describeCron, PRESETS, presetFor, WEEKDAYS } from "../lib/schedule";
import { TASK_STATUSES } from "@client/types";
import type {
  AgentProfile,
  Automation,
  AutomationDebug,
  AutomationRun,
  Host,
  Id,
  Member,
  Participation,
  Project,
  RuntimeInstallation,
  RuntimeOption,
} from "@client/types";

/// A string that changes when the machine list meaningfully changes — a host
/// appearing, disappearing, or going up or down — and stays put through the
/// `last_seen` bump every heartbeat brings.
function useHostSignature(hosts: Host[]): string {
  return useMemo(
    () => hosts.map((host) => `${host.id}:${host.online ? 1 : 0}`).join(","),
    [hosts],
  );
}

// --- agents ----------------------------------------------------------------

export function AgentsPage() {
  const app = useApp();
  const api = useApi();
  const [editing, setEditing] = useState<Member | null>(null);
  const [creating, setCreating] = useState(false);
  const [addingManager, setAddingManager] = useState(false);
  const [error, setError] = useState("");
  const agents = app.members.filter((member) => member.kind === "agent");

  const addManager = async () => {
    const relay = app.hosts.find((host) => host.kind === "relay" && host.online);
    const runtimes = relay?.capabilities.runtimes.filter(
      (runtime) => runtime.available && runtime.id !== "custom",
    );
    const runtime =
      runtimes?.find((candidate) => candidate.id === "codex") ?? runtimes?.[0];
    setAddingManager(true);
    setError("");
    try {
      await api.createAgent({
        display_name: "Manager",
        is_admin: app.me?.is_admin ?? false,
        profile: {
          description:
            "Manages the workspace, triages requests, coordinates agents, and keeps tasks moving.",
          runtime: runtime?.id ?? "codex",
          location: relay ? "relay" : "auto",
          host_id: relay?.id,
          dm_enabled: true,
          default_participation: "mention",
          channel_participation: {},
          model: runtime?.default_model,
        },
      });
    } catch (err) {
      setError(String((err as Error).message ?? err));
    } finally {
      setAddingManager(false);
    }
  };

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
            <div className="field-row">
              <button
                className="button primary"
                disabled={addingManager}
                onClick={() => void addManager()}
              >
                {addingManager ? "Adding…" : "Add Manager (recommended)"}
              </button>
              <button className="button" onClick={() => setCreating(true)}>
                Create a custom agent
              </button>
            </div>
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
            {agent.is_admin && <Chip>admin</Chip>}
            <Chip>{agent.agent?.runtime}</Chip>
            <Chip tone={agent.presence === "working" ? "accent" : ""}>
              {locationLabel(agent.agent)}
            </Chip>
          </button>
        ))
      )}

      {error && <div className="error-text">{error}</div>}

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

export interface Machine {
  /// The host that work is actually dispatched to.
  host: Host;
  /// What to call it. A person recognises "Vince's laptop"; "Relay" is a role.
  name: string;
  /// Every host id living on this box, so "is this me" has one answer.
  hostIds: string[];
  isRelay: boolean;
  isDesktop: boolean;
}

/// One entry per physical machine.
///
/// The relay and the desktop app can be the same box — that is the normal setup
/// for one person working alone — and offering "Codex on Vince's laptop" and
/// "Codex on Relay" as separate choices is offering the same computer twice.
/// Work is dispatched to the relay side, because an agent there keeps going
/// when the app is closed, which is the whole reason to run one; the name comes
/// from the desktop side, because that is the one a person named.
export function distinctMachines(hosts: Host[]): Machine[] {
  const out: Machine[] = [];
  const byKey = new Map<string, Machine>();

  for (const host of hosts) {
    const key = host.capabilities.machine_key;
    const isRelay = host.kind === "relay";
    const existing = key ? byKey.get(key) : undefined;

    if (!existing) {
      const machine: Machine = {
        host,
        name: host.name,
        hostIds: [host.id],
        isRelay,
        isDesktop: !isRelay,
      };
      if (key) byKey.set(key, machine);
      out.push(machine);
      continue;
    }

    existing.hostIds.push(host.id);
    existing.isRelay ||= isRelay;
    existing.isDesktop ||= !isRelay;
    // Dispatch to the relay; keep whichever name a human chose.
    if (isRelay) {
      existing.host = host;
    } else {
      existing.name = host.name;
    }
  }
  return out;
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

/// Long enough to browse, short enough to scroll. Past this the field's own
/// filtering is the better tool.
const MODEL_MENU_LIMIT = 40;

/// A model by its id, typed or picked.
///
/// A list is a suggestion, not the truth: a runtime only reports what it can
/// run once it has opened a session, and providers add models faster than
/// anything here learns about them. So the field is an input, and the list
/// fills it in.
function ModelField({
  value,
  onChange,
  models,
  fallback,
  help,
}: {
  value: string;
  onChange: (value: string) => void;
  models: RuntimeOption[];
  /// What runs when the field is empty.
  fallback?: string;
  help: string;
}) {
  return (
    <div className="form-row">
      <label>Model</label>
      <div className="field-row">
        <input
          className="field grow"
          {...plainText}
          list={models.length > 0 ? "runtime-models" : undefined}
          value={value}
          placeholder={
            fallback ? `${fallback} — the default` : "whatever the machine is set to"
          }
          onChange={(event) => onChange(event.target.value)}
        />
        {/* Some runtimes report a thousand models. Typing filters them; the
            menu is for browsing, so it shows a readable number and says so. */}
        {models.length > 0 && (
          <datalist id="runtime-models">
            {models.map((model) => (
              <option key={model.id} value={model.id}>
                {model.name}
              </option>
            ))}
          </datalist>
        )}
        {models.length > 0 && (
          <MenuButton
            align="right"
            title="Models this runtime reported"
            header={
              models.length > MODEL_MENU_LIMIT
                ? `${models.length} models — type to filter`
                : "Reported by the runtime"
            }
            items={[
              {
                key: "",
                label: fallback ? `${fallback} — the default` : "The machine's default",
                onSelect: () => onChange(""),
              },
              ...models.slice(0, MODEL_MENU_LIMIT).map((model) => ({
                key: model.id,
                label: model.name,
                hint: model.description || model.id,
                onSelect: () => onChange(model.id),
              })),
            ]}
          >
            <ChevronIcon size={14} />
          </MenuButton>
        )}
      </div>
      <span className="form-help">{help}</span>
    </div>
  );
}

/// Store a provider key, sign into a subscription, or forget one. Used both
/// in Settings and wherever a provider is being chosen, because "add one in
/// Settings" is a worse answer than a box to paste it in.
function ProviderKeyControls({
  provider,
  stored,
  onChanged,
}: {
  provider: ProviderInfo;
  stored: boolean;
  onChanged: (keys: Record<string, string>) => void;
}) {
  const { toast } = useNavigation();
  const [draft, setDraft] = useState("");
  const [command, setCommand] = useState("");

  const save = async (key: string) => {
    try {
      const settings = await setProviderKey(provider.id, key);
      setDraft("");
      onChanged(settings.provider_keys);
    } catch (err) {
      toast(String((err as Error).message ?? err));
    }
  };

  if (stored) {
    return (
      <>
        <Chip tone="positive">key stored</Chip>
        <button className="button quiet danger" onClick={() => void save("")}>
          Remove
        </button>
      </>
    );
  }

  if (provider.subscription) {
    return (
      <>
        <button
          className="button"
          onClick={async () => {
            try {
              setCommand(await piLogin(provider.id));
            } catch (err) {
              toast(String((err as Error).message ?? err));
            }
          }}
        >
          Sign in
        </button>
        {command && (
          <div className="notice">
            Run this in a terminal to finish signing in
            <pre className="code-block">{command}</pre>
          </div>
        )}
      </>
    );
  }

  return (
    <>
      <input
        className="field grow"
        {...plainText}
        type="password"
        placeholder={provider.env_var}
        value={draft}
        onChange={(event) => setDraft(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter" && draft.trim()) void save(draft.trim());
        }}
      />
      <button
        className="button"
        disabled={!draft.trim()}
        onClick={() => void save(draft.trim())}
      >
        Save
      </button>
    </>
  );
}

export function AgentModal({
  agent,
  onClose,
}: {
  agent: Member | null;
  onClose: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const [name, setName] = useState(agent?.display_name ?? "");
  const [isAdmin, setIsAdmin] = useState(agent?.is_admin ?? false);
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

  // "Which runtime" and "which machine" were two questions with one answer:
  // an agent runs a particular runtime *somewhere*, and the somewheres are
  // exactly the machines that have that runtime installed. One list, and every
  // entry in it is a combination that can actually run.
  const machines = useMemo(() => distinctMachines(app.hosts), [app.hosts]);

  const placements = useMemo(() => {
    const out: {
      value: string;
      label: string;
      hint?: string;
      runtime: string;
      location: AgentProfile["location"];
      host_id?: Id;
    }[] = [];
    const byRuntime = new Map<string, { label: string; machines: Machine[] }>();

    for (const machine of machines) {
      for (const runtime of machine.host.capabilities.runtimes) {
        if (!runtime.available || runtime.id === "custom") continue;
        const entry = byRuntime.get(runtime.id) ?? {
          label: runtime.label,
          machines: [],
        };
        entry.machines.push(machine);
        byRuntime.set(runtime.id, entry);
      }
    }

    for (const [id, { label, machines: where }] of byRuntime) {
      // Anywhere it can run — the right default, because a laptop that is shut
      // should not stop the work.
      out.push({
        value: `auto:${id}:`,
        label,
        hint:
          where.length > 1
            ? `on whichever machine has the project (${where.length} can)`
            : `on ${where[0].name}`,
        runtime: id,
        location: "auto",
      });
      if (where.length > 1) {
        for (const machine of where) {
          out.push({
            value: `${machine.host.kind === "relay" ? "relay" : "desktop"}:${id}:${machine.host.id}`,
            label: `${label} on ${machine.name}`,
            hint: machine.host.online ? "online" : "offline",
            runtime: id,
            location: machine.host.kind === "relay" ? "relay" : "desktop",
            host_id: machine.host.id,
          });
        }
      }
    }

    out.push({
      value: "auto:custom:",
      label: "A custom ACP command",
      runtime: "custom",
      location: "auto",
    });
    return out;
  }, [machines]);

  const placementValue = `${profile.location}:${profile.runtime}:${profile.host_id ?? ""}`;
  const chosenPlacement =
    placements.find((entry) => entry.value === placementValue) ??
    placements.find((entry) => entry.runtime === profile.runtime);

  // What that placement can actually think with. When it could run on several
  // machines, only offer models every one of them has — anything else would be
  // a setting that works until the run lands on the wrong laptop.
  const { models, thinking, defaultModel, defaultThinking } = useMemo(() => {
    const installs = machines
      .filter((machine) => !profile.host_id || machine.hostIds.includes(profile.host_id))
      .map((machine) =>
        machine.host.capabilities.runtimes.find(
          (runtime) => runtime.id === profile.runtime,
        ),
      )
      .filter((runtime): runtime is RuntimeInstallation => !!runtime)
      .filter((runtime) => runtime.models.length > 0 || runtime.thinking.length > 0);

    if (installs.length === 0) {
      return {
        models: [],
        thinking: [],
        defaultModel: undefined,
        defaultThinking: undefined,
      };
    }
    const shared = (pick: (r: RuntimeInstallation) => RuntimeOption[]) =>
      pick(installs[0]).filter((option) =>
        installs.every((install) => pick(install).some((o) => o.id === option.id)),
      );
    return {
      models: shared((runtime) => runtime.models),
      thinking: shared((runtime) => runtime.thinking),
      defaultModel: installs[0].default_model,
      defaultThinking: installs[0].default_thinking,
    };
  }, [machines, profile.runtime, profile.host_id]);

  // Our own runtime is the one with nothing to install, so the question it
  // asks instead is which model provider to think with — and whether the
  // machine you are sitting at has a key for it. Both are loaded together
  // because neither is worth a render on its own.
  const isPatchwork = profile.runtime === "patchwork";
  const { value: providers, setValue: setProviders } = useAsync(
    async () =>
      isPatchwork
        ? {
            list: await providerCatalog(),
            keys: (await desktopBoot()).settings.provider_keys,
          }
        : { list: [] as ProviderInfo[], keys: {} as Record<string, string> },
    [isPatchwork],
  );
  const provider = profile.provider ?? "openrouter";
  const chosenProvider = providers?.list.find((entry) => entry.id === provider);
  const providerUnkeyed = !!chosenProvider && !providers?.keys[provider];

  const save = async () => {
    setBusy(true);
    setError("");
    try {
      if (agent) {
        await api.updateAgent(agent.id, {
          display_name: name,
          is_admin: isAdmin,
          profile,
        });
      } else {
        await api.createAgent({ display_name: name, is_admin: isAdmin, profile });
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
        label="Runs on"
        value={chosenPlacement?.value ?? placementValue}
        onChange={(value) => {
          const entry = placements.find((candidate) => candidate.value === value);
          if (!entry) return;
          setProfile({
            ...profile,
            runtime: entry.runtime,
            location: entry.location,
            host_id: entry.host_id,
            // A model belongs to a runtime; carrying it across would set this
            // agent to a model the new runtime has never heard of.
            model: entry.runtime === profile.runtime ? profile.model : undefined,
            thinking: entry.runtime === profile.runtime ? profile.thinking : undefined,
            provider:
              entry.runtime === "patchwork"
                ? (profile.provider ?? "openrouter")
                : undefined,
          });
        }}
        options={placements.map((entry) => ({
          value: entry.value,
          label: entry.label,
          hint: entry.hint,
          icon: <RuntimeIcon runtime={entry.runtime} />,
        }))}
        help={
          placements.length <= 1
            ? "No machine has reported an agent runtime yet."
            : undefined
        }
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
      {isPatchwork && (
        <>
          <FormSelect
            label="Provider"
            value={provider}
            onChange={(value) => setProfile({ ...profile, provider: value })}
            options={(providers?.list ?? []).map((entry) => ({
              value: entry.id,
              label: entry.label,
              hint: entry.hint,
            }))}
            help="The Patchwork agent brings no model of its own."
          />
          {/* Asking for the key here rather than sending you to Settings: it
              is the one thing standing between this agent and its first run. */}
          {chosenProvider && (
            <div className="form-row">
              <label>
                {chosenProvider.label} key
                <span className="label-note">stays on this machine</span>
              </label>
              <div className="field-row">
                <ProviderKeyControls
                  provider={chosenProvider}
                  stored={!providerUnkeyed}
                  onChanged={(keys) =>
                    setProviders({ list: providers?.list ?? [], keys })
                  }
                />
              </div>
            </div>
          )}
        </>
      )}

      {profile.runtime === "custom" ? (
        <div className="form-row">
          <label>Model</label>
          <div className="notice">
            A custom command brings its own model configuration.
          </div>
        </div>
      ) : (
        <ModelField
          value={profile.model ?? ""}
          onChange={(model) => setProfile({ ...profile, model: model || undefined })}
          models={models}
          fallback={
            defaultModel ??
            (isPatchwork ? chosenProvider?.recommended_model : undefined)
          }
          help={
            models.length > 0
              ? "An id you can type, so a model this machine has not reported yet is still reachable."
              : "Type the model id. The picker fills in once the runtime has opened a session and said what it can run."
          }
        />
      )}

      {/* Permissions are not here on purpose: a run takes the widest mode its
          runtime offers. This is how hard it thinks, which is the setting
          that costs money and time. */}
      {thinking.length > 0 && (
        <FormSelect
          label="Thinking"
          value={profile.thinking ?? ""}
          onChange={(level) =>
            setProfile({ ...profile, thinking: level || undefined })
          }
          options={[
            {
              value: "",
              label: defaultThinking
                ? `The runtime's default (${defaultThinking})`
                : "The runtime's default",
            },
            ...thinking.map((level) => ({
              value: level.id,
              label: level.name,
              hint: level.description || undefined,
            })),
          ]}
          help="How hard this agent thinks before it answers."
        />
      )}
      <FormSelect
        label="Default project"
        value={profile.default_project_id ?? ""}
        onChange={(default_project_id) =>
          setProfile({
            ...profile,
            default_project_id: default_project_id || undefined,
          })
        }
        options={[
          { value: "", label: "None" },
          ...app.projects.map((project) => ({
            value: project.id,
            label: project.name,
          })),
        ]}
        help="Pre-selected when you give this agent a task."
      />
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

      {app.me?.is_admin && (
        <Toggle
          checked={isAdmin}
          onChange={setIsAdmin}
          label="Workspace administrator"
          help="Can change workspace settings, invite or remove members, and delete tasks or projects."
        />
      )}

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

  // Which machines exist and whether they are up — not every heartbeat. The
  // hosts array gets a new identity on each one, and re-asking this machine
  // about itself forty times an hour is work nobody sees.
  const hostSignature = useHostSignature(app.hosts);
  useEffect(() => {
    void desktopInfo().then(setInfo);
  }, [hostSignature]);

  return (
    <Page
      title="Projects and machines"
      subtitle="A repository every machine clones for itself, or a folder that already exists on one"
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
            hint="Paste a repository URL and the machines that run its tasks clone it themselves."
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
              {project.repo_url ? (
                <Chip>
                  {Object.keys(project.paths).length > 0
                    ? `cloned on ${Object.keys(project.paths).length}`
                    : "clones on demand"}
                </Chip>
              ) : (
                <Chip tone={Object.keys(project.paths).length ? "" : "caution"}>
                  {Object.keys(project.paths).length > 0
                    ? `folder on ${Object.keys(project.paths).length}`
                    : "no folder set"}
                </Chip>
              )}
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

export function ProjectModal({
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
  // A URL says what the project is called. Typing the name again is work
  // nobody needs to do, so it fills itself in until you disagree with it.
  const named = useRef(!!project);
  const isRepo = !!repoUrl.trim();
  const [paths, setPaths] = useState<Record<string, string>>(project?.paths ?? {});
  const [localPath, setLocalPath] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    void desktopBoot().then((info) => {
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
      };
      const saved = project
        ? await api.updateProject(project.id, body)
        : await api.createProject(body);

      if (localPath) {
        const info = await desktopBoot();
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
      <Field
        label="Repository URL"
        value={repoUrl}
        onChange={(value) => {
          setRepoUrl(value);
          if (!named.current) setName(nameFromRepo(value));
        }}
        autoFocus={!project}
        placeholder="https://github.com/acme/app"
      />
      <Field
        label="Name"
        value={name}
        onChange={(value) => {
          named.current = true;
          setName(value);
        }}
      />
      <Field label="What it is" value={description} onChange={setDescription} />
      {isRepo && <Field label="Default branch" value={branch} onChange={setBranch} />}

      {isRepo ? (
        <div className="notice">
          Every machine that runs a task here clones this for itself, into
          <code> ~/.patchwork/projects</code>. A private repository needs that
          machine to have access: an SSH URL uses its key, an https one uses
          <code> gh auth login</code> there.
        </div>
      ) : (
        <>
          <div className="notice">
            No repository, so this is a folder that already exists on a machine.
            Tasks work in the folder itself rather than in a worktree, which
            means one task at a time and no branch to review.
          </div>
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
          {otherHosts.map((host) => (
            <div className="form-row" key={host.id}>
              <label>On {host.name}</label>
              <input
                className="field"
                {...plainText}
                value={paths[host.id] ?? ""}
                placeholder="/absolute/path"
                onChange={(event) =>
                  setPaths({ ...paths, [host.id]: event.target.value })
                }
              />
            </div>
          ))}
        </>
      )}

      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- members ---------------------------------------------------------------

export function MembersPage() {
  const app = useApp();
  const api = useApi();
  const { toast } = useNavigation();
  const [inviting, setInviting] = useState(false);
  const [pairing, setPairing] = useState(false);
  const [removing, setRemoving] = useState<Member | null>(null);
  const humans = app.members.filter((member) => member.kind === "human");
  const iAmAdmin = app.me?.is_admin ?? false;

  return (
    <Page
      title="Members"
      subtitle={`${humans.length} ${humans.length === 1 ? "person" : "people"}`}
      actions={
        <>
          <button className="button quiet" onClick={() => setPairing(true)}>
            Pair phone or tablet
          </button>
          <button className="button" onClick={() => setInviting(true)}>
            <PlusIcon size={15} />
            Invite someone
          </button>
        </>
      }
    >
      {humans.map((member) => (
        <div className="row hoverable" key={member.id}>
          <Avatar member={member} size={30} presence />
          <span className="grow">
            <span className="name">
              {member.display_name}
              {member.id === app.me?.id && <span className="you"> you</span>}
            </span>
            <span className="sub">
              @{member.handle}
              {member.email ? ` · ${member.email}` : ""}
            </span>
          </span>
          {member.is_admin && <Chip>admin</Chip>}
          <Chip tone={member.presence === "online" ? "positive" : ""}>
            {member.presence}
          </Chip>
          {iAmAdmin && member.id !== app.me?.id && (
            <MenuButton
              align="right"
              title="Manage"
              items={[
                {
                  key: "admin",
                  label: member.is_admin ? "Remove admin" : "Make admin",
                  disabled: true,
                  hint: "Admin rights are set by the relay for now",
                  onSelect: () => {},
                },
                "separator",
                {
                  key: "remove",
                  label: `Remove ${member.display_name}`,
                  icon: <TrashIcon size={15} />,
                  danger: true,
                  onSelect: () => setRemoving(member),
                },
              ]}
            >
              <MoreIcon size={17} />
            </MenuButton>
          )}
        </div>
      ))}

      {!iAmAdmin && humans.length > 1 && (
        <div className="notice" style={{ marginTop: 18 }}>
          Only an admin can remove someone from this workspace.
        </div>
      )}

      {inviting && <InviteModal onClose={() => setInviting(false)} />}
      {pairing && <PairDeviceModal onClose={() => setPairing(false)} />}

      {removing && (
        <Modal
          title={`Remove ${removing.display_name}?`}
          subtitle="They lose access immediately. What they wrote stays in the transcript — removing a person does not rewrite history."
          onClose={() => setRemoving(null)}
          actions={
            <>
              <button className="button quiet" onClick={() => setRemoving(null)}>
                Cancel
              </button>
              <button
                className="button primary danger-solid"
                onClick={async () => {
                  try {
                    await api.removeMember(removing.id);
                    toast(`${removing.display_name} was removed`);
                  } catch (err) {
                    toast(String((err as Error).message ?? err));
                  }
                  setRemoving(null);
                }}
              >
                Remove
              </button>
            </>
          }
        >
          <div className="row hoverable" style={{ marginTop: 14 }}>
            <Avatar member={removing} size={30} />
            <span className="grow">
              <span className="name">{removing.display_name}</span>
              <span className="sub">@{removing.handle}</span>
            </span>
          </div>
        </Modal>
      )}
    </Page>
  );
}

/// One copyable invitation: the recipient should not have to ask which URL a
/// code belongs to or configure any networking before they can use it.
export function InviteModal({ onClose }: { onClose: () => void }) {
  const api = useApi();
  const relayUrl = api.baseUrl.replace(/\/w\/[^/]+\/?$/, "");
  const [code, setCode] = useState<string>();
  const [admin, setAdmin] = useState(false);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");

  const create = async () => {
    setError("");
    try {
      const created = await api.createInvite({ is_admin: admin });
      setCode(created.code);
      setCopied(false);
    } catch (err) {
      setError(String((err as Error).message ?? err));
    }
  };

  return (
    <Modal
      title={code ? "Invite code" : "Invite someone"}
      subtitle={
        code
          ? "Send both connection details. They can paste them into Patchwork Desktop."
          : "Create one invitation containing the relay URL and a one-use code."
      }
      onClose={onClose}
      actions={
        code ? (
          <button className="button primary" onClick={onClose}>
            Done
          </button>
        ) : (
          <>
            <button className="button quiet" onClick={onClose}>
              Cancel
            </button>
            <button className="button primary" onClick={create}>
              Create the code
            </button>
          </>
        )
      }
    >
      {code ? (
        <div className="invite-code">
          <code style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}>{`Relay URL: ${relayUrl}\nInvite code: ${code}`}</code>
          <button
            className="button quiet"
            onClick={() => {
              void navigator.clipboard.writeText(`Relay URL: ${relayUrl}\nInvite code: ${code}`);
              setCopied(true);
            }}
          >
            {copied ? <CheckIcon size={15} /> : null}
            {copied ? "Copied" : "Copy invitation"}
          </button>
        </div>
      ) : (
        <Toggle
          checked={admin}
          onChange={setAdmin}
          label="Join as an admin"
          help="Admins can remove members and delete tasks."
        />
      )}
      {error && <div className="error-text">{error}</div>}
    </Modal>
  );
}

// --- automations -----------------------------------------------------------

export function AutomationsPage() {
  const app = useApp();
  const api = useApi();
  const { go, toast } = useNavigation();
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<Automation | null>(null);
  const [deleting, setDeleting] = useState<Automation | null>(null);

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
              <MenuButton
                align="right"
                title="Manage"
                items={[
                  {
                    key: "edit",
                    label: "Edit…",
                    icon: <PencilIcon size={15} />,
                    onSelect: () => setEditing(automation),
                  },
                  {
                    key: "toggle",
                    label: automation.enabled ? "Pause" : "Resume",
                    onSelect: () =>
                      void api.updateAutomation(automation.id, {
                        ...automation,
                        enabled: !automation.enabled,
                      }),
                  },
                  "separator",
                  {
                    key: "delete",
                    label: "Delete automation",
                    icon: <TrashIcon size={15} />,
                    danger: true,
                    onSelect: () => setDeleting(automation),
                  },
                ]}
              >
                <MoreIcon size={17} />
              </MenuButton>
            </button>
          );
        })
      )}

      {(creating || editing) && (
        <AutomationModal
          automation={editing}
          onClose={() => {
            setCreating(false);
            setEditing(null);
          }}
        />
      )}
      {deleting && (
        <ConfirmDelete
          what={deleting.name}
          detail="It stops firing immediately. Runs it already made stay in the record."
          onCancel={() => setDeleting(null)}
          onConfirm={async () => {
            try {
              await api.deleteAutomation(deleting.id);
              toast(`“${deleting.name}” deleted`);
            } catch (err) {
              toast(String((err as Error).message ?? err));
            }
            setDeleting(null);
          }}
        />
      )}
    </Page>
  );
}

/// Deleting is the one action worth a second of friction, and the dialog should
/// say what is actually lost rather than asking "are you sure".
export function ConfirmDelete({
  what,
  detail,
  onCancel,
  onConfirm,
}: {
  what: string;
  detail: string;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return (
    <Modal
      title={`Delete “${what}”?`}
      subtitle={detail}
      onClose={onCancel}
      actions={
        <>
          <button className="button quiet" onClick={onCancel}>
            Cancel
          </button>
          <button className="button primary danger-solid" onClick={onConfirm}>
            Delete
          </button>
        </>
      }
    >
      <div />
    </Modal>
  );
}

function describeTrigger(automation: Automation) {
  const trigger = automation.trigger;
  switch (trigger.type) {
    case "schedule":
      return `every ${Math.round(trigger.every_seconds / 60)} min`;
    case "cron":
      return describeCron(trigger.expression);
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
    case "watch":
      return `scans every ${Math.round(trigger.every_seconds / 60)} min`;
    case "manual":
      return "manual only";
  }
}

/// One dialog for creating and for editing.
///
/// An automation is mostly its instructions — the paragraph telling the agent
/// what to do — and not being able to read that back, let alone fix a typo in
/// it, made every automation a black box you could only delete and recreate.
export function AutomationModal({
  automation,
  onClose,
}: {
  automation?: Automation | null;
  onClose: () => void;
}) {
  const app = useApp();
  const api = useApi();
  const { toast } = useNavigation();
  const editing = !!automation;

  const [name, setName] = useState(automation?.name ?? "");
  const [agentId, setAgentId] = useState(
    automation?.agent_id ??
      app.members.find((member) => member.kind === "agent")?.id ??
      "",
  );
  const [triggerKind, setTriggerKind] = useState(
    automation?.trigger.type === "cron" ? "cron" : (automation?.trigger.type ?? "cron"),
  );
  const initialCron =
    automation?.trigger.type === "cron" ? automation.trigger.expression : "0 9 * * *";
  const initial = presetFor(initialCron);
  const [preset, setPreset] = useState(initial.preset);
  const [time, setTime] = useState(initial.time);
  const [weekday, setWeekday] = useState(initial.weekday);
  const [expression, setExpression] = useState(initialCron);
  const [minutes, setMinutes] = useState(
    automation?.trigger.type === "schedule" || automation?.trigger.type === "watch"
      ? String(Math.round(automation.trigger.every_seconds / 60))
      : "60",
  );
  const [command, setCommand] = useState(
    automation?.trigger.type === "watch" ? automation.trigger.command : "",
  );
  const [channelId, setChannelId] = useState(
    automation?.context_channel_id ??
      app.channels.find((channel) => channel.kind === "channel")?.id ??
      "",
  );
  const [pattern, setPattern] = useState(
    automation?.trigger.type === "message" ? automation.trigger.pattern : "",
  );
  const [status, setStatus] = useState(
    automation?.trigger.type === "task_status" ? automation.trigger.status : "review",
  );
  const [action, setAction] = useState<string>(automation?.action ?? "post_in_chat");
  const [instructions, setInstructions] = useState(automation?.instructions ?? "");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const cronExpression =
    preset === "custom"
      ? expression
      : (PRESETS.find((entry) => entry.id === preset)?.cron(time, weekday) ??
        expression);

  const trigger = () => {
    switch (triggerKind) {
      case "cron":
        return { type: "cron", expression: cronExpression };
      case "schedule":
        return { type: "schedule", every_seconds: Number(minutes) * 60 };
      case "watch":
        return { type: "watch", command, every_seconds: Number(minutes) * 60 };
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
        return automation?.trigger.type === "webhook"
          ? automation.trigger
          : { type: "webhook", token: crypto.randomUUID() };
      default:
        return { type: "manual" };
    }
  };

  const save = async () => {
    setBusy(true);
    setError("");
    const body = {
      name,
      trigger: trigger(),
      agent_id: agentId,
      action,
      instructions,
      context_channel_id: channelId || undefined,
      report_channel_id: channelId || undefined,
      enabled: automation?.enabled ?? true,
    };
    try {
      if (automation) {
        await api.updateAutomation(automation.id, body);
        toast("Automation updated");
      } else {
        await api.createAutomation(body);
      }
      onClose();
    } catch (err) {
      setError(String((err as Error).message ?? err));
      setBusy(false);
    }
  };

  return (
    <Modal
      title={editing ? automation.name : "New automation"}
      subtitle="What fires it, which agent acts, and where the result lands."
      onClose={onClose}
      actions={
        <>
          <button className="button quiet" onClick={onClose}>
            Cancel
          </button>
          <button
            className="button primary"
            disabled={
              !name.trim() ||
              !agentId ||
              busy ||
              (triggerKind === "watch" && !command.trim())
            }
            onClick={save}
          >
            {editing ? "Save" : "Create"}
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
          { value: "cron", label: "On a schedule", hint: "at a time of day" },
          {
            value: "schedule",
            label: "At an interval",
            hint: "every N minutes, from the last run",
          },
          {
            value: "watch",
            label: "When a script finds something",
            hint: "polls a command, fires only on new output",
          },
          { value: "message", label: "On a new message" },
          { value: "task_status", label: "When a task changes status" },
          { value: "task_assigned", label: "When a task is assigned to it" },
          { value: "pull_request", label: "On pull request activity" },
          { value: "webhook", label: "On an incoming webhook" },
          { value: "manual", label: "Only when run manually" },
        ]}
      />

      {triggerKind === "cron" && (
        <>
          <FormSelect
            label="How often"
            value={preset}
            onChange={setPreset}
            options={[
              ...PRESETS.map((entry) => ({ value: entry.id, label: entry.label })),
              { value: "custom", label: "Custom cron" },
            ]}
          />
          {preset !== "custom" && PRESETS.find((e) => e.id === preset)?.needsTime && (
            <div className="form-row">
              <label>At</label>
              <input
                className="field"
                type="time"
                value={time}
                onChange={(event) => setTime(event.target.value)}
              />
            </div>
          )}
          {preset === "weekly" && (
            <FormSelect
              label="On"
              value={String(weekday)}
              onChange={(value) => setWeekday(Number(value))}
              options={WEEKDAYS.map((day, index) => ({
                value: String(index),
                label: day,
              }))}
            />
          )}
          {preset === "custom" && (
            <Field
              label="Cron expression"
              value={expression}
              onChange={setExpression}
              placeholder="0 9 * * 1-5"
            />
          )}
          <div className="form-help">
            Runs {describeCron(cronExpression)}, in the relay's local time.
          </div>
        </>
      )}
      {triggerKind === "schedule" && (
        <Field label="Every (minutes)" value={minutes} onChange={setMinutes} />
      )}
      {triggerKind === "watch" && (
        <>
          <Field
            label="Command"
            value={command}
            onChange={setCommand}
            placeholder="curl -s https://api.example.com/issues/new | jq -r '.[].title'"
          />
          <Field label="Check every (minutes)" value={minutes} onChange={setMinutes} />
          <div className="form-help">
            Runs on the relay. The agent only wakes when the command prints
            something it did not print last time, so checking often is cheap.
            <code>$PATCHWORK_STATE_DIR</code> is a directory of its own, kept
            between runs.
          </div>
        </>
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
          onChange={(value) => setStatus(value as typeof status)}
          options={TASK_STATUSES.map((value) => ({
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

export function AutomationDebugPage({ automationId }: { automationId: string }) {
  const api = useApi();
  const app = useApp();
  const { inspect, go, toast } = useNavigation();
  const [debug, setDebug] = useState<AutomationDebug>();
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);

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
          <button className="button" onClick={() => api.runAutomation(automation.id)}>
            Run now
          </button>
          <button className="button" onClick={() => setEditing(true)}>
            <PencilIcon size={15} />
            Edit
          </button>
          <MenuButton
            align="right"
            title="More"
            items={[
              {
                key: "delete",
                label: "Delete automation",
                icon: <TrashIcon size={15} />,
                danger: true,
                onSelect: () => setDeleting(true),
              },
            ]}
          >
            <MoreIcon size={17} />
          </MenuButton>
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
          <div className="form-help">
            Add <code>?once=your-key</code> so a redelivery of the same event
            does not act twice.
          </div>
        </div>
      )}

      {automation.trigger.type === "watch" && (
        <div className="card" style={{ maxWidth: "none", marginTop: 14 }}>
          <div className="card-head">Scan</div>
          <code style={{ wordBreak: "break-all" }}>{automation.trigger.command}</code>
        </div>
      )}

      {/* The instructions are the automation. Hiding them made every one of
          these a black box you could only delete and recreate. */}
      <Section
        title="Instructions"
        action={
          <button className="button quiet" onClick={() => setEditing(true)}>
            Edit
          </button>
        }
      >
        {automation.instructions.trim() ? (
          <div className="instructions">{automation.instructions}</div>
        ) : (
          <div className="notice">
            No instructions — the agent only gets the trigger and the channel.
          </div>
        )}
      </Section>

      <Section title="Runs">
        {debug.runs.length === 0 ? (
          <Empty
            title="This automation has not fired yet"
            hint="Every firing records its trigger, what it selected, and the context the agent received."
          />
        ) : (
          debug.runs.map((run) => (
            <AutomationRunRow
              key={run.id}
              run={run}
              onOpenRun={(runId) => inspect({ kind: "run", runId })}
              onOpenTask={(taskId) => go({ kind: "task", id: taskId })}
            />
          ))
        )}
      </Section>

      {editing && (
        <AutomationModal
          automation={automation}
          onClose={() => {
            setEditing(false);
            void api.automationDebug(automationId).then(setDebug);
          }}
        />
      )}
      {deleting && (
        <ConfirmDelete
          what={automation.name}
          detail="It stops firing immediately. Runs it already made stay in the record."
          onCancel={() => setDeleting(false)}
          onConfirm={async () => {
            try {
              await api.deleteAutomation(automation.id);
              toast(`“${automation.name}” deleted`);
              go({ kind: "automations" });
            } catch (err) {
              toast(String((err as Error).message ?? err));
            }
            setDeleting(false);
          }}
        />
      )}
    </Page>
  );
}

// --- settings --------------------------------------------------------------

export function SettingsPage({ onSignOut }: { onSignOut: () => void }) {
  const app = useApp();
  const api = useApi();
  const workspaces = useWorkspaces();
  const { toast } = useNavigation();
  const iconInput = useRef<HTMLInputElement>(null);
  const [info, setInfo] = useState<DesktopInfo>();
  const [name, setName] = useState(app.workspace?.name ?? "");
  const [icon, setIcon] = useState(app.workspace?.icon ?? "");
  const [prefix, setPrefix] = useState(app.workspace?.task_prefix ?? "PW");
  const [iconUploading, setIconUploading] = useState(false);
  const [saved, setSaved] = useState(false);
  const [awakePolicy, setAwake] = useState<AwakePolicy>("never");
  const [updateStatus, setUpdateStatus] = useState("");

  useEffect(() => {
    setName(app.workspace?.name ?? "");
    setIcon(app.workspace?.icon ?? "");
    setPrefix(app.workspace?.task_prefix ?? "PW");
  }, [
    app.workspace?.id,
    app.workspace?.name,
    app.workspace?.icon,
    app.workspace?.task_prefix,
  ]);

  const checkForUpdate = async () => {
    setUpdateStatus("Checking…");
    try {
      const { check } = await import("@tauri-apps/plugin-updater");
      const update = await check();
      if (!update) {
        setUpdateStatus("Patchwork is up to date");
        return;
      }
      setUpdateStatus(`Installing ${update.version}…`);
      await update.downloadAndInstall();
      const { relaunch } = await import("@tauri-apps/plugin-process");
      await relaunch();
    } catch (err) {
      setUpdateStatus(String((err as Error).message ?? err));
    }
  };

  const hostSignature = useHostSignature(app.hosts);
  useEffect(() => {
    void desktopInfo().then((loaded) => {
      setInfo(loaded);
      setAwake(loaded.settings.awake ?? "never");
    });
  }, [hostSignature]);

  const relayUrl =
    info?.settings.workspaces.find(
      (workspace) => workspace.id === app.workspace?.id,
    )?.relay_url ?? "";
  const currentWorkspace = workspaces.find((workspace) => workspace.active);
  const iconChanged = icon !== (app.workspace?.icon ?? "");
  const managedRelay = relayUrl.startsWith("https://relay.patchwork.sh/r/");

  // The relay knows about every host. This machine also knows things the relay
  // has not been told yet — its own capabilities before it has registered — so
  // the two are merged, with the local view winning for the local machine.
  const machines = distinctMachines(app.hosts).map((machine) => {
    // "This machine" is about the box, not about which of its hosts you happen
    // to be looking at: the same laptop can be both the relay and a desktop.
    const isThis =
      !!info &&
      (machine.hostIds.includes(info.host.host_id) ||
        (!!info.capabilities.machine_key &&
          machine.host.capabilities.machine_key === info.capabilities.machine_key));
    const capabilities = isThis ? info.capabilities : machine.host.capabilities;
    return {
      id: machine.host.id,
      name: machine.name,
      role: machine.isRelay && machine.isDesktop
        ? "relay and desktop"
        : machine.isRelay
          ? "relay"
          : "desktop",
      isThis,
      platform: isThis ? info.platform : machine.host.platform,
      online: isThis ? info.host.connected : machine.host.online,
      lastSeen: machine.host.last_seen,
      error: isThis ? info.host.last_error : undefined,
      hasGh: capabilities.has_gh,
      ghAuthed: capabilities.gh_authenticated,
      runtimes: capabilities.runtimes.filter((runtime) => runtime.id !== "custom"),
    };
  });

  // Not yet registered with the relay: still worth showing, or the user is
  // staring at a list that does not contain the machine they are sitting at.
  if (info && !machines.some((machine) => machine.isThis)) {
    machines.unshift({
      id: info.host.host_id || "local",
      name: info.host.host_name || "This machine",
      role: "desktop",
      isThis: true,
      platform: info.platform,
      online: info.host.connected,
      lastSeen: Date.now(),
      error: info.host.last_error,
      hasGh: info.capabilities.has_gh,
      ghAuthed: info.capabilities.gh_authenticated,
      runtimes: info.capabilities.runtimes.filter(
        (runtime) => runtime.id !== "custom",
      ),
    });
  }

  return (
    <Page title="Settings">
      <Section title="Workspace">
        <div className="workspace-icon-editor">
          <WorkspaceMark
            name={app.workspace?.name ?? "Workspace"}
            icon={app.workspace?.icon}
            image={currentWorkspace?.iconImage}
            size={42}
          />
          <button
            className="button quiet"
            disabled={iconUploading}
            onClick={() => iconInput.current?.click()}
          >
            {iconUploading ? "Uploading…" : "Upload PNG or JPEG"}
          </button>
          {app.workspace?.icon_image && (
            <button
              className="button quiet danger"
              onClick={() => void api.updateWorkspace({ icon: "" })}
            >
              Remove image
            </button>
          )}
          <input
            ref={iconInput}
            type="file"
            hidden
            accept="image/png,image/jpeg,.png,.jpg,.jpeg"
            onChange={async (event) => {
              const file = event.currentTarget.files?.[0];
              event.currentTarget.value = "";
              if (!file) return;
              setIconUploading(true);
              try {
                const uploaded = await api.upload(file);
                await api.updateWorkspace({ icon_file_id: uploaded.id });
                setIcon("");
              } catch (err) {
                toast(String((err as Error).message ?? err));
              } finally {
                setIconUploading(false);
              }
            }}
          />
        </div>
        <Field label="Name" value={name} onChange={setName} />
        <Field
          label="Emoji"
          value={icon}
          onChange={(value) => setIcon([...value].slice(0, 8).join(""))}
          placeholder="🚀"
        />
        <Field
          label="Task prefix"
          value={prefix}
          onChange={(value) => setPrefix(value.toUpperCase().slice(0, 6))}
          placeholder="PW"
        />
        <span className="form-help">
          The next task will be {prefix.trim() || "PW"}-
          {(app.workspace?.task_seq ?? 0) + 1}. Keys already handed out keep
          the prefix they were made with.
        </span>
        <button
          className="button"
          style={{ marginTop: 10 }}
          disabled={
            (!name.trim() || name === app.workspace?.name) &&
            !iconChanged &&
            (!prefix.trim() || prefix === app.workspace?.task_prefix)
          }
          onClick={async () => {
            await api.updateWorkspace({
              name: name.trim() || undefined,
              icon: iconChanged ? icon.trim() : undefined,
              task_prefix: prefix.trim() || undefined,
            });
            setSaved(true);
            window.setTimeout(() => setSaved(false), 1800);
          }}
        >
          {saved ? <CheckIcon size={15} /> : null}
          {saved ? "Saved" : "Save"}
        </button>
      </Section>

      {/* Every machine, not just this one. An agent installed on the relay is
          the whole point of running a relay, and it used to be invisible here
          because this section only ever asked the local host what it had. */}
      <Section
        title="Machines and runtimes"
        action={
          <span className="section-note">
            An agent can run anywhere its runtime is installed
          </span>
        }
      >
        {machines.length === 0 && (
          <div className="notice">No machine has reported in yet.</div>
        )}
        {machines.map((machine) => (
          <div className="machine" key={machine.id}>
            <div className="machine-head">
              <span className={`dot ${machine.online ? "online" : ""}`} />
              <span className="grow">
                <span className="name">
                  {machine.name}
                  {machine.isThis && <span className="you"> this machine</span>}
                </span>
                <span className="sub">
                  {machine.platform} · {machine.role}
                  {machine.online ? "" : ` · seen ${relative(machine.lastSeen)}`}
                  {machine.error ? ` · ${machine.error}` : ""}
                </span>
              </span>
              {machine.hasGh && (
                <Chip tone={machine.ghAuthed ? "positive" : "caution"}>gh</Chip>
              )}
            </div>
            {machine.runtimes.length === 0 ? (
              <div className="machine-runtime empty">
                No agent runtimes detected here
              </div>
            ) : (
              machine.runtimes.map((runtime) => (
                <div className="machine-runtime" key={runtime.id}>
                  <RuntimeIcon runtime={runtime.id} />
                  <span className="grow">
                    <span className="name">{runtime.label}</span>
                    <span className="sub">
                      {runtime.problem ??
                        runtime.version ??
                        runtime.command.join(" ")}
                    </span>
                  </span>
                  <Chip tone={runtime.available ? "positive" : "caution"}>
                    {runtime.available ? "ready" : "unavailable"}
                  </Chip>
                </div>
              ))
            )}

            {/* Only this machine, because only this machine's sleep is ours to
                prevent. An agent working here dies when the lid closes. */}
            {machine.isThis && (
              <div className="machine-runtime">
                <span className="grow">
                  <span className="name">Keep awake</span>
                  <span className="sub">
                    Stops this machine sleeping and killing a run part-way
                  </span>
                </span>
                <Dropdown
                  align="right"
                  width={210}
                  value={awakePolicy}
                  onChange={(value) => {
                    const policy = value as AwakePolicy;
                    setAwake(policy);
                    void setAwakePolicy(policy);
                  }}
                  options={[
                    { value: "never", label: "Never" },
                    {
                      value: "while_running",
                      label: "While an agent is running",
                      hint: "recommended",
                    },
                    { value: "while_open", label: "While Patchwork is open" },
                  ]}
                />
              </div>
            )}
          </div>
        ))}
      </Section>

      {/* Only inside the app: a browser tab has no machine to keep a key on. */}
      {inTauri && <ProviderSection />}

      {/* Every workspace this machine has joined stays connected, whichever
          one the window is showing: an agent working in one of them does not
          care what you are looking at. */}
      <Section
        title="Workspaces"
        action={
          <span className="section-note">All connected, all working</span>
        }
      >
        {(info?.settings.workspaces ?? []).map((workspace) => {
          const here = workspace.id === app.workspace?.id;
          const live = workspaces.find((joined) => joined.id === workspace.id);
          return (
            <div className="row hoverable" key={workspace.id}>
              <WorkspaceMark
                name={live?.name ?? workspace.name}
                icon={live?.icon}
                image={live?.iconImage}
                size={28}
              />
              <span className="grow">
                <span className="name">
                  {live?.name ?? workspace.name}
                  {here && <span className="you"> showing</span>}
                </span>
                <span className="sub">
                  {workspace.relay_url} · {workspace.member_name}
                </span>
              </span>
              {!here && (
                <button
                  className="button quiet"
                  onClick={() => void switchTo(workspace.id)}
                >
                  Switch
                </button>
              )}
              <button
                className="button quiet danger"
                onClick={async () => {
                  await leave(workspace.id);
                  setInfo(await desktopInfo());
                }}
              >
                Leave
              </button>
            </div>
          );
        })}
      </Section>

      <Section title="Relay">
        <div className="row hoverable">
          <span className={`dot ${app.live ? "online" : "waiting"}`} />
          <span className="grow">
            <span className="name">{relayUrl}</span>
            <span className="sub">
              {info?.hosting_relay
                ? `${managedRelay ? "shared securely through Patchwork Relay" : "served by this machine"} · ${app.live ? "connected" : "reconnecting…"}`
                : app.live
                  ? "connected"
                  : "reconnecting…"}
            </span>
          </span>
          <button
            className="button quiet"
            onClick={() => openExternal(`${relayUrl}/api/health`)}
          >
            <ExternalIcon size={14} />
            Health
          </button>
        </div>
      </Section>

      {inTauri && (
        <Section title="Updates">
          <div className="row">
            <span className="grow">
              <span className="name">Patchwork Desktop</span>
              <span className="sub">
                {updateStatus || "Signed updates from GitHub Releases"}
              </span>
            </span>
            <button
              className="button"
              disabled={updateStatus === "Checking…" || updateStatus.startsWith("Installing ")}
              onClick={() => void checkForUpdate()}
            >
              Check for updates
            </button>
          </div>
        </Section>
      )}

      <Section title="Account">
        <button
          className="button quiet danger"
          onClick={async () => {
            await signOutOfEverything();
            onSignOut();
          }}
        >
          Sign out of every workspace
        </button>
      </Section>
    </Page>
  );
}

/// `https://github.com/acme/app.git` is called `app`.
function nameFromRepo(url: string) {
  const tail = url
    .trim()
    .replace(/\.git$/, "")
    .replace(/\/+$/, "")
    .split(/[/:]/)
    .filter(Boolean)
    .pop();
  return tail ?? "";
}

/// One firing, one line: when, what set it off, how it went. A firing is
/// something you scan a hundred of looking for the one that failed, so the
/// evidence behind it opens on demand rather than standing open forever.
function AutomationRunRow({
  run,
  onOpenRun,
  onOpenTask,
}: {
  run: AutomationRun;
  onOpenRun: (runId: Id) => void;
  onOpenTask: (taskId: Id) => void;
}) {
  const [open, setOpen] = useState(false);
  const hasDetail = run.selection != null || !!run.context_preview;

  return (
    <div className={`run-row${open ? " open" : ""}`}>
      <button
        className="run-row-head"
        onClick={() => hasDetail && setOpen(!open)}
        title={hasDetail ? "What it selected and the context it received" : undefined}
      >
        {run.status === "running" ? (
          <Spinner size={12} />
        ) : (
          <span className={`dot ${statusTone(run.status)}`} />
        )}
        <span className="when">{relative(run.created_at)}</span>
        <span className="grow summary">{run.error || run.trigger_summary}</span>
        {run.run_id && (
          <span
            className="run-row-link"
            role="button"
            onClick={(event) => {
              event.stopPropagation();
              onOpenRun(run.run_id!);
            }}
          >
            Log
          </span>
        )}
        {run.task_id && (
          <span
            className="run-row-link"
            role="button"
            onClick={(event) => {
              event.stopPropagation();
              onOpenTask(run.task_id!);
            }}
          >
            Task
          </span>
        )}
        <Chip tone={run.error ? "danger" : statusTone(run.status)}>
          {statusLabel(run.status)}
        </Chip>
      </button>
      {open && (
        <div className="run-row-detail">
          {run.selection != null && (
            <pre className="code-block">{JSON.stringify(run.selection, null, 2)}</pre>
          )}
          {run.context_preview && (
            <pre className="code-block">{run.context_preview}</pre>
          )}
        </div>
      )}
    </div>
  );
}

/// What the built-in Patchwork agent thinks with. Nothing here is workspace
/// state: a key is typed on one machine, kept there, and comes back redacted,
/// so this is the one settings section that describes only the box you are
/// sitting at.
function ProviderSection() {
  const { value: state, setValue } = useAsync(
    async () => ({
      list: await providerCatalog(),
      keys: (await desktopBoot()).settings.provider_keys,
    }),
    [],
  );
  if (!state?.list.length) return null;

  return (
    <Section
      title="Patchwork agent providers"
      action={
        <span className="section-note">
          Keys stay on this machine and are never sent to the relay
        </span>
      }
    >
      {state.list.map((provider) => (
        <div className="row" key={provider.id}>
          <span className="grow">
            <span className="name">{provider.label}</span>
            <span className="sub">{provider.hint}</span>
          </span>
          <ProviderKeyControls
            provider={provider}
            stored={!!state.keys[provider.id]}
            onChanged={(keys) => setValue({ list: state.list, keys })}
          />
        </div>
      ))}
    </Section>
  );
}
