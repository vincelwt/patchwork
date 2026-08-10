import { useMemo, useState } from "react";
import { ScrollView, StyleSheet } from "react-native";

import type { AgentProfile, Member, Participation } from "@client/types";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { Button, ChoiceField, ErrorNotice, TextField, ToggleRow } from "./ui";

export function AgentEditor({ agent, onSaved }: { agent?: Member; onSaved: (agent: Member) => void }) {
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
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
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const runtimes = useMemo(() => {
    const labels = new Map<string, string>();
    for (const host of data?.hosts ?? []) {
      for (const runtime of host.capabilities.runtimes) {
        if (runtime.available && runtime.id !== "custom") labels.set(runtime.id, runtime.label);
      }
    }
    if (!labels.size) labels.set("codex", "Codex");
    return [...labels].map(([value, label]) => ({ value, label }));
  }, [data?.hosts]);
  if (!data) return null;

  const save = async () => {
    setBusy(true);
    setError("");
    try {
      await store.mutate(
        (api) => agent
          ? api.updateAgent(agent.id, { display_name: name.trim(), profile })
          : api.createAgent({ display_name: name.trim(), profile }),
        true,
        onSaved,
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView contentContainerStyle={styles.form} keyboardShouldPersistTaps="handled">
      <TextField label="Name" value={name} onChangeText={setName} />
      <TextField label="What this agent owns" value={profile.description} onChangeText={(value) => setProfile({ ...profile, description: value })} multiline />
      <ChoiceField label="Runtime" value={profile.runtime} options={runtimes} onChange={(runtime) => setProfile({ ...profile, runtime })} />
      <ChoiceField
        label="Where it runs"
        value={profile.location}
        options={[
          { value: "auto", label: "Wherever the project is", description: "Prefer an available relay or connected desktop." },
          { value: "relay", label: "Relay", description: "Keeps working without a connected computer." },
          { value: "desktop", label: "A desktop", description: "Use one connected desktop host." },
        ]}
        onChange={(location) => setProfile({ ...profile, location: location as AgentProfile["location"], host_id: location === "desktop" ? profile.host_id : undefined })}
      />
      {profile.location === "desktop" ? (
        <ChoiceField
          label="Desktop host"
          value={profile.host_id}
          options={data.hosts.filter((host) => host.kind === "desktop").map((host) => ({ value: host.id, label: host.name, description: host.online ? "Online" : "Offline" }))}
          onChange={(host_id) => setProfile({ ...profile, host_id })}
        />
      ) : null}
      <TextField label="Model override" value={profile.model ?? ""} onChangeText={(model) => setProfile({ ...profile, model: model || undefined })} help="Leave blank to use the selected machine's default." autoCapitalize="none" />
      <ChoiceField
        label="Default participation"
        value={profile.default_participation}
        options={[
          { value: "off", label: "Off" },
          { value: "mention", label: "When mentioned" },
          { value: "ambient", label: "Ambient" },
        ]}
        onChange={(value) => setProfile({ ...profile, default_participation: value as Participation })}
      />
      <ChoiceField
        label="Default project"
        value={profile.default_project_id}
        options={[{ value: "", label: "None" }, ...data.projects.map((project) => ({ value: project.id, label: project.name }))]}
        onChange={(default_project_id) => setProfile({ ...profile, default_project_id: default_project_id || undefined })}
      />
      <ToggleRow label="Allow direct messages" detail="A direct message can start or continue this agent." value={profile.dm_enabled} onChange={(dm_enabled) => setProfile({ ...profile, dm_enabled })} />
      <ErrorNotice message={error} />
      <Button label={agent ? "Save agent" : "Create agent"} busy={busy} disabled={!name.trim() || !profile.runtime} onPress={() => void save()} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  form: { padding: 16, gap: 15, paddingBottom: 36 },
});
