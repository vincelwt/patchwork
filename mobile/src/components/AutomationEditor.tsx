import { useState } from "react";
import { ScrollView, StyleSheet } from "react-native";
import * as Crypto from "expo-crypto";

import type {
  Automation,
  AutomationAction,
  AutomationTrigger,
  ExecutionLocation,
  TaskStatus,
} from "@client/types";
import { TASK_STATUSES } from "@client/types";
import { watchNeedsTest } from "@/lib/format";
import { useWorkspace, useWorkspaceStore } from "@/lib/store";
import { Button, ChoiceField, ErrorNotice, TextField, ToggleRow } from "./ui";

export function AutomationEditor({ automation, onSaved }: { automation?: Automation; onSaved: (automation: Automation) => void }) {
  const workspace = useWorkspace();
  const store = useWorkspaceStore();
  const data = workspace.bootstrap;
  const [name, setName] = useState(automation?.name ?? "");
  const [description, setDescription] = useState(automation?.description ?? "");
  const [agentId, setAgentId] = useState(automation?.agent_id ?? data?.members.find((member) => member.kind === "agent")?.id ?? "");
  const [triggerType, setTriggerType] = useState<AutomationTrigger["type"]>(automation?.trigger.type ?? "cron");
  const [cron, setCron] = useState(automation?.trigger.type === "cron" ? automation.trigger.expression : "0 9 * * 1-5");
  const [minutes, setMinutes] = useState(
    automation?.trigger.type === "schedule" || automation?.trigger.type === "watch"
      ? String(Math.max(1, Math.round(automation.trigger.every_seconds / 60)))
      : "60",
  );
  const [command, setCommand] = useState(automation?.trigger.type === "watch" ? automation.trigger.command : "");
  const [pattern, setPattern] = useState(automation?.trigger.type === "message" ? automation.trigger.pattern : "");
  const [includeAgents, setIncludeAgents] = useState(automation?.trigger.type === "message" ? automation.trigger.include_agents : false);
  const [taskStatus, setTaskStatus] = useState<TaskStatus>(automation?.trigger.type === "task_status" ? automation.trigger.status : "review");
  const [reviewComment, setReviewComment] = useState(automation?.trigger.type === "pull_request" ? automation.trigger.on_review_comment : true);
  const [checksFailed, setChecksFailed] = useState(automation?.trigger.type === "pull_request" ? automation.trigger.on_checks_failed : true);
  const [channelId, setChannelId] = useState(
    automation?.trigger.type === "message"
      ? automation.trigger.channel_id
      : automation?.context_channel_id ?? data?.channels.find((channel) => channel.kind === "channel")?.id ?? "",
  );
  const [reportChannelId, setReportChannelId] = useState(automation?.report_channel_id ?? channelId);
  const [projectId, setProjectId] = useState(automation?.project_id ?? "");
  const [action, setAction] = useState<AutomationAction>(automation?.action ?? "post_in_chat");
  const [instructions, setInstructions] = useState(automation?.instructions ?? "");
  const [location, setLocation] = useState<ExecutionLocation>(automation?.location ?? "auto");
  const [hostId, setHostId] = useState(automation?.host_id ?? "");
  const [enabled, setEnabled] = useState(automation?.enabled ?? true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  /// A watch is saved paused, tested, then enabled, so a failed test leaves an
  /// automation behind. Saving again fixes that one rather than making a second.
  const [savedId, setSavedId] = useState(automation?.id);
  if (!data) return null;

  const trigger = (): AutomationTrigger => {
    switch (triggerType) {
      case "schedule":
        return { type: "schedule", every_seconds: Math.max(60, Number(minutes || 1) * 60) };
      case "cron":
        return { type: "cron", expression: cron.trim() };
      case "message":
        return { type: "message", channel_id: channelId, pattern: pattern.trim(), include_agents: includeAgents };
      case "task_status":
        // A listener scoped to one task keeps its task when edited here.
        return { type: "task_status", status: taskStatus, project_id: projectId || undefined, task_id: automation?.trigger.type === "task_status" ? automation.trigger.task_id : undefined };
      case "task_assigned":
        return { type: "task_assigned" };
      case "pull_request":
        return { type: "pull_request", on_review_comment: reviewComment, on_checks_failed: checksFailed };
      case "webhook":
        return automation?.trigger.type === "webhook" ? automation.trigger : { type: "webhook", token: Crypto.randomUUID() };
      case "watch":
        return { type: "watch", command: command.trim(), every_seconds: Math.max(60, Number(minutes || 1) * 60) };
      case "manual":
        return { type: "manual" };
    }
  };

  const save = async () => {
    setBusy(true);
    setError("");
    const nextTrigger = trigger();
    // The relay refuses to enable a watch whose command has not passed a test,
    // and an untested watch that looks enabled is the failure this guards: save
    // it paused, test it, and only then put it back on.
    const needsTest = watchNeedsTest(automation, nextTrigger);
    const body = {
      name: name.trim(),
      description: description.trim(),
      trigger: nextTrigger,
      agent_id: agentId,
      action,
      instructions: instructions.trim(),
      context_channel_id: channelId || undefined,
      report_channel_id: reportChannelId || undefined,
      project_id: projectId || undefined,
      location,
      host_id: location === "desktop" ? hostId || undefined : undefined,
      enabled: enabled && !needsTest,
    };
    let created: string | undefined;
    try {
      await store.mutate(
        async (api) => {
          const saved = savedId
            ? await api.updateAutomation(savedId, body)
            : await api.createAutomation(body);
          created = saved.id;
          if (!needsTest) return { automation: saved, test: undefined };
          const test = await api.testAutomation(saved.id);
          // A watch the author deliberately paused stays paused.
          const enabledNow = test.ok && enabled
            ? await api.updateAutomation(saved.id, { ...body, enabled: true })
            : saved;
          return { automation: enabledNow, test };
        },
        true,
        ({ automation: saved, test }) => {
          if (test && !test.ok) {
            setError(`The command failed, so it stays paused: ${test.error ?? "no diagnostic"}`);
            return;
          }
          onSaved(saved);
        },
      );
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      if (created) setSavedId(created);
      setBusy(false);
    }
  };

  // A report can land in a direct message as easily as in a channel — the daily
  // sweep does exactly that — so both are offered here.
  const channelOptions = [
    { value: "", label: "None" },
    ...data.channels
      .filter((channel) => channel.kind === "channel" || channel.kind === "dm")
      .map((channel) => ({ value: channel.id, label: channel.kind === "dm" ? `DM · ${channel.name}` : `# ${channel.name}` })),
  ];

  return (
    <ScrollView contentContainerStyle={styles.form} keyboardShouldPersistTaps="handled">
      <TextField label="Name" value={name} onChangeText={setName} />
      <TextField label="Description" value={description} onChangeText={setDescription} multiline />
      <ChoiceField label="Agent" value={agentId} options={data.members.filter((member) => member.kind === "agent").map((member) => ({ value: member.id, label: member.display_name, description: member.agent?.runtime }))} onChange={setAgentId} />
      <ChoiceField
        label="Trigger"
        value={triggerType}
        options={[
          { value: "cron", label: "On a schedule" },
          { value: "schedule", label: "At an interval" },
          { value: "watch", label: "When a script finds something" },
          { value: "message", label: "On a new message" },
          { value: "task_status", label: "When a task changes status" },
          { value: "task_assigned", label: "When a task is assigned" },
          { value: "pull_request", label: "On pull request activity" },
          { value: "webhook", label: "On an incoming webhook" },
          { value: "manual", label: "Manual only" },
        ]}
        onChange={(value) => setTriggerType(value as AutomationTrigger["type"])}
      />
      {triggerType === "cron" ? <TextField label="Cron expression" value={cron} onChangeText={setCron} placeholder="0 9 * * 1-5" autoCapitalize="none" /> : null}
      {triggerType === "schedule" || triggerType === "watch" ? <TextField label="Every (minutes)" value={minutes} onChangeText={setMinutes} keyboardType="number-pad" /> : null}
      {triggerType === "watch" ? <TextField label="Command" value={command} onChangeText={setCommand} multiline autoCapitalize="none" help="Exit 0 with empty output is a healthy no-op. Findings must be one JSON event per line. Saving tests the command without firing the action." /> : null}
      {triggerType === "message" ? (
        <>
          <ChoiceField label="Watch channel" value={channelId} options={channelOptions.slice(1)} onChange={setChannelId} />
          <TextField label="Only matching" value={pattern} onChangeText={setPattern} placeholder="Optional pattern" />
          <ToggleRow label="Include agent messages" value={includeAgents} onChange={setIncludeAgents} />
        </>
      ) : null}
      {triggerType === "task_status" ? <ChoiceField label="Status" value={taskStatus} options={TASK_STATUSES.map((status) => ({ value: status, label: status[0].toUpperCase() + status.slice(1) }))} onChange={(value) => setTaskStatus(value as TaskStatus)} /> : null}
      {triggerType === "pull_request" ? (
        <>
          <ToggleRow label="Review comments" value={reviewComment} onChange={setReviewComment} />
          <ToggleRow label="Failed checks" value={checksFailed} onChange={setChecksFailed} />
        </>
      ) : null}
      <ChoiceField label="Context channel" value={channelId} options={channelOptions} onChange={setChannelId} />
      <ChoiceField label="Report channel" value={reportChannelId} options={channelOptions} onChange={setReportChannelId} />
      <ChoiceField label="Project" value={projectId} options={[{ value: "", label: "No project" }, ...data.projects.map((project) => ({ value: project.id, label: project.name }))]} onChange={setProjectId} />
      <ChoiceField label="Action" value={action} options={[{ value: "post_in_chat", label: "Post in chat" }, { value: "create_task", label: "Create and work on a task" }, { value: "continue_task", label: "Continue the triggering task" }]} onChange={(value) => setAction(value as AutomationAction)} />
      <TextField label="Instructions" value={instructions} onChangeText={setInstructions} multiline placeholder="What should the agent do?" />
      <ChoiceField label="Run on" value={location} options={[{ value: "auto", label: "Wherever available" }, { value: "relay", label: "Relay" }, { value: "desktop", label: "Desktop" }]} onChange={(value) => setLocation(value as ExecutionLocation)} />
      {location === "desktop" ? <ChoiceField label="Desktop host" value={hostId} options={data.hosts.filter((host) => host.kind === "desktop").map((host) => ({ value: host.id, label: host.name, description: host.online ? "Online" : "Offline" }))} onChange={setHostId} /> : null}
      <ToggleRow label="Enabled" value={enabled} onChange={setEnabled} />
      <ErrorNotice message={error} />
      <Button label={automation ? "Save automation" : "Create automation"} busy={busy} disabled={!name.trim() || !agentId || (triggerType === "watch" && !command.trim())} onPress={() => void save()} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  form: { padding: 16, gap: 15, paddingBottom: 36 },
});
