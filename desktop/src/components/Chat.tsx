import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { store, useApi, useApp } from "../lib/store";
import { bytes, dayLabel, timeOfDay } from "../lib/format";
import { useVirtualWindow } from "../lib/virtual";
import { Avatar, useNavigation } from "./common";
import {
  AttachIcon,
  CloseIcon,
  EventIcon,
  MoreIcon,
  PulseIcon,
  ReactIcon,
  SendIcon,
  Spinner,
  ThreadIcon,
} from "./icons";
import { AttachmentRow, Card } from "./Cards";
import { Markdown } from "./Markdown";
import { ReactionPicker, ReactionRow } from "./Reactions";
import type { Attachment, Channel, Id, Message } from "../lib/types";

export function ChatView({ channelId }: { channelId: Id }) {
  const app = useApp();
  const channel = app.channels.find((candidate) => candidate.id === channelId);
  const messages = app.messages[channelId];
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
  const app = useApp();
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
    if (element.scrollTop < 60 && app.hasMore[channelId]) {
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
  const rows = useMemo(
    () =>
      messages.map((message, index) => {
        const previous = messages[index - 1];
        const day = dayLabel(message.created_at);
        const showDay = !previous || day !== dayLabel(previous.created_at);
        return {
          message,
          day: showDay ? day : undefined,
          grouped: !showDay && groupsWithPrevious(message, previous),
        };
      }),
    [messages],
  );

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
          return (
            <div key={row.message.id} ref={(el) => window_.measure(index, el)}>
              {row.day && (
                <div className="day-marker">
                  <span>{row.day}</span>
                </div>
              )}
              <MessageRow message={row.message} grouped={row.grouped} />
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
  const app = useApp();
  return useMemo(
    () => new Set(app.members.map((member) => member.handle.toLowerCase())),
    [app.members],
  );
}

export const MessageRow = memo(function MessageRow({
  message,
  grouped,
}: {
  message: Message;
  grouped: boolean;
}) {
  const app = useApp();
  const api = useApi();
  const { inspect } = useNavigation();
  const author = app.members.find((member) => member.id === message.author_id);
  const [picker, setPicker] = useState<{ x: number; y: number } | null>(null);
  const handles = useHandles();

  // A reply the relay is still rewriting: its run is going, and nothing newer
  // from that run has arrived.
  const run = message.run_id ? app.runs[message.run_id] : undefined;
  const siblings = app.messages[message.channel_id];
  const newestOfRun = useMemo(() => {
    if (!run || !siblings) return false;
    for (let index = siblings.length - 1; index >= 0; index -= 1) {
      if (siblings[index].run_id === run.id) return siblings[index].id === message.id;
    }
    return false;
  }, [siblings, run, message.id]);
  const streaming =
    newestOfRun &&
    message.kind === "text" &&
    ["running", "dispatched"].includes(run?.status ?? "");

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
  const app = useApp();
  const api = useApi();
  const { inspect } = useNavigation();
  const [, force] = useState(0);

  useEffect(() => {
    const timer = window.setInterval(() => force((n) => n + 1), 1500);
    return () => window.clearInterval(timer);
  }, []);

  const typing = Object.entries(app.typing[channelId] ?? {})
    .filter(([id, at]) => id !== app.me?.id && Date.now() - at < 4000)
    .map(([id]) => app.members.find((member) => member.id === id)?.display_name)
    .filter(Boolean) as string[];

  const working = Object.values(app.runs)
    .filter(
      (run) =>
        run.channel_id === channelId &&
        ["running", "dispatched", "queued", "waiting"].includes(run.status),
    )
    .map((run) => ({
      run,
      agent: app.members.find((member) => member.id === run.agent_id),
    }));

  let content: React.ReactNode = null;
  if (typing.length > 0) {
    content = (
      <span>
        {typing.join(", ")} {typing.length === 1 ? "is" : "are"} typing…
      </span>
    );
  } else if (working.length === 1) {
    const { run, agent } = working[0];
    content = (
      <span>
        <Spinner size={13} />
        <span className="what">
          {agent?.display_name} · {run.headline || run.status}
        </span>
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
      </span>
    );
  } else if (working.length > 1) {
    content = (
      <span>
        <Spinner size={13} />
        <span className="what">{working.length} agents working</span>
      </span>
    );
  }

  return <div className="working-pill">{content}</div>;
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
  const app = useApp();
  const [text, setText] = useState("");
  const [pending, setPending] = useState<Attachment[]>([]);
  const [busy, setBusy] = useState(false);
  const [uploading, setUploading] = useState(0);
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const box = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 240)}px`;
  }, [text]);

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
      : app.members
          .filter(
            (member) =>
              member.handle.startsWith(mentionQuery.toLowerCase()) &&
              member.id !== app.me?.id,
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
    <div className="composer-wrap">
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
