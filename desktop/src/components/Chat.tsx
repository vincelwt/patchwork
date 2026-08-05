import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { store, useApi, useAppSelector } from "../lib/store";
import { bytes, dayLabel, duration, timeOfDay } from "../lib/format";
import { useVirtualWindow } from "../lib/virtual";
import { Avatar, proseText, useNavigation } from "./common";
import {
  AttachIcon,
  CloseIcon,
  EventIcon,
  MoreIcon,
  PulseIcon,
  ReactIcon,
  RunIcon,
  SendIcon,
  Spinner,
  ThreadIcon,
} from "./icons";
import { AttachmentRow, Card } from "./Cards";
import { Markdown } from "./Markdown";
import { ReactionPicker, ReactionRow } from "./Reactions";
import type { Attachment, Channel, Id, Member, Message, Run } from "../lib/types";

export function ChatView({ channelId }: { channelId: Id }) {
  const { channel, messages } = useAppSelector((data) => ({
    channel: data.channels.find((candidate) => candidate.id === channelId),
    messages: data.messages[channelId],
  }));
  const [dropped, setDropped] = useState<File[]>([]);
  const clearDropped = useCallback(() => setDropped([]), []);

  useEffect(() => {
    void store.loadChannel(channelId);
  }, [channelId]);

  if (!channel) return <div className="empty">This conversation is gone.</div>;

  return (
    // Anywhere in the conversation is a drop target. Aiming for the text box is
    // a requirement invented by the implementation, not by the person holding
    // the file — they are dropping it *into this conversation*.
    <DropZone onFiles={(files) => setDropped(files)}>
      <Timeline channelId={channelId} messages={messages ?? []} />
      <Composer channel={channel} incoming={dropped} onConsumed={clearDropped} />
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
}: {
  channelId: Id;
  messages: Message[];
}) {
  const { members, runs, hasMore } = useAppSelector((data) => ({
    members: data.members,
    runs: data.runs,
    hasMore: !!data.hasMore[channelId],
  }));
  const handles = useHandles();
  const scroller = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  const atBottom = useRef(true);
  const window_ = useVirtualWindow(scroller, messages.length);

  // Following the conversation means following the last message as it *grows*,
  // not only when a new one arrives: a streamed reply adds no rows to the list.
  const tail = messages[messages.length - 1];
  const pin = useCallback(() => {
    const element = scroller.current;
    if (element && atBottom.current) element.scrollTop = element.scrollHeight;
  }, [scroller]);

  useEffect(pin, [messages.length, tail?.body.length, channelId, pin]);

  // Images decode, code blocks reflow and measured rows settle *after* the
  // first paint, so a single scrollTop assignment lands short of the bottom.
  // Watching the content box is the only version that ends up in the right
  // place regardless of what is still arriving.
  useEffect(() => {
    const element = inner.current;
    if (!element) return;
    const observer = new ResizeObserver(pin);
    observer.observe(element);
    return () => observer.disconnect();
  }, [pin]);

  const onScroll = () => {
    const element = scroller.current;
    if (!element) return;
    atBottom.current =
      element.scrollHeight - element.scrollTop - element.clientHeight < 80;
    if (element.scrollTop < 60 && hasMore) {
      const previousHeight = element.scrollHeight;
      void store.loadOlder(channelId).then(() => {
        requestAnimationFrame(() => {
          if (scroller.current) {
            scroller.current.scrollTop =
              scroller.current.scrollHeight - previousHeight;
          }
        });
      });
    }
  };

  // Day markers and grouping are decided for the whole list, not for the
  // visible slice — otherwise scrolling would change where the dividers fall.
  const rows = useMemo(() => {
    let previousDay: string | undefined;
    return messages.map((message, index) => {
      const previous = messages[index - 1];
      const day = dayLabel(message.created_at);
      const showDay = day !== previousDay;
      previousDay = day;
      return {
        message,
        day: showDay ? day : undefined,
        grouped: !showDay && groupsWithPrevious(message, previous),
      };
    });
  }, [messages]);

  // Which message a run is currently writing into. Working this out inside
  // each row meant every visible row scanning the whole channel on every
  // event — quadratic, in the one place that updates most often.
  const lastOfRun = useMemo(() => {
    const map = new Map<Id, Id>();
    for (const message of messages) {
      if (message.run_id) map.set(message.run_id, message.id);
    }
    return map;
  }, [messages]);

  const authorOf = useMemo(() => {
    const map = new Map<Id, Member>();
    for (const member of members) map.set(member.id, member);
    return map;
  }, [members]);

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
    <div className="timeline" ref={scroller} onScroll={onScroll}>
      <div className="timeline-inner" ref={inner}>
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
          if (folded) return <div key={message.id} ref={window_.rowRef(index)} />;
          return (
            <div key={message.id} ref={window_.rowRef(index)}>
              {row.day && (
                <div className="day-marker">
                  <span>{row.day}</span>
                </div>
              )}
              <MessageRow
                message={message}
                grouped={row.grouped}
                author={authorOf.get(message.author_id)}
                handles={handles}
                run={run}
                streaming={
                  message.kind === "text" &&
                  !!run &&
                  lastOfRun.get(run.id) === message.id &&
                  (run.status === "running" || run.status === "dispatched")
                }
              />
            </div>
          );
        })}
        {window_.padBottom > 0 && <div style={{ height: window_.padBottom }} />}
      </div>
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
  streaming = false,
}: {
  message: Message;
  grouped: boolean;
  author?: Member;
  handles?: Set<string>;
  /// The run that produced this message, summarised in its header.
  run?: Run;
  /// The reply the relay is still writing into.
  streaming?: boolean;
}) {
  const api = useApi();
  const { inspect } = useNavigation();
  const [picker, setPicker] = useState<{ x: number; y: number } | null>(null);

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

  return (
    <div
      className={`message message-${message.kind}${grouped ? " grouped" : ""}${
        selfAttributed ? " bare" : ""
      }`}
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
        {message.body && (
          <div className="message-body">
            <Markdown body={message.body} handles={handles} />
            {streaming && <span className="caret" />}
          </div>
        )}
        {message.card && <Card card={message.card} />}
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
        <button
          className="icon-button small"
          title="Reply in thread"
          onClick={() => inspect({ kind: "thread", messageId: message.id })}
        >
          <ThreadIcon size={16} />
        </button>
        <button
          className="icon-button small"
          title="Copy text"
          onClick={() => void navigator.clipboard.writeText(message.body)}
        >
          <MoreIcon size={16} />
        </button>
      </div>

      {picker && (
        <ReactionPicker at={picker} onPick={react} onClose={() => setPicker(null)} />
      )}
    </div>
  );
});

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
function Attached({ attachment }: { attachment: Attachment }) {
  const api = useApi();
  const url = `${api.baseUrl.replace(/\/$/, "")}${attachment.url}`;
  const [broken, setBroken] = useState(false);

  if (attachment.mime.startsWith("image/") && !broken) {
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
      url={url}
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

export function Composer({
  channel,
  parentId,
  placeholder,
  incoming,
  onConsumed,
}: {
  channel: Channel;
  parentId?: Id;
  placeholder?: string;
  /// Files dropped anywhere in the conversation, not just on the text box.
  incoming?: File[];
  onConsumed?: () => void;
}) {
  const api = useApi();
  const { members, me } = useAppSelector((data) => ({
    members: data.members,
    me: data.me,
  }));
  const [text, setText] = useState("");
  const [pending, setPending] = useState<Attachment[]>([]);
  const [busy, setBusy] = useState(false);
  const [uploading, setUploading] = useState(0);
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

  const attach = useCallback(
    async (files: FileList | File[]) => {
      const list = Array.from(files);
      if (list.length === 0) return;
      setUploading((n) => n + list.length);
      try {
        for (const file of list) {
          try {
            const uploaded = await api.upload(file);
            setPending((current) => [...current, uploaded]);
          } finally {
            setUploading((n) => n - 1);
          }
        }
      } catch {
        setUploading(0);
      }
    },
    [api],
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

  const send = async () => {
    if (!text.trim() && pending.length === 0) return;
    setBusy(true);
    try {
      await api.send(channel.id, {
        body: text.trim(),
        parent_id: parentId,
        attachment_ids: pending.map((attachment) => attachment.id),
      } as never);
      setText("");
      setPending([]);
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

  const label =
    placeholder ??
    (channel.kind === "channel"
      ? `Message #${channel.name}`
      : channel.kind === "task"
        ? "Message this task"
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
        {(pending.length > 0 || uploading > 0) && (
          <div className="composer-attachments">
            {pending.map((attachment) => (
              <PendingAttachment
                key={attachment.id}
                attachment={attachment}
                onRemove={() =>
                  setPending(pending.filter((item) => item.id !== attachment.id))
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
        )}
        <textarea
          ref={box}
          rows={1}
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
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              void send();
            }
          }}
          onPaste={(event) => {
            const files = Array.from(event.clipboardData.files);
            if (files.length === 0) return;
            event.preventDefault();
            void attach(files);
          }}
        />
        <div className="composer-row">
          <label className="icon-button" title="Attach files">
            <AttachIcon size={17} />
            <input
              type="file"
              multiple
              hidden
              onChange={(event) => {
                if (event.target.files) void attach(event.target.files);
                event.target.value = "";
              }}
            />
          </label>
          <span className="composer-hint">
            {text.includes("\n") ? "⇧↵ for a new line" : ""}
          </span>
          <span className="spacer" />
          <button
            className="send-button"
            disabled={busy || (!text.trim() && pending.length === 0)}
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
  const api = useApi();
  const url = `${api.baseUrl.replace(/\/$/, "")}${attachment.url}`;
  const isImage = attachment.mime.startsWith("image/");

  return (
    <span className={`pending-attachment${isImage ? " image" : ""}`}>
      {isImage ? (
        <img src={url} alt={attachment.file_name} />
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
