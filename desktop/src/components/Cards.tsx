import { useEffect, useMemo, useRef, useState } from "react";
import type { ChartAssemblyInput } from "flint-chart";
import type { EChartsType } from "echarts";
import { useApi, useAppSelector, store } from "../lib/store";
import { bytes, duration, statusLabel, statusTone } from "../lib/format";
import { openExternal } from "../lib/desktop";
import { useFileUrl, usePreviewUrl } from "../lib/file";
import { Chip, proseText, useNavigation } from "./common";
import {
  ExternalIcon,
  PreviewIcon,
  QuestionIcon,
  RunIcon,
  TasksIcon,
} from "./icons";
import type { MessageCard, QuestionAnswer } from "@client/types";

/// Cards are how tasks, runs, questions, artifacts, previews and pull requests
/// appear inline in a conversation — the same objects the rest of the app
/// navigates to, not copies of them.
export function Card({ card, body = "" }: { card: MessageCard; body?: string }) {
  // The message above already says it. A caption that repeats the sentence
  // word for word is the same title twice.
  const captionOf = (caption?: string) =>
    caption && caption.trim() === body.trim() ? undefined : caption;

  switch (card.type) {
    case "task":
      return <TaskCardInline taskId={card.task_id} />;
    case "run":
      return <RunCardInline runId={card.run_id} />;
    case "question":
      return <QuestionCard questionId={card.question_id} />;
    case "artifact":
      return (
        <ArtifactCard
          attachmentId={card.attachment_id}
          caption={captionOf(card.caption)}
        />
      );
    case "preview":
      return <PreviewCard previewId={card.preview_id} />;
    case "pull_request":
      return <PullRequestCard url={card.url} taskId={card.task_id} />;
    case "chart":
      return <ChartCard spec={card.spec} caption={captionOf(card.caption)} />;
  }
}

