import { useEffect, useMemo, useRef, useState } from "react";
import { store, useApi, useApp } from "../lib/store";
import { dayLabel, timeOfDay } from "../lib/format";
import { Avatar, useNavigation } from "./common";
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
      <TypingLine channelId={channelId} />
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
            previous?.author_id === message.author_id &&
            previous.kind === message.kind &&
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

  return (
    <div className={`message ${message.kind}${grouped ? " grouped" : ""}`}>
      <div>{!grouped && <Avatar member={author} />}</div>
      <div>
        {!grouped && (
          <div className="message-head">
            <span className="message-author">{author?.display_name ?? "Unknown"}</span>
            {author?.kind === "agent" && (
              <span className="message-time">agent</span>
            )}
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
          QUICK_REACTIONS.map((emoji) => (
            <button
              key={emoji}
              className="icon-button"
              onClick={() => {
                void api.react(message.id, emoji);
                setShowReactions(false);
              }}
            >
              {emoji}
            </button>
          ))
        ) : (
          <button
            className="icon-button"
            title="React"
            onClick={() => setShowReactions(true)}
          >
            ☺
          </button>
        )}
        <button
          className="icon-button"
          title="Reply in thread"
          onClick={() => inspect({ kind: "thread", messageId: message.id })}
        >
          ⤷
        </button>
      </div>
    </div>
  );
}

/// Mentions are highlighted; everything else stays plain text so an agent's
/// prose reads the way it was written.
function Body({ body, members }: { body: string; members: Member[] }) {
  const parts = useMemo(() => {
    const handles = members.map((member) => member.handle).sort((a, b) => b.length - a.length);
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

function TypingLine({ channelId }: { channelId: Id }) {
  const app = useApp();
  const [, force] = useState(0);

  useEffect(() => {
    const timer = window.setInterval(() => force((n) => n + 1), 1500);
    return () => window.clearInterval(timer);
  }, []);

  const typing = Object.entries(app.typing[channelId] ?? {})
    .filter(([id, at]) => id !== app.me?.id && Date.now() - at < 4000)
    .map(([id]) => app.members.find((member) => member.id === id)?.display_name)
    .filter(Boolean);

  const working = app.members.filter(
    (member) =>
      member.kind === "agent" &&
      (member.presence === "working" || member.presence === "thinking"),
  );

  return (
    <div className="typing-line">
      {typing.length > 0
        ? `${typing.join(", ")} ${typing.length === 1 ? "is" : "are"} typing…`
        : working.length > 0
          ? `${working.map((agent) => agent.display_name).join(", ")} ${working.length === 1 ? "is" : "are"} working…`
          : ""}
    </div>
  );
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

  const resize = () => {
    const element = box.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${Math.min(element.scrollHeight, 220)}px`;
  };

  useEffect(resize, [text]);

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

  const candidates = app.members.filter((member) =>
    mentionQuery === null
      ? false
      : member.handle.startsWith(mentionQuery.toLowerCase()) &&
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
      : `Message ${channel.name}`);

  return (
    <div className="composer-wrap">
      {candidates.length > 0 && (
        <div className="card" style={{ marginBottom: 6 }}>
          {candidates.slice(0, 6).map((member) => (
            <button
              key={member.id}
              className="row"
              style={{ width: "100%" }}
              onClick={() => applyMention(member.handle)}
            >
              <Avatar member={member} size={20} />
              <span className="grow">
                <span className="name">{member.display_name}</span>{" "}
                <span className="sub">@{member.handle}</span>
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
                  className="icon-button"
                  style={{ width: 18, height: 18 }}
                  onClick={() =>
                    setPending(pending.filter((item) => item.id !== attachment.id))
                  }
                >
                  ×
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
          <label className="button quiet">
            Attach
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
          <span className="composer-hint">Enter to send</span>
          <button className="button primary" disabled={busy} onClick={send}>
            Send
          </button>
        </div>
      </div>
    </div>
  );
}
