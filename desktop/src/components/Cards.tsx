import { useEffect, useMemo, useRef, useState } from "react";
import type { ChartAssemblyInput } from "flint-chart";
import type { EChartsType } from "echarts";
import { evidenceKind, isTextEvidence, normalizedChartSpec } from "@client/evidence";
import { useApi, useAppSelector, store } from "../lib/store";
import { bytes, duration, pullRequestTone, statusLabel, statusTone } from "../lib/format";
import { openExternal } from "../lib/desktop";
import { useFileUrl, useGrantedFileUrl, usePreviewUrl } from "../lib/file";
import { Chip, proseText, useNavigation } from "./common";
import { Lightbox, TextEvidence } from "./Evidence";
import {
  ExternalIcon,
  PreviewIcon,
  QuestionIcon,
  RunIcon,
} from "./icons";
import type { Attachment, MessageCard } from "@client/types";

/// Cards are how tasks, runs, asks, artifacts, previews and pull requests
/// appear inline in a conversation — the same objects the rest of the app
/// navigates to, not copies of them.
export function Card({
  card,
  body = "",
  attachments = [],
}: {
  card: MessageCard;
  body?: string;
  /// The message's own files, so an artifact card renders as the evidence it
  /// points at rather than as a second, thinner viewer.
  attachments?: Attachment[];
}) {
  // The message above already says it. A caption that repeats the sentence
  // word for word is the same title twice.
  const captionOf = (caption?: string) =>
    caption && caption.trim() === body.trim() ? undefined : caption;

  switch (card.type) {
    case "task":
      return <TaskCardInline taskId={card.task_id} />;
    case "run":
      return <RunCardInline runId={card.run_id} />;
    case "ask":
      return <AskCard askId={card.ask_id} />;
    case "artifact": {
      const attachment = attachments.find(
        (candidate) => candidate.id === card.attachment_id,
      );
      return attachment ? (
        <EvidenceCard attachment={attachment} caption={captionOf(card.caption)} />
      ) : (
        <PinnedEvidence attachmentId={card.attachment_id} />
      );
    }
    case "preview":
      return <PreviewCard previewId={card.preview_id} />;
    case "pull_request":
      return <PullRequestCard url={card.url} taskId={card.task_id} />;
    case "chart":
      return <ChartCard spec={card.spec} caption={captionOf(card.caption)} />;
  }
}

