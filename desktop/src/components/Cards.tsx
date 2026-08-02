import { useEffect, useState } from "react";
import { useApi, useApp, store } from "../lib/store";
import { bytes, duration, statusLabel, statusTone } from "../lib/format";
import { openExternal } from "../lib/desktop";
import { Chip, useNavigation } from "./common";
import {
  ExternalIcon,
  PreviewIcon,
  QuestionIcon,
  RunIcon,
  Spinner,
  TasksIcon,
} from "./icons";
import type { MessageCard, QuestionAnswer } from "../lib/types";

/// Cards are how tasks, runs, questions, artifacts, previews and pull requests
/// appear inline in a conversation — the same objects the rest of the app
/// navigates to, not copies of them.
export function Card({ card }: { card: MessageCard }) {
  switch (card.type) {
    case "task":
      return <TaskCardInline taskId={card.task_id} />;
    case "run":
      return <RunCardInline runId={card.run_id} />;
    case "question":
      return <QuestionCard questionId={card.question_id} />;
    case "artifact":
      return <ArtifactCard attachmentId={card.attachment_id} caption={card.caption} />;
    case "preview":
      return <PreviewCard previewId={card.preview_id} />;
    case "pull_request":
      return <PullRequestCard url={card.url} taskId={card.task_id} />;
  }
}

function TaskCardInline({ taskId }: { taskId: string }) {
  const app = useApp();
  const { go } = useNavigation();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  if (!task) return null;
  const owner = app.members.find((member) => member.id === task.owner_id);

  return (
    <button className="card" onClick={() => go({ kind: "task", id: task.id })}>
      <div className="card-head">
        <TasksIcon size={14} />
        <span>{task.key}</span>
      </div>
      <div className="card-title">{task.title}</div>
      {task.outcome && <div className="card-sub">{task.outcome}</div>}
      <div className="card-row">
        <Chip tone={statusTone(task.status)}>{statusLabel(task.status)}</Chip>
        {owner && <Chip>{owner.display_name}</Chip>}
      </div>
    </button>
  );
}

function RunCardInline({ runId }: { runId: string }) {
  const app = useApp();
  const api = useApi();
  const { inspect } = useNavigation();
  const run = app.runs[runId];

  useEffect(() => {
    if (!app.runs[runId]) void store.loadRun(runId);
  }, [runId, app.runs]);

  if (!run) return null;
  const agent = app.members.find((member) => member.id === run.agent_id);
  const active = !["succeeded", "failed", "cancelled"].includes(run.status);

  // A run is not an announcement. Nearly every one of them — starting, working,
  // finished — is a single quiet line in the transcript, because the thing you
  // came to read is the agent's actual reply, not a status panel wrapped around
  // it. Only a run that has failed, or that is sitting waiting for a person,
  // has earned the weight of a card.
  const wantsAttention = run.status === "failed" || run.status === "waiting";

  if (!wantsAttention) {
    return (
      <div className={`run-line${active ? " active" : ""}`}>
        {active ? <Spinner size={13} /> : <RunIcon size={14} />}
        <span className="text">
          {active ? (
            <>{run.headline || `${agent?.display_name ?? "An agent"} is working`}</>
          ) : (
            <>
              <span className="who">{agent?.display_name} </span>
              {run.status === "cancelled" ? "was stopped" : `ran ${run.runtime}`} ·{" "}
              {duration(run.started_at, run.ended_at)}
            </>
          )}
        </span>
        <button
          className="run-line-action"
          onClick={() => inspect({ kind: "run", runId: run.id })}
        >
          Details
        </button>
        {active && (
          <button className="run-line-action" onClick={() => api.cancelRun(run.id)}>
            Stop
          </button>
        )}
      </div>
    );
  }

  return (
    <div className={`card ${run.status}`}>
      <div className="card-head">
        {run.status === "waiting" ? <QuestionIcon size={14} /> : <RunIcon size={14} />}
        <span>
          {agent?.display_name} · {run.runtime}
        </span>
      </div>
      <div className="card-title">{run.headline || statusLabel(run.status)}</div>
      {run.error && (
        <div className="card-sub" style={{ color: "var(--danger)" }}>
          {run.error}
        </div>
      )}
      <div className="card-row">
        <Chip tone={statusTone(run.status)}>{statusLabel(run.status)}</Chip>
        <Chip>{duration(run.started_at, run.ended_at)}</Chip>
        <span className="spacer" />
        <button
          className="button quiet"
          onClick={() => inspect({ kind: "run", runId: run.id })}
        >
          Details
        </button>
        {active && (
          <button className="button quiet" onClick={() => api.cancelRun(run.id)}>
            Stop
          </button>
        )}
      </div>
    </div>
  );
}

