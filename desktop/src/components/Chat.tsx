import { useEffect, useMemo, useRef, useState } from "react";
import { store, useApi, useApp } from "../lib/store";
import { dayLabel, timeOfDay } from "../lib/format";
import { Avatar, useNavigation } from "./common";
import {
  AttachIcon,
  CloseIcon,
  EventIcon,
  PulseIcon,
  ReactIcon,
  SendIcon,
  Spinner,
  ThreadIcon,
} from "./icons";
import { AttachmentRow, Card } from "./Cards";
import type { Attachment, Channel, Id, Member, Message } from "../lib/types";

export function ChatView({ channelId }: { channelId: Id }) {
  const app = useApp();
  const channel = app.channels.find((candidate) => candidate.id === channelId);
  const messages = app.messages[channelId];

  useEffect(() => {
    void store.loadChannel(channelId);
  }, [channelId]);

  if (!channel) return <div className="empty">This conversation is gone.</div>;

  return (
    <div className="column">
      <Timeline channelId={channelId} messages={messages ?? []} />
      <Composer channel={channel} />
    </div>
  );
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
  const atBottom = useRef(true);

  useEffect(() => {
    const element = scroller.current;
    if (element && atBottom.current) {
      element.scrollTop = element.scrollHeight;
    }
  }, [messages.length, channelId]);

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

  let lastDay = "";
  let previous: Message | undefined;

  return (
    <div className="timeline" ref={scroller} onScroll={onScroll}>
      <div className="timeline-inner">
        {messages.length === 0 && (
          <div className="empty">
            Nothing here yet. Say something, or bring an agent in with @.
          </div>
        )}
        {messages.map((message) => {
          const day = dayLabel(message.created_at);
          const showDay = day !== lastDay;
          lastDay = day;
          const grouped =
            !showDay &&
            message.kind === "text" &&
            previous?.kind === "text" &&
            previous.author_id === message.author_id &&
            message.created_at - previous.created_at < 5 * 60_000;
          previous = message;
          return (
            <div key={message.id}>
              {showDay && <div className="day-marker">{day}</div>}
              <MessageRow message={message} grouped={grouped} />
            </div>
          );
        })}
      </div>
    </div>
  );
}

const QUICK_REACTIONS = ["👍", "🎉", "👀"];

