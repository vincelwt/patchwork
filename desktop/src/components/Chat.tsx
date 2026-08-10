import {
  memo,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { store, useApi, useAppSelector } from "../lib/store";
import { bytes, dayLabel, duration, timeOfDay } from "../lib/format";
import { useVirtualWindow } from "../lib/virtual";
import { useBottomAnchor } from "../lib/scroll";
import { useFileUrl } from "../lib/file";
import { Avatar, proseText, useNavigation } from "./common";
import { useDictation } from "../lib/dictation";
import { readTask } from "../lib/task";
import { leaveComposer, movePane } from "../lib/shortcuts";
import {
  AttachIcon,
  CloseIcon,
  CopyIcon,
  EventIcon,
  MicIcon,
  MoreIcon,
  PulseIcon,
  ReactIcon,
  ReplyIcon,
  RunIcon,
  SendIcon,
  Spinner,
  ThreadIcon,
} from "./icons";
import { Menu, type MenuItem } from "./ui";
import { AttachmentRow, Card } from "./Cards";
import { Markdown } from "./Markdown";
import { ReactionPicker, ReactionRow } from "./Reactions";
import type { Attachment, Channel, Id, Member, Message, Run } from "@client/types";

export function ChatView({ channelId }: { channelId: Id }) {
  const { channel, messages } = useAppSelector((data) => ({
    channel: data.channels.find((candidate) => candidate.id === channelId),
    messages: data.messages[channelId],
  }));
  const [dropped, setDropped] = useState<File[]>([]);
  const [replyTo, setReplyTo] = useState<Message>();
  const clearDropped = useCallback(() => setDropped([]), []);

  useEffect(() => {
    setReplyTo(undefined);
    void store.loadChannel(channelId);
  }, [channelId]);

  if (!channel) return <div className="empty">This conversation is gone.</div>;

  return (
    // Anywhere in the conversation is a drop target. Aiming for the text box is
    // a requirement invented by the implementation, not by the person holding
    // the file — they are dropping it *into this conversation*.
    <DropZone onFiles={(files) => setDropped(files)}>
      <Timeline
        channelId={channelId}
        messages={messages ?? []}
        onReply={setReplyTo}
      />
      <Composer
        channel={channel}
        incoming={dropped}
        onConsumed={clearDropped}
        replyTo={replyTo}
        onCancelReply={() => setReplyTo(undefined)}
      />
    </DropZone>
  );
}

/// A drop target that covers its whole subtree.
///
/// Enter and leave are counted rather than toggled: moving over a child fires
/// `dragleave` on the parent, and a naive boolean flickers the overlay on every
/// message the cursor crosses.
export function DropZone({
  onFiles,
  children,
  className = "column",
}: {
  onFiles: (files: File[]) => void;
  children: React.ReactNode;
  className?: string;
}) {
  const [over, setOver] = useState(false);
  const depth = useRef(0);
  const carrying = (event: React.DragEvent) =>
    event.dataTransfer.types.includes("Files");

  return (
    <div
      className={`${className} dropzone${over ? " over" : ""}`}
      onDragEnter={(event) => {
        if (!carrying(event)) return;
        depth.current += 1;
        setOver(true);
      }}
      onDragOver={(event) => {
        if (!carrying(event)) return;
        // Without this the browser refuses the drop and shows a "no" cursor.
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
      }}
      onDragLeave={() => {
        depth.current = Math.max(0, depth.current - 1);
        if (depth.current === 0) setOver(false);
      }}
      onDrop={(event) => {
        depth.current = 0;
        setOver(false);
        const files = Array.from(event.dataTransfer.files);
        if (files.length === 0) return;
        event.preventDefault();
        onFiles(files);
      }}
    >
      {children}
      {over && (
        <div className="drop-overlay">
          <span>Drop to attach</span>
        </div>
      )}
    </div>
  );
}

/// How long a typing signal stands for before the person counts as stopped.
const TYPING_TTL = 4000;

/// Two messages are one block when the same person said them close together.
/// This is what makes a transcript read as conversation rather than as a stack
/// of envelopes, and it is the single biggest thing that makes chat feel like
/// chat.
function groupsWithPrevious(message: Message, previous?: Message): boolean {
  if (!previous) return false;
  if (message.kind !== "text" || previous.kind !== "text") return false;
  if (previous.author_id !== message.author_id) return false;
  return message.created_at - previous.created_at < 5 * 60_000;
}

export function Timeline({
  channelId,
  messages,
  onReply,
}: {
  channelId: Id;
  messages: Message[];
  onReply: (message: Message) => void;
}) {
  const { members, runs, hasMore, sourceMessageId } = useAppSelector((data) => {
    const channel = data.channels.find((candidate) => candidate.id === channelId);
    const task = channel?.task_id
      ? data.tasks.find((candidate) => candidate.id === channel.task_id)
      : undefined;
    return {
      members: data.members,
      runs: data.runs,
      hasMore: !!data.hasMore[channelId],
      /// The request as it was first written, which the discussion should keep
      /// legible however far the conversation has moved on.
      sourceMessageId: task?.source_message_id,
    };
  });
  const handles = useHandles();
  const { scrollerRef, contentRef, updatePinned } = useBottomAnchor(channelId);
  const window_ = useVirtualWindow(scrollerRef, messages.length);

  const onScroll = () => {
    const element = scrollerRef.current;
    if (!element) return;
    updatePinned();
    if (element.scrollTop < 60 && hasMore) {
      const previousHeight = element.scrollHeight;
      void store.loadOlder(channelId).then(() => {
        requestAnimationFrame(() => {
          if (scrollerRef.current) {
            scrollerRef.current.scrollTop =
              scrollerRef.current.scrollHeight - previousHeight;
          }
        });
      });
    }
  };

  // Day markers and grouping are decided for the whole list, not for the
  // visible slice — otherwise scrolling would change where the dividers fall.
  const rows = useMemo(() => {
    let previousDay: string | undefined;
    const out = messages.map((message, index) => {
      const previous = messages[index - 1];
      const day = dayLabel(message.created_at);
      const showDay = day !== previousDay;
      previousDay = day;
      return {
        message,
        day: showDay ? day : undefined,
        grouped: !showDay && groupsWithPrevious(message, previous),
        /// Set on the first of a run of workspace events: the whole run,
        /// drawn as one line.
        group: undefined as Message[] | undefined,
        /// Swallowed by the line above it.
        hidden: false,
      };
    });

    // Dragging a card across the board four times is one thing that happened,
    // not four things to read. A run of workspace events collapses into its
    // latest line, which opens if you actually want the history.
    for (let start = 0; start < out.length; ) {
      if (out[start].message.kind !== "system") {
        start += 1;
        continue;
      }
      let end = start + 1;
      while (
        end < out.length &&
        out[end].message.kind === "system" &&
        !out[end].day
      ) {
        end += 1;
      }
      if (end - start >= 3) {
        out[start].group = out.slice(start, end).map((row) => row.message);
        for (let at = start + 1; at < end; at += 1) out[at].hidden = true;
      }
      start = end;
    }
    return out;
  }, [messages]);

  const authorOf = useMemo(() => {
    const map = new Map<Id, Member>();
    for (const member of members) map.set(member.id, member);
    return map;
  }, [members]);
  const messageOf = useMemo(
    () => new Map(messages.map((message) => [message.id, message])),
    [messages],
  );

  // A finished run belongs *in* the reply it produced, not on a line of its own
  // above it. Two rows for one thing the agent did is one row too many.
  const runsWithReply = useMemo(() => {
    const set = new Set<Id>();
    for (const message of messages) {
      if (message.kind === "text" && message.run_id) set.add(message.run_id);
    }
    return set;
  }, [messages]);

  return (
    <div className="timeline" ref={scrollerRef} onScroll={onScroll}>
      <div className="timeline-inner" ref={contentRef}>
        {messages.length === 0 && (
          <div className="empty">
            Nothing here yet. Say something, or bring an agent in with @.
          </div>
        )}
        {window_.padTop > 0 && <div style={{ height: window_.padTop }} />}
        {rows.slice(window_.start, window_.end).map((row, offset) => {
          const index = window_.start + offset;
          const message = row.message;
          const run = message.run_id ? runs[message.run_id] : undefined;
          // The card only still earns its own row when the run failed, is
          // waiting on someone, or produced no reply to fold itself into.
          const folded =
            message.kind === "card" &&
            message.card?.type === "run" &&
            runsWithReply.has(message.card.run_id) &&
            !!runs[message.card.run_id] &&
            !["failed", "waiting"].includes(runs[message.card.run_id].status);
          if (folded || row.hidden)
            return <div key={message.id} ref={window_.rowRef(index)} />;
          return (
            <div key={message.id} ref={window_.rowRef(index)}>
              {row.day && (
                <div className="day-marker">
                  <span>{row.day}</span>
                </div>
              )}
              {row.group ? (
                <ActivityGroup messages={row.group} />
              ) : (
              <MessageRow
                message={message}
                grouped={row.grouped}
                author={authorOf.get(message.author_id)}
                handles={handles}
                run={run}
                original={message.id === sourceMessageId}
                replyTo={messageOf.get(message.reply_to_id ?? "")}
                replyPreview={message.reply_to}
                replyAuthor={authorOf.get(
                  messageOf.get(message.reply_to_id ?? "")?.author_id ??
                    message.reply_to?.author_id ??
                    "",
                )}
                onReply={onReply}
              />
              )}
            </div>
          );
        })}
        {window_.padBottom > 0 && <div style={{ height: window_.padBottom }} />}
      </div>
    </div>
  );
}

/// Talk instead of typing. Only where the machine can do it on its own: a
/// button that needs an API key is a button that needs a settings page.
export function DictateButton({
  value,
  onText,
}: {
  value: string;
  onText: (text: string) => void;
}) {
  const { supported, recording, error, start, stop, within, latestToggle } =
    useDictation(onText);
  const toggle = () => (recording ? stop() : start(value));
  // Re-pointed on every render so the chord always starts from the text that
  // is in the box now, not the text that was there when it mounted.
  latestToggle.current = toggle;

  if (!supported) return null;

  return (
    <button
      ref={(node) => {
        within.current = node?.closest(".composer, .task-composer") ?? null;
      }}
      className={`icon-button dictate${recording ? " recording" : ""}`}
      title={error || (recording ? "Stop dictating (⌘D)" : "Dictate (⌘D)")}
      onClick={toggle}
    >
      <MicIcon size={17} />
    </button>
  );
}

/// A run of workspace events as one line, with the rest one click away.
function ActivityGroup({ messages }: { messages: Message[] }) {
  const [open, setOpen] = useState(false);
  const latest = messages[messages.length - 1];

  if (open) {
    return (
      <>
        {messages.map((message) => (
          <div className="activity" key={message.id}>
            <EventIcon size={15} />
            <span className="text">{message.body}</span>
          </div>
        ))}
        <button className="activity-toggle" onClick={() => setOpen(false)}>
          Hide
        </button>
      </>
    );
  }

  return (
    <div className="activity">
      <EventIcon size={15} />
      <span className="text">{latest.body}</span>
      <button className="activity-toggle" onClick={() => setOpen(true)}>
        {messages.length - 1} earlier
      </button>
    </div>
  );
}

/// Handles that resolve to a real member, so `@2x` in a sentence about screen
/// resolution does not light up as a mention. Shared by every renderer.
export function useHandles(): Set<string> {
  const members = useAppSelector((data) => data.members);
  return useMemo(
    () => new Set(members.map((member) => member.handle.toLowerCase())),
    [members],
  );
}

/// Everything a row draws, handed to it rather than looked up by it.
///
/// A row that reads the store re-renders whenever *anything* in the workspace
/// changes, which during a streamed reply is several times a second for every
/// message on screen. Taking plain props instead is what lets `memo` do its
/// job: one token arriving re-renders one row.
export const MessageRow = memo(function MessageRow({
  message,
  grouped,
  author,
  handles,
  run,
  original = false,
  replyTo,
  replyPreview,
  replyAuthor,
  onReply,
}: {
  message: Message;
  grouped: boolean;
  author?: Member;
  handles?: Set<string>;
  /// The run that produced this message, summarised in its header.
  run?: Run;
  /// The immutable request this task started from.
  original?: boolean;
  replyTo?: Message;
  replyPreview?: Message["reply_to"];
  replyAuthor?: Member;
  onReply?: (message: Message) => void;
}) {
  const api = useApi();
  const { inspect } = useNavigation();
  const [picker, setPicker] = useState<{ x: number; y: number } | null>(null);
  // Right-click, and the "…" button, open the same menu at a point.
  const [menu, setMenu] = useState<{ x: number; y: number; selection: string } | null>(
    null,
  );

  // A status note or a workspace event is not somebody talking. It reads as a
  // quiet line, the way tool activity does in a good agent transcript.
  if (message.kind === "status" || message.kind === "system") {
    return (
      <div className="activity">
        {message.kind === "status" ? <PulseIcon size={15} /> : <EventIcon size={15} />}
        <span className="text">
          {message.kind === "status" && author && (
            <span className="who">{author.display_name} · </span>
          )}
          {message.body}
        </span>
      </div>
    );
  }

  // A run card carries its own attribution, so repeating the author above it
  // just adds weight to something that is meant to be glanceable.
  const selfAttributed = message.kind === "card" && message.card?.type === "run";
  const showHead = !grouped && !selfAttributed;

  const react = (emoji: string) => {
    void api.react(message.id, emoji);
    setPicker(null);
  };
  const repliedMessage = replyTo ?? replyPreview;

  const items = (at: { x: number; y: number; selection: string }): MenuItem[] => [
    {
      key: "react",
      label: "Add a reaction…",
      icon: <ReactIcon size={15} />,
      onSelect: () => setPicker({ x: at.x, y: at.y }),
    },
    ...(onReply
      ? [
          {
            key: "reply",
            label: "Reply",
            icon: <ReplyIcon size={15} />,
            onSelect: () => onReply(message),
          },
        ]
      : []),
    {
      key: "thread",
      label: "Reply in thread",
      icon: <ThreadIcon size={15} />,
      onSelect: () => inspect({ kind: "thread", messageId: message.id }),
    },
    {
      key: "copy",
      label: at.selection ? "Copy selection" : "Copy text",
      icon: <CopyIcon size={15} />,
      disabled: !at.selection && !message.body.trim(),
      onSelect: () => void navigator.clipboard.writeText(at.selection || message.body),
    },
  ];

  return (
    <div
      className={`message message-${message.kind}${grouped ? " grouped" : ""}${
        selfAttributed ? " bare" : ""
      }`}
      // A message is a row like any other: ↑ ↓ walk the transcript and Enter
      // opens the same menu as a right-click, so react, reply, thread and copy
      // need no mouse. Not in the tab order — tabbing through a day of chat to
      // reach the box you are typing in would be worse than useless.
      tabIndex={-1}
      onContextMenu={(event) => {
        event.preventDefault();
        setMenu({
          x: event.clientX,
          y: event.clientY,
          selection: selectionIn(event.currentTarget),
        });
      }}
      onKeyDown={(event) => {
        if (event.key !== "Enter" || event.target !== event.currentTarget) return;
        event.preventDefault();
        const rect = event.currentTarget.getBoundingClientRect();
        setMenu({ x: rect.left + 48, y: rect.top + 24, selection: "" });
      }}
    >
      <div className="message-gutter">
        {showHead ? (
          <Avatar member={author} size={30} />
        ) : (
          !selfAttributed && (
            <span className="hover-time">{timeOfDay(message.created_at)}</span>
          )
        )}
      </div>

      <div className="message-main">
        {showHead && (
          <div className="message-head">
            <span className="message-author">{author?.display_name ?? "Unknown"}</span>
            {author?.kind === "agent" && <span className="message-badge">agent</span>}
            <span className="message-time">{timeOfDay(message.created_at)}</span>
            {message.edited_at && <span className="message-time">edited</span>}
            {run && <RunMeta run={run} />}
          </div>
        )}
        {message.reply_to_id && (
          <div className="reply-reference">
            <ReplyIcon size={13} />
            <span className="name">
              {repliedMessage ? replyAuthor?.display_name ?? "Unknown" : "Earlier message"}
            </span>
            {repliedMessage && (
              <span className="preview">
                {repliedMessage.body.trim() ||
                  (repliedMessage.card
                    ? repliedMessage.card.type.replaceAll("_", " ")
                    : "Attachment")}
              </span>
            )}
          </div>
        )}
        {message.body && (
          <div className="message-body">
            {original ? (
              // Kept whole and kept where it was written. A long brief folds so
              // that reopening the task does not mean scrolling past it again.
              <details className="original-request" open={message.body.length < 500}>
                <summary>Original request</summary>
                <Markdown body={message.body} handles={handles} />
              </details>
            ) : (
              <Markdown body={message.body} handles={handles} />
            )}
          </div>
        )}
        {message.card && <Card card={message.card} body={message.body} />}
        {message.attachments.length > 0 && (
          <div className="attachments">
            {message.attachments.map((attachment: Attachment) => (
              <Attached key={attachment.id} attachment={attachment} />
            ))}
          </div>
        )}
        <ReactionRow message={message} onAdd={setPicker} />
        {message.reply_count > 0 && (
          <button
            className="thread-link"
            onClick={() => inspect({ kind: "thread", messageId: message.id })}
          >
            <ThreadIcon size={14} />
            {message.reply_count} {message.reply_count === 1 ? "reply" : "replies"}
          </button>
        )}
      </div>

      <div className="message-actions">
        <button
          className="icon-button small"
          title="Add a reaction"
          onClick={(event) => {
            const rect = event.currentTarget.getBoundingClientRect();
            setPicker({ x: rect.left, y: rect.top });
          }}
        >
          <ReactIcon size={16} />
        </button>
        {onReply && (
          <button
            className="icon-button small"
            title="Reply"
            aria-label="Reply"
            onClick={() => onReply(message)}
          >
            <ReplyIcon size={16} />
          </button>
        )}
        <button
          className="icon-button small"
          title="Reply in thread"
          onClick={() => inspect({ kind: "thread", messageId: message.id })}
        >
          <ThreadIcon size={16} />
        </button>
        <button
          className="icon-button small"
          title="More"
          aria-label="More"
          onClick={(event) => {
            const rect = event.currentTarget.getBoundingClientRect();
            const row = event.currentTarget.closest(".message");
            setMenu({ x: rect.left, y: rect.bottom, selection: selectionIn(row) });
          }}
        >
          <MoreIcon size={16} />
        </button>
      </div>

      {menu && (
        <Menu
          at={menu}
          header={author?.display_name}
          items={items(menu)}
          onClose={() => setMenu(null)}
        />
      )}
      {picker && (
        <ReactionPicker at={picker} onPick={react} onClose={() => setPicker(null)} />
      )}
    </div>
  );
});

/// Text selected inside this message, if any. Right-clicking a highlighted
/// quote should still copy the quote, not the whole message.
function selectionIn(row: Node | null) {
  const selection = window.getSelection();
  const text = selection?.toString() ?? "";
  if (!text.trim() || !row || !selection?.anchorNode) return "";
  return row.contains(selection.anchorNode) ? text : "";
}

/// What the run behind a reply cost, sitting in the reply's own header: which
/// runtime, how long, and the way into the full trace. Live runs say nothing
/// here — the pill above the composer is already saying it.
function RunMeta({ run }: { run: Run }) {
  const { inspect } = useNavigation();
  if (!["succeeded", "failed", "cancelled"].includes(run.status)) return null;
  return (
    <button
      className={`message-run${run.status === "failed" ? " failed" : ""}`}
      title="Open the run"
      onClick={() => inspect({ kind: "run", runId: run.id })}
    >
      <RunIcon size={11} />
      {run.status === "cancelled" ? "stopped" : run.runtime}
      <span className="sep">·</span>
      {duration(run.started_at, run.ended_at)}
    </button>
  );
}

/// An image someone dropped in should be visible without a download step.
export function Attached({ attachment }: { attachment: Attachment }) {
  const api = useApi();
  const image = attachment.mime.startsWith("image/");
  const url = useFileUrl(image ? attachment.url : "");
  const [broken, setBroken] = useState(false);

  if (image && !broken) {
    if (!url) return <span className="attachment-chip">Loading image…</span>;
    return (
      <a href={url} target="_blank" rel="noreferrer noopener" className="image-attachment">
        <img src={url} alt={attachment.file_name} onError={() => setBroken(true)} />
      </a>
    );
  }
  return (
    <AttachmentRow
      fileName={attachment.file_name}
      size={attachment.size}
      onOpen={() => void api.openFile(attachment.url)}
    />
  );
}

/// One line above the composer for "somebody or something is busy" — typing
/// humans first, then the agents actually working in this conversation.
function WorkingPill({ channelId }: { channelId: Id }) {
  const { typingHere, me, members, runs } = useAppSelector((data) => ({
    typingHere: data.typing[channelId],
    me: data.me,
    members: data.members,
    runs: data.runs,
  }));
  const api = useApi();
  const { inspect } = useNavigation();
  const [, force] = useState(0);

  const typing = Object.entries(typingHere ?? {})
    .filter(([id, at]) => id !== me?.id && Date.now() - at < TYPING_TTL)
    .map(([id]) => members.find((member) => member.id === id)?.display_name)
    .filter(Boolean) as string[];

  // "X is typing" is the one thing here that goes stale on its own, so it is
  // the only thing worth a timer — and only until the last entry has expired.
  // The previous version ticked once a second and a half for the life of the
  // app, waking React in every open conversation to redraw nothing.
  const newestTyping = Math.max(0, ...Object.values(typingHere ?? {}));
  useEffect(() => {
    if (typing.length === 0) return;
    const remaining = newestTyping + TYPING_TTL - Date.now();
    if (remaining <= 0) return;
    const timer = window.setTimeout(() => force((n) => n + 1), remaining + 50);
    return () => window.clearTimeout(timer);
  }, [typing.length, newestTyping]);

  const working = Object.values(runs)
    .filter(
      (run) =>
        run.channel_id === channelId &&
        ["running", "dispatched", "queued", "waiting"].includes(run.status),
    )
    .map((run) => ({
      run,
      agent: members.find((member) => member.id === run.agent_id),
    }));

  // Slack's line, not a badge: who, what they are doing, and three dots.
  let content: React.ReactNode = null;
  if (typing.length > 0) {
    content = (
      <>
        <span className="who">{typing.join(", ")}</span>
        <span className="what">
          {typing.length === 1 ? "is typing" : "are typing"}
        </span>
        <TypingDots />
      </>
    );
  } else if (working.length === 1) {
    const { run, agent } = working[0];
    content = (
      <>
        <Avatar member={agent} size={16} />
        <span className="who">{agent?.display_name}</span>
        <span className="what">{run.headline || busyWord(run.status)}</span>
        <TypingDots />
        {/* The only place these live now, so they are always reachable while
            something is actually happening. */}
        <button
          className="pill-action"
          onClick={() => inspect({ kind: "run", runId: run.id })}
        >
          Details
        </button>
        <button className="pill-action" onClick={() => api.cancelRun(run.id)}>
          Stop
        </button>
      </>
    );
  } else if (working.length > 1) {
    content = (
      <>
        <span className="who">{working.length} agents</span>
        <span className="what">are working</span>
        <TypingDots />
      </>
    );
  }

  return content ? <div className="typing-line">{content}</div> : null;
}

function TypingDots() {
  return (
    <span className="typing-dots" aria-hidden>
      <i />
      <i />
      <i />
    </span>
  );
}

function busyWord(status: string) {
  return status === "waiting" ? "is waiting for you" : "is working";
}

/// Files on their way into a message: uploaded the moment they are chosen, so
/// sending is only ever a list of ids.
///
/// Shared by the message composer and the run control box: one upload path,
/// one row of chips, one place that knows what to do with a paste.
export function useAttachments({
  incoming,
  onConsumed,
  taskId,
}: {
  /// Files dropped anywhere in the surrounding surface, not just on the box.
  incoming?: File[];
  onConsumed?: () => void;
  /// A screenshot dropped in a task discussion is evidence for the task as
  /// well as for the message, and one upload should be both.
  taskId?: Id;
} = {}) {
  const api = useApi();
  const [pending, setPending] = useState<Attachment[]>([]);
  const [uploading, setUploading] = useState(0);

  const attach = useCallback(
    async (files: FileList | File[]) => {
      const list = Array.from(files);
      if (list.length === 0) return;
      setUploading((n) => n + list.length);
      try {
        for (const file of list) {
          try {
            const uploaded = await api.upload(file, taskId);
            setPending((current) => [...current, uploaded]);
          } finally {
            setUploading((n) => n - 1);
          }
        }
      } catch {
        setUploading(0);
      }
    },
    [api, taskId],
  );

  // Keyed on the array's identity, not its contents: a re-render for any other
  // reason must not upload the same drop a second time.
  const handled = useRef<File[] | null>(null);
  useEffect(() => {
    if (!incoming || incoming.length === 0 || handled.current === incoming) return;
    handled.current = incoming;
    void attach(incoming);
    onConsumed?.();
  }, [incoming, attach, onConsumed]);

  const strip =
    pending.length > 0 || uploading > 0 ? (
      <div className="composer-attachments">
        {pending.map((attachment) => (
          <PendingAttachment
            key={attachment.id}
            attachment={attachment}
            onRemove={() =>
              setPending((current) =>
                current.filter((item) => item.id !== attachment.id),
              )
            }
          />
        ))}
        {uploading > 0 && (
          <span className="attachment-chip">
            <Spinner size={13} />
            Uploading {uploading}
          </span>
        )}
      </div>
    ) : null;

  return {
    pending,
    uploading,
    attach,
    strip,
    clear: useCallback(() => setPending([]), []),
  };
}

/// The paperclip, wherever files can be added.
export function AttachButton({ onFiles }: { onFiles: (files: FileList) => void }) {
  return (
    <label className="icon-button" title="Attach files">
      <AttachIcon size={17} />
      <input
        type="file"
        multiple
        hidden
        onChange={(event) => {
          if (event.target.files) onFiles(event.target.files);
          event.target.value = "";
        }}
      />
    </label>
  );
}

interface ComposerProps {
  channel: Channel;
  parentId?: Id;
  placeholder?: string;
  /// Files dropped anywhere in the conversation, not just on the text box.
  incoming?: File[];
  onConsumed?: () => void;
  replyTo?: Message;
  onCancelReply?: () => void;
}

/// Drafts belong to one workspace, channel and optional thread. Attachments
/// stay ephemeral because an upload id cannot safely outlive the app.
const DRAFT_PREFIX = "patchwork.draft.";

export function Composer(props: ComposerProps) {
  const { workspaceId, memberId } = useAppSelector((data) => ({
    workspaceId: data.workspace?.id,
    memberId: data.me?.id,
  }));
  const draftKey = `${DRAFT_PREFIX}${workspaceId ?? ""}.${memberId ?? ""}.${
    props.channel.id
  }.${props.parentId ?? ""}`;
  // Remounting prevents one channel's or person's text using the next key.
  return <ComposerBox key={draftKey} draftKey={draftKey} {...props} />;
}

function ComposerBox({
  draftKey,
  channel,
  parentId,
  placeholder,
  incoming,
  onConsumed,
  replyTo,
  onCancelReply,
}: ComposerProps & { draftKey: string }) {
  const api = useApi();
  const { members, me } = useAppSelector((data) => ({
    members: data.members,
    me: data.me,
  }));
  const [text, setText] = useState(() => localStorage.getItem(draftKey) ?? "");
  const files = useAttachments({ incoming, onConsumed, taskId: channel.task_id });
  const [busy, setBusy] = useState(false);
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const box = useRef<HTMLTextAreaElement>(null);
  const wrap = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 240)}px`;
  }, [text]);

  useEffect(() => {
    if (replyTo) box.current?.focus();
  }, [replyTo?.id]);

  // Typing, dictation and mention completion all update this same value.
  useEffect(() => {
    if (text) localStorage.setItem(draftKey, text);
    else localStorage.removeItem(draftKey);
  }, [draftKey, text]);

  // The composer floats over the transcript, so the scroller behind it has to
  // know how tall it currently is — it grows with text, attachments and the
  // working pill.
  useEffect(() => {
    const element = wrap.current;
    const scroller = element?.parentElement;
    if (!element || !scroller) return;
    const observer = new ResizeObserver(() => {
      scroller.style.setProperty("--composer-h", `${element.offsetHeight}px`);
    });
    observer.observe(element);
    return () => {
      observer.disconnect();
      scroller.style.removeProperty("--composer-h");
    };
  }, []);

  const send = async () => {
    if (files.uploading > 0 || (!text.trim() && files.pending.length === 0)) return;
    setBusy(true);
    try {
      await api.send(channel.id, {
        body: text.trim(),
        parent_id: parentId,
        reply_to_id: replyTo?.id,
        attachment_ids: files.pending.map((attachment) => attachment.id),
      } as never);
      setText("");
      files.clear();
      onCancelReply?.();
    } finally {
      setBusy(false);
    }
  };

  const candidates =
    mentionQuery === null
      ? []
      : members
          .filter(
            (member) =>
              member.handle.startsWith(mentionQuery.toLowerCase()) &&
              member.id !== me?.id,
          )
          .slice(0, 6);

  const applyMention = (handle: string) => {
    setText((current) => current.replace(/@[\w-]*$/, `@${handle} `));
    setMentionQuery(null);
    box.current?.focus();
  };

  const onChange = (value: string) => {
    setText(value);
    const match = value.match(/@([\w-]*)$/);
    setMentionQuery(match ? match[1] : null);
    setMentionIndex(0);
    store.typing(channel.id);
  };

  // The same Return does a different thing depending on where the task is:
  // it feeds a live run, wakes an idle agent, or asks a person. The box says
  // which before it is pressed, and still sends an ordinary message.
  const taskLabel = useAppSelector((data) => {
    if (channel.kind !== "task" || !channel.task_id) return "";
    const task = data.tasks.find((candidate) => candidate.id === channel.task_id);
    if (!task) return "";
    const state = readTask(task, data.members, data.runs, data.questions);
    if (state.owner?.kind !== "agent") return "";
    switch (state.situation) {
      case "working":
      case "queued":
      case "asking":
        return `Feedback for ${state.owner.display_name}`;
      case "review":
        return "Request changes";
      case "done":
        return "Message this completed task";
      case "canceled":
        return "Message this canceled task";
      default:
        return `Send and resume ${state.owner.display_name}`;
    }
  });

  const label =
    placeholder ??
    (channel.kind === "channel"
      ? `Message #${channel.name}`
      : channel.kind === "task"
        ? taskLabel || "Message this task"
        : `Message ${channel.name}`);

  return (
    <div className="composer-wrap" ref={wrap}>
      {!parentId && <WorkingPill channelId={channel.id} />}

      {candidates.length > 0 && (
        <div className="mention-menu">
          {candidates.map((member, index) => (
            <button
              key={member.id}
              className={`row${index === mentionIndex ? " active" : ""}`}
              onMouseEnter={() => setMentionIndex(index)}
              onClick={() => applyMention(member.handle)}
            >
              <Avatar member={member} size={22} />
              <span className="grow">
                <span className="name">{member.display_name}</span>
                <span className="sub">
                  @{member.handle}
                  {member.kind === "agent" ? " · agent" : ""}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}

      <div className="composer">
        {replyTo && (
          <div className="composer-reply">
            <ReplyIcon size={14} />
            <span className="label">
              Replying to{" "}
              {members.find((member) => member.id === replyTo.author_id)?.display_name ??
                "Unknown"}
            </span>
            <span className="preview">
              {replyTo.body.trim() ||
                (replyTo.card ? replyTo.card.type.replaceAll("_", " ") : "Attachment")}
            </span>
            <button
              className="icon-button small"
              title="Cancel reply"
              aria-label="Cancel reply"
              onClick={onCancelReply}
            >
              <CloseIcon size={13} />
            </button>
          </div>
        )}
        {files.strip}
        <textarea
          ref={box}
          rows={1}
          // Opening a conversation means you are about to write in it. The box
          // remounts per channel and thread (see `draftKey`), so this fires on
          // every open, not only the first one.
          autoFocus
          // Prose, but prose full of paths and flags: check it, do not rewrite it.
          {...proseText}
          spellCheck
          placeholder={label}
          value={text}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (candidates.length > 0) {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setMentionIndex((index) => Math.min(index + 1, candidates.length - 1));
                return;
              }
              if (event.key === "ArrowUp") {
                event.preventDefault();
                setMentionIndex((index) => Math.max(index - 1, 0));
                return;
              }
              if (event.key === "Tab" || (event.key === "Enter" && !event.shiftKey)) {
                event.preventDefault();
                applyMention(candidates[mentionIndex].handle);
                return;
              }
              if (event.key === "Escape") {
                setMentionQuery(null);
                return;
              }
            }
            // Esc hands the keyboard back to navigation, and an empty box has no
            // caret for ↑ to move, so it does the same rather than nothing: the
            // arrows go back to walking the transcript and the sidebar.
            if (event.key === "Escape" || (!text && event.key === "ArrowUp")) {
              leaveComposer(event.currentTarget);
              return;
            }
            if (!text && event.key === "ArrowLeft" && movePane(-1)) return;
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              void send();
            }
          }}
          onPaste={(event) => {
            const pasted = Array.from(event.clipboardData.files);
            if (pasted.length === 0) return;
            event.preventDefault();
            void files.attach(pasted);
          }}
        />
        <DictateButton value={text} onText={onChange} />
        <div className="composer-row">
          <AttachButton onFiles={(picked) => void files.attach(picked)} />
          <span className="composer-hint">
            {text.includes("\n") ? "⇧↵ for a new line" : ""}
          </span>
          <span className="spacer" />
          <button
            className="send-button"
            disabled={
              busy || files.uploading > 0 || (!text.trim() && files.pending.length === 0)
            }
            onClick={send}
            title="Send"
          >
            <SendIcon size={16} />
          </button>
        </div>
      </div>

    </div>
  );
}

/// An image gets a thumbnail before it is sent, because "did I attach the right
/// screenshot" is a question you want answered before pressing Return.
function PendingAttachment({
  attachment,
  onRemove,
}: {
  attachment: Attachment;
  onRemove: () => void;
}) {
  const isImage = attachment.mime.startsWith("image/");
  const url = useFileUrl(isImage ? attachment.url : "");

  return (
    <span className={`pending-attachment${isImage ? " image" : ""}`}>
      {isImage ? (
        url ? <img src={url} alt={attachment.file_name} /> : <Spinner size={13} />
      ) : (
        <span className="file">
          <span className="name">{attachment.file_name}</span>
          <span className="size">{bytes(attachment.size)}</span>
        </span>
      )}
      <button className="remove" onClick={onRemove} title="Remove">
        <CloseIcon size={12} />
      </button>
    </span>
  );
}