function TaskCardInline({ taskId }: { taskId: string }) {
  const { task, owner } = useAppSelector((data) => {
    const task = data.tasks.find((candidate) => candidate.id === taskId);
    return {
      task,
      owner: data.members.find((member) => member.id === task?.owner_id),
    };
  });
  const { go } = useNavigation();
  if (!task) return null;

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
  const { run, agent } = useAppSelector((data) => {
    const run = data.runs[runId];
    return {
      run,
      agent: data.members.find((member) => member.id === run?.agent_id),
    };
  });
  const { inspect } = useNavigation();

  // Keyed on whether we have it, not on the runs map: that map gets a new
  // identity on every run event in the workspace, and re-running this on each
  // one meant re-deciding the same "no, we already have it" repeatedly.
  const missing = !run;
  useEffect(() => {
    if (missing) void store.loadRun(runId);
  }, [runId, missing]);

  if (!run) return null;
  const active = !["succeeded", "failed", "cancelled"].includes(run.status);

  // A run is not an announcement. Nearly every one of them — starting, working,
  // finished — is a single quiet line in the transcript, because the thing you
  // came to read is the agent's actual reply, not a status panel wrapped around
  // it. Only a run that has failed, or that is sitting waiting for a person,
  // has earned the weight of a card.
  const wantsAttention = run.status === "failed" || run.status === "waiting";

  // While a run is going, the floating pill above the composer is already
  // saying so, and saying it twice — once here, once down there — is the app
  // talking over itself. The transcript keeps the finished record; the pill
  // owns "right now", including the controls.
  if (active) return null;

  if (!wantsAttention) {
    return (
      <div className="run-line">
        <RunIcon size={14} />
        <span className="text">
          <span className="who">{agent?.display_name} </span>
          {run.status === "cancelled" ? "was stopped" : `ran ${run.runtime}`} ·{" "}
          {duration(run.started_at, run.ended_at)}
        </span>
        <button
          className="run-line-action"
          onClick={() => inspect({ kind: "run", runId: run.id })}
        >
          Details
        </button>
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
      </div>
    </div>
  );
}

/// The clarification flow: an agent's question is answered in place, and the
/// answer goes straight back to the waiting run.
function QuestionCard({ questionId }: { questionId: string }) {
  const question = useAppSelector((data) => data.questions[questionId]);
  const api = useApi();
  const [selection, setSelection] = useState<Record<string, string[]>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [sending, setSending] = useState(false);
  const [failed, setFailed] = useState("");

  useEffect(() => {
    // The card event can arrive just before its question transaction settles.
    void store.loadQuestion(questionId).catch(() => {});
  }, [questionId]);

  if (!question) return null;
  // Only an open question is something to answer. A cancelled one is over:
  // the run moved on without you, and offering a box that cannot post is
  // worse than saying so.
  const open = question.status === "open";
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
    setFailed("");
    try {
      const answers: QuestionAnswer[] = question.items.map((item) => ({
        item_id: item.id,
        values: selection[item.id] ?? [],
        note: notes[item.id] ?? "",
      }));
      await api.answerQuestion(question.id, answers);
    } catch (error) {
      // A refusal often means this copy is stale, so show it and refresh.
      setFailed(String((error as Error).message ?? error));
      void store.loadQuestion(question.id, true).catch(() => {});
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
        <span>{open || answered ? "Needs your answer" : "No longer needed"}</span>
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
                disabled={!open}
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
          {item.allow_free_text && open && (
            <input
              className="field"
              {...proseText}
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

      {failed && (
        <div className="card-sub" style={{ color: "var(--danger)" }}>
          {failed}
        </div>
      )}

      {open && (
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
      {!open && !answered && (
        <div className="card-row">
          <Chip>Cancelled</Chip>
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
  const path = `/api/files/${attachmentId}`;
  const url = useFileUrl(path);
  const [broken, setBroken] = useState(false);

  if (broken) {
    return (
      <div className="card">
        <div className="card-head">
          <span>Attached</span>
        </div>
        <button className="button" onClick={() => void api.openFile(path)}>
          Open file
        </button>
        {caption && <div className="card-sub">{caption}</div>}
      </div>
    );
  }
  if (!url) return <div className="card-sub">Loading attachment…</div>;

  // No frame around a picture: a border, a header and a caption stacked
  // around an image say nothing the image does not.
  return (
    <figure className="artifact">
      <img src={url} alt={caption ?? "attachment"} onError={() => setBroken(true)} />
      {caption && <figcaption className="card-sub">{caption}</figcaption>}
    </figure>
  );
}

/// A chart arrives as a spec, not as a picture: the agent says what the data is
/// and what to show, and it is compiled here. Both libraries are imported
/// inside the effect rather than at the top of the file, so they land in their
/// own chunk — a workspace that never sees a chart never pays for one.
function ChartCard({ spec, caption }: { spec: unknown; caption?: string }) {
  const host = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState("");
  // A reaction or an edit hands us a fresh copy of the same message, and
  // redrawing the chart because an emoji arrived would be a visible flicker.
  // Only the contents decide whether it is a different chart.
  const identity = useMemo(() => JSON.stringify(spec), [spec]);

  // The app has no theme control of its own, it follows the system, so the
  // chart follows it too rather than picking a side at mount and keeping it.
  const [dark, setDark] = useState(
    () => window.matchMedia("(prefers-color-scheme: dark)").matches,
  );
  useEffect(() => {
    const scheme = window.matchMedia("(prefers-color-scheme: dark)");
    const sync = () => setDark(scheme.matches);
    scheme.addEventListener("change", sync);
    return () => scheme.removeEventListener("change", sync);
  }, []);

  useEffect(() => {
    let chart: EChartsType | undefined;
    let observer: ResizeObserver | undefined;
    let dropped = false;

    void (async () => {
      try {
        const [flint, echarts] = await Promise.all([
          import("flint-chart"),
          import("echarts"),
        ]);
        const option = flint.assembleECharts(spec as ChartAssemblyInput);
        if (dropped || !host.current) return;
        chart = echarts.init(host.current, dark ? "dark" : null);
        // No title inside the canvas: the message above the chart is its
        // title, and a second one drawn over the plot is what collided with
        // the legend. The transcript sits behind it, so no background either.
        chart.setOption({
          ...option,
          title: undefined,
          backgroundColor: "transparent",
        });
        observer = new ResizeObserver(() => chart?.resize());
        observer.observe(host.current);
      } catch (error) {
        // A spec we cannot draw is one quiet card, never a broken transcript.
        if (!dropped) setFailed(String((error as Error).message ?? error));
      }
    })();

    return () => {
      dropped = true;
      observer?.disconnect();
      chart?.dispose();
    };
    // `spec` is deliberately absent: `identity` is what says it changed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [identity, dark]);

  const height =
    (spec as { chart_spec?: { baseSize?: { height?: number } } })?.chart_spec
      ?.baseSize?.height ?? 320;

  if (failed) {
    return <div className="notice">This chart could not be drawn: {failed}</div>;
  }

  return (
    <figure className="chart">
      <div ref={host} style={{ width: "100%", height }} />
      {caption && <figcaption className="card-sub">{caption}</figcaption>}
    </figure>
  );
}

function PreviewCard({ previewId }: { previewId: string }) {
  const preview = useAppSelector((data) => data.previews[previewId]);
  const api = useApi();

  useEffect(() => {
    void store.loadPreview(previewId);
  }, [previewId]);

  const url = usePreviewUrl(previewId, preview?.status === "live");
  if (!preview) return null;

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
        <span className="spacer" />
        {preview.status === "live" && (
          <>
            <button className="button" disabled={!url} onClick={() => openExternal(url)}>
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
  const pr = useAppSelector(
    (data) => data.tasks.find((candidate) => candidate.id === taskId)?.pr_state,
  );

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
  onOpen,
}: {
  fileName: string;
  size: number;
  onOpen: () => void;
}) {
  return (
    <button className="attachment-chip" onClick={onOpen}>
      {fileName}
      <span style={{ color: "var(--text-faint)" }}>{bytes(size)}</span>
    </button>
  );
}