export function MessageRow({
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
  const [showReactions, setShowReactions] = useState(false);

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

  return (
    <div className={`message message-${message.kind}${grouped ? " grouped" : ""}`}>
      <div>{!grouped && !selfAttributed && <Avatar member={author} size={26} />}</div>
      <div style={{ minWidth: 0 }}>
        {!grouped && !selfAttributed && (
          <div className="message-head">
            <span className="message-author">{author?.display_name ?? "Unknown"}</span>
            {author?.kind === "agent" && <span className="message-badge">agent</span>}
            <span className="message-time">{timeOfDay(message.created_at)}</span>
          </div>
        )}
        {message.body && (
          <div className="message-body">
            <Body body={message.body} members={app.members} />
          </div>
        )}
        {message.card && <Card card={message.card} />}
        {message.attachments.length > 0 && (
          <div className="card-row">
            {message.attachments.map((attachment: Attachment) => (
              <AttachmentRow
                key={attachment.id}
                fileName={attachment.file_name}
                size={attachment.size}
                url={`${api.baseUrl.replace(/\/$/, "")}${attachment.url}`}
              />
            ))}
          </div>
        )}
        {message.reactions.length > 0 && (
          <div className="reactions">
            {message.reactions.map((reaction) => (
              <button
                key={reaction.emoji}
                className={`reaction${reaction.member_ids.includes(app.me?.id ?? "") ? " mine" : ""}`}
                onClick={() => api.react(message.id, reaction.emoji)}
              >
                {reaction.emoji} {reaction.member_ids.length}
              </button>
            ))}
          </div>
        )}
        {message.reply_count > 0 && (
          <button
            className="thread-link"
            onClick={() => inspect({ kind: "thread", messageId: message.id })}
          >
            {message.reply_count} {message.reply_count === 1 ? "reply" : "replies"}
          </button>
        )}
      </div>

      <div className="message-actions">
        {showReactions ? (
          <>
            {QUICK_REACTIONS.map((emoji) => (
              <button
                key={emoji}
                className="icon-button small"
                onClick={() => {
                  void api.react(message.id, emoji);
                  setShowReactions(false);
                }}
              >
                {emoji}
              </button>
            ))}
            <button
              className="icon-button small"
              onClick={() => setShowReactions(false)}
            >
              <CloseIcon size={13} />
            </button>
          </>
        ) : (
          <>
            <button
              className="icon-button small"
              title="React"
              onClick={() => setShowReactions(true)}
            >
              <ReactIcon size={15} />
            </button>
            <button
              className="icon-button small"
              title="Reply in thread"
              onClick={() => inspect({ kind: "thread", messageId: message.id })}
            >
              <ThreadIcon size={15} />
            </button>
          </>
        )}
      </div>
    </div>
  );
}

/// Mentions are highlighted; everything else stays plain text so an agent's
/// prose reads the way it was written.
function Body({ body, members }: { body: string; members: Member[] }) {
  const parts = useMemo(() => {
    const handles = members
      .map((member) => member.handle)
      .sort((a, b) => b.length - a.length);
    if (handles.length === 0) return [body];
    const pattern = new RegExp(`@(${handles.map(escape).join("|")})\\b`, "g");
    const out: (string | { handle: string })[] = [];
    let index = 0;
    for (const match of body.matchAll(pattern)) {
      const at = match.index ?? 0;
      if (at > index) out.push(body.slice(index, at));
      out.push({ handle: match[1] });
      index = at + match[0].length;
    }
    out.push(body.slice(index));
    return out;
  }, [body, members]);

  return (
    <>
      {parts.map((part, index) =>
        typeof part === "string" ? (
          <span key={index}>{part}</span>
        ) : (
          <span className="mention" key={index}>
            @{part.handle}
          </span>
        ),
      )}
    </>
  );
}

function escape(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/// One line above the composer for "somebody or something is busy" — typing
/// humans first, then the agents actually working in this conversation.
function WorkingPill({ channelId }: { channelId: Id }) {
  const app = useApp();
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
        {agent?.display_name} · {run.headline || run.status}
      </span>
    );
  } else if (working.length > 1) {
    content = (
      <span>
        <Spinner size={13} />
        {working.length} agents working
      </span>
    );
  }

  return <div className="working-pill">{content}</div>;
}

export function Composer({
  channel,
  parentId,
  placeholder,
}: {
  channel: Channel;
  parentId?: Id;
  placeholder?: string;
}) {
  const api = useApi();
  const app = useApp();
  const [text, setText] = useState("");
  const [pending, setPending] = useState<Attachment[]>([]);
  const [busy, setBusy] = useState(false);
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const box = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    const element = box.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 240)}px`;
  }, [text]);

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
      : app.members.filter(
          (member) =>
            member.handle.startsWith(mentionQuery.toLowerCase()) &&
            member.id !== app.me?.id,
        );

  const applyMention = (handle: string) => {
    setText((current) => current.replace(/@[\w-]*$/, `@${handle} `));
    setMentionQuery(null);
    box.current?.focus();
  };

  const onChange = (value: string) => {
    setText(value);
    const match = value.match(/@([\w-]*)$/);
    setMentionQuery(match ? match[1] : null);
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
          {candidates.slice(0, 6).map((member) => (
            <button
              key={member.id}
              className="row"
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
        {pending.length > 0 && (
          <div className="composer-row">
            {pending.map((attachment) => (
              <span className="attachment-chip" key={attachment.id}>
                {attachment.file_name}
                <button
                  className="icon-button small"
                  onClick={() =>
                    setPending(pending.filter((item) => item.id !== attachment.id))
                  }
                >
                  <CloseIcon size={12} />
                </button>
              </span>
            ))}
          </div>
        )}
        <textarea
          ref={box}
          rows={1}
          placeholder={label}
          value={text}
          onChange={(event) => onChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              void send();
            }
          }}
          onPaste={async (event) => {
            const file = event.clipboardData.files[0];
            if (!file) return;
            event.preventDefault();
            setPending([...pending, await api.upload(file)]);
          }}
        />
        <div className="composer-row">
          <label className="icon-button" title="Attach a file">
            <AttachIcon size={17} />
            <input
              type="file"
              hidden
              onChange={async (event) => {
                const file = event.target.files?.[0];
                if (file) setPending([...pending, await api.upload(file)]);
                event.target.value = "";
              }}
            />
          </label>
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