/// What the task is called and where it stands. The key, the owner and the
/// status were three more things to read that the brief already accounts for.
function TaskCardInline({ taskId }: { taskId: string }) {
  const task = useAppSelector((data) =>
    data.tasks.find((candidate) => candidate.id === taskId),
  );
  const { go } = useNavigation();
  if (!task) return null;

  return (
    <button
      className="card task-inline"
      title={task.key}
      onClick={() => go({ kind: "task", id: task.id })}
    >
      <div className="card-title">{task.title}</div>
      {task.brief && <div className="card-sub">{task.brief}</div>}
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
        {/* Which runtime it was is a fact about the plumbing. What a reader
            wants from this line is that it is over and roughly how long it
            took. */}
        <span className="text">
          <span className="who">{agent?.display_name} </span>
          {run.status === "cancelled" ? "stopped" : "finished"} ·{" "}
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

/// The one thing an agent needs from a person, answered where it was asked.
///
/// Every way out of it is the same call: picking an option, typing a sentence,
/// or pressing the action a review names. Approval is not a separate gesture,
/// it is answering with the label on the button.
function AskCard({ askId }: { askId: string }) {
  const ask = useAppSelector((data) => data.asks[askId]);
  const api = useApi();
  const [picked, setPicked] = useState<string[]>([]);
  const [note, setNote] = useState("");
  const [sending, setSending] = useState(false);
  const [failed, setFailed] = useState("");

  useEffect(() => {
    // The card event can arrive just before its ask transaction settles.
    void store.loadAsk(askId).catch(() => {});
  }, [askId]);

  if (!ask) return null;
  // Only an open ask is something to answer. A cancelled one is over: the run
  // moved on without you, and offering a box that cannot post is worse than
  // saying so.
  const open = ask.status === "open";
  const answered = ask.status === "answered";

  const answer = async (values: string[]) => {
    setSending(true);
    setFailed("");
    try {
      await api.answerAsk(ask.id, values, note.trim());
    } catch (error) {
      // A refusal often means this copy is stale, so show it and refresh.
      setFailed(String((error as Error).message ?? error));
      void store.loadAsk(ask.id, true).catch(() => {});
    } finally {
      setSending(false);
    }
  };

  const choose = (label: string) => {
    if (!ask.multi_select) {
      void answer([label]);
      return;
    }
    setPicked((current) =>
      current.includes(label)
        ? current.filter((value) => value !== label)
        : [...current, label],
    );
  };

  const chosen = answered ? ask.answer : picked;
  const ready = picked.length > 0 || note.trim() !== "";

  return (
    <div className="card">
      <div className="card-head">
        <QuestionIcon size={14} />
        <span>{open || answered ? "Needs you" : "No longer needed"}</span>
      </div>
      <div className="card-title">{ask.text}</div>
      {ask.summary.length > 0 && (
        <ul className="ask-summary">
          {ask.summary.map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      )}
      {ask.evidence_ids.map((id) => (
        <PinnedEvidence key={id} attachmentId={id} />
      ))}

      {ask.options.map((option) => (
        <button
          key={option.label}
          className={`question-option${chosen.includes(option.label) ? " selected" : ""}`}
          disabled={!open || sending}
          onClick={() => choose(option.label)}
        >
          <div>
            <div className="label">{option.label}</div>
            {option.description && (
              <div className="description">{option.description}</div>
            )}
          </div>
        </button>
      ))}
      {ask.allow_free_text && open && (
        <input
          className="field"
          {...proseText}
          style={{ marginTop: 6 }}
          placeholder={ask.options.length ? "Or say something else" : "Your answer"}
          value={note}
          onChange={(event) => setNote(event.target.value)}
        />
      )}

      {failed && (
        <div className="card-sub" style={{ color: "var(--danger)" }}>
          {failed}
        </div>
      )}

      {open && (ask.action || ask.multi_select || ask.allow_free_text) && (
        <div className="card-row">
          <button
            className="button primary"
            disabled={sending || (!ask.action && !ready)}
            onClick={() => void answer(ask.action ? [ask.action] : picked)}
          >
            {sending ? "Sending" : (ask.action ?? "Answer")}
          </button>
        </div>
      )}
      {answered && (
        <div className="card-row">
          <Chip tone="positive">{ask.answer.join(", ") || "Answered"}</Chip>
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

/// An ask points at what to look at first. The file itself is already in the
/// transcript with the message that posted it, so this is the same card again
/// rather than a second gallery.
function PinnedEvidence({ attachmentId }: { attachmentId: string }) {
  const api = useApi();
  const attachment = useAppSelector((data) => {
    for (const list of Object.values(data.messages)) {
      for (const message of list) {
        const hit = message.attachments.find((item) => item.id === attachmentId);
        if (hit) return hit;
      }
    }
    return undefined;
  });

  // Pinned from further back than this client has loaded: still openable.
  if (!attachment) {
    return (
      <button
        className="attachment-chip"
        onClick={() => void api.openFile(`/api/files/${attachmentId}`)}
      >
        Open the attached file
      </button>
    );
  }
  return <EvidenceCard attachment={attachment} />;
}

/// Evidence, rendered where it was posted.
///
/// One card for every kind: a screenshot opens big, a video plays, a report or
/// a table renders as itself. Folded to a preview, because a transcript is a
/// conversation and not a document viewer until you ask it to be.
export function EvidenceCard({
  attachment,
  caption,
}: {
  attachment: Attachment;
  caption?: string;
}) {
  const api = useApi();
  const kind = evidenceKind(attachment.mime, attachment.file_name);
  const image = kind === "image";
  const video = kind === "video";
  const [open, setOpen] = useState(false);
  const [zoomed, setZoomed] = useState(false);
  const [broken, setBroken] = useState(false);
  // Only a video needs a URL the media element can fetch on its own; text is
  // read through the authenticated client and images are already blobs.
  const granted = useGrantedFileUrl(video ? attachment.id : undefined);
  const imageUrl = useFileUrl(image && !broken ? attachment.url : "");
  const label = caption || attachment.caption || attachment.file_name;

  if (image && !broken) {
    if (!imageUrl) return <span className="attachment-chip">Loading image…</span>;
    return (
      <>
        <button
          className="image-attachment"
          title="Open this image"
          onClick={() => setZoomed(true)}
        >
          <img src={imageUrl} alt={label} onError={() => setBroken(true)} />
        </button>
        {zoomed && (
          <Lightbox url={imageUrl} alt={label} onClose={() => setZoomed(false)} />
        )}
      </>
    );
  }

  if (video) {
    return granted ? (
      <video className="review-video" src={granted} controls preload="metadata" />
    ) : (
      <span className="attachment-chip">Loading video…</span>
    );
  }

  if (!isTextEvidence(kind)) {
    return (
      <AttachmentRow
        fileName={attachment.file_name}
        size={attachment.size}
        onOpen={() => void api.openFile(attachment.url)}
      />
    );
  }

  return (
    <div className="evidence-card">
      <button className="evidence-head" onClick={() => setOpen(!open)}>
        <span className="name">{label}</span>
        <span className="sub">{open ? "Hide" : "Show"}</span>
      </button>
      {open && <TextEvidence attachment={attachment} />}
    </div>
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
        const option = flint.assembleECharts(normalizedChartSpec(spec) as ChartAssemblyInput);
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
        {pr && <Chip tone={pullRequestTone(pr.state)}>{pr.state}</Chip>}
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