/// The clarification flow: an agent's question is answered in place, and the
/// answer goes straight back to the waiting run.
function QuestionCard({ questionId }: { questionId: string }) {
  const app = useApp();
  const api = useApi();
  const question = app.questions[questionId];
  const [selection, setSelection] = useState<Record<string, string[]>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [sending, setSending] = useState(false);

  useEffect(() => {
    void store.loadQuestion(questionId);
  }, [questionId]);

  if (!question) return null;
  const answered = question.status === "answered";

  const toggle = (itemId: string, label: string, multi: boolean) => {
    const current = selection[itemId] ?? [];
    if (multi) {
      setSelection({
        ...selection,
        [itemId]: current.includes(label)
          ? current.filter((value) => value !== label)
          : [...current, label],
      });
    } else {
      setSelection({ ...selection, [itemId]: [label] });
    }
  };

  const submit = async () => {
    setSending(true);
    try {
      const answers: QuestionAnswer[] = question.items.map((item) => ({
        item_id: item.id,
        values: selection[item.id] ?? [],
        note: notes[item.id] ?? "",
      }));
      await api.answerQuestion(question.id, answers);
    } finally {
      setSending(false);
    }
  };

  const ready = question.items.every(
    (item) =>
      (selection[item.id]?.length ?? 0) > 0 || (notes[item.id] ?? "").trim() !== "",
  );

  return (
    <div className="card">
      <div className="card-head">
        <QuestionIcon size={14} />
        <span>Needs your answer</span>
      </div>
      {question.items.map((item) => (
        <div key={item.id} style={{ marginTop: 8 }}>
          {item.header && <Chip tone="accent">{item.header}</Chip>}
          <div className="card-title" style={{ marginTop: 4 }}>
            {item.question}
          </div>
          {item.options.map((option) => {
            const chosen = (
              answered
                ? (question.answers?.find((a) => a.item_id === item.id)?.values ?? [])
                : (selection[item.id] ?? [])
            ).includes(option.label);
            return (
              <button
                key={option.label}
                className={`question-option${chosen ? " selected" : ""}`}
                disabled={answered}
                onClick={() => toggle(item.id, option.label, item.multi_select)}
              >
                <div>
                  <div className="label">{option.label}</div>
                  {option.description && (
                    <div className="description">{option.description}</div>
                  )}
                </div>
              </button>
            );
          })}
          {item.allow_free_text && !answered && (
            <input
              className="field"
              style={{ marginTop: 6 }}
              placeholder={item.options.length ? "Or say something else" : "Your answer"}
              value={notes[item.id] ?? ""}
              onChange={(event) =>
                setNotes({ ...notes, [item.id]: event.target.value })
              }
            />
          )}
          {answered && (
            <div className="card-sub" style={{ marginTop: 6 }}>
              {question.answers
                ?.find((a) => a.item_id === item.id)
                ?.note}
            </div>
          )}
        </div>
      ))}

      {!answered && (
        <div className="card-row">
          <button
            className="button primary"
            disabled={!ready || sending}
            onClick={submit}
          >
            {sending ? "Sending" : "Answer"}
          </button>
          <span className="composer-hint">This unblocks the run.</span>
        </div>
      )}
      {answered && (
        <div className="card-row">
          <Chip tone="positive">Answered</Chip>
        </div>
      )}
    </div>
  );
}

function ArtifactCard({
  attachmentId,
  caption,
}: {
  attachmentId: string;
  caption?: string;
}) {
  const api = useApi();
  const url = `${api.baseUrl.replace(/\/$/, "")}/api/files/${attachmentId}`;
  const [broken, setBroken] = useState(false);

  return (
    <div className="card">
      <div className="card-head">
        <span>Attached</span>
      </div>
      {!broken ? (
        <img
          src={url}
          alt={caption ?? "attachment"}
          style={{ maxWidth: "100%", borderRadius: 8 }}
          onError={() => setBroken(true)}
        />
      ) : (
        <button className="button" onClick={() => openExternal(url)}>
          Open file
        </button>
      )}
      {caption && <div className="card-sub">{caption}</div>}
    </div>
  );
}

function PreviewCard({ previewId }: { previewId: string }) {
  const app = useApp();
  const api = useApi();
  const preview = app.previews[previewId];

  useEffect(() => {
    void store.loadPreview(previewId);
  }, [previewId]);

  if (!preview) return null;
  const url = preview.local_only
    ? `http://127.0.0.1:${preview.port}`
    : preview.url;

  return (
    <div className="card">
      <div className="card-head">
        <PreviewIcon size={14} />
        <span>Preview · port {preview.port}</span>
      </div>
      <div className="card-title">{preview.label}</div>
      <div className="card-row">
        <Chip tone={preview.status === "live" ? "positive" : ""}>
          {statusLabel(preview.status as never)}
        </Chip>
        {preview.local_only && <Chip>on this machine</Chip>}
        <span className="spacer" />
        {preview.status === "live" && (
          <>
            <button className="button" onClick={() => openExternal(url)}>
              Open
            </button>
            <button
              className="button quiet"
              onClick={() => api.stopPreview(preview.id)}
            >
              Stop
            </button>
          </>
        )}
      </div>
    </div>
  );
}

function PullRequestCard({ url, taskId }: { url: string; taskId?: string }) {
  const app = useApp();
  const task = app.tasks.find((candidate) => candidate.id === taskId);
  const pr = task?.pr_state;

  return (
    <div className="card">
      <div className="card-head">
        <ExternalIcon size={14} />
        <span>Pull request{pr ? ` #${pr.number}` : ""}</span>
      </div>
      <div className="card-title">{pr?.title ?? url}</div>
      <div className="card-row">
        {pr && <Chip tone={pr.state === "MERGED" ? "positive" : ""}>{pr.state}</Chip>}
        {pr?.checks && (
          <Chip tone={pr.checks === "FAILURE" ? "danger" : pr.checks === "SUCCESS" ? "positive" : "caution"}>
            checks {pr.checks.toLowerCase()}
          </Chip>
        )}
        {pr?.review && <Chip tone={pr.review === "APPROVED" ? "positive" : "caution"}>
          {pr.review.toLowerCase().replace(/_/g, " ")}
        </Chip>}
        <span className="spacer" />
        <button className="button" onClick={() => openExternal(url)}>
          <ExternalIcon size={14} />
          Open on GitHub
        </button>
      </div>
    </div>
  );
}

export function AttachmentRow({
  fileName,
  size,
  url,
}: {
  fileName: string;
  size: number;
  url: string;
}) {
  return (
    <button className="attachment-chip" onClick={() => openExternal(url)}>
      {fileName}
      <span style={{ color: "var(--text-faint)" }}>{bytes(size)}</span>
    </button>
  );
}
