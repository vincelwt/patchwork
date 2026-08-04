// Reacting to a message, and seeing who did.
//
// A row of three fixed emoji was not a reaction feature, it was a placeholder.
// This is the small honest version: the ones you actually reach for on top,
// a searchable set behind them, and — the part that makes reactions worth
// having at all — the names of the people behind each one.

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useApi, useApp } from "../lib/store";
import { SearchIcon } from "./icons";
import type { Message, Reaction } from "../lib/types";

/// Small on purpose. A full Unicode set needs a data file and an index; this
/// covers what a working conversation reaches for, and search makes it usable.
const SETS: { name: string; emoji: [string, string][] }[] = [
  {
    name: "Reactions",
    emoji: [
      ["👍", "thumbs up yes agree"],
      ["👎", "thumbs down no disagree"],
      ["✅", "check done tick complete"],
      ["❌", "cross no wrong fail"],
      ["🎉", "tada party ship celebrate"],
      ["🙏", "thanks please pray"],
      ["👀", "eyes looking watching review"],
      ["🔥", "fire hot great"],
      ["💯", "hundred perfect"],
      ["🚀", "rocket ship launch deploy"],
      ["⚡", "zap fast quick"],
      ["🧠", "brain smart think"],
    ],
  },
  {
    name: "Feelings",
    emoji: [
      ["😄", "smile happy"],
      ["😅", "sweat nervous laugh"],
      ["😂", "joy laughing funny"],
      ["🙂", "slight smile fine"],
      ["😍", "love heart eyes"],
      ["🤔", "thinking hmm unsure"],
      ["😬", "grimace awkward yikes"],
      ["😭", "sob crying"],
      ["😱", "scream shock"],
      ["🤯", "mind blown exploding"],
      ["😴", "sleep tired bored"],
      ["🫠", "melting fine this is fine"],
    ],
  },
  {
    name: "Work",
    emoji: [
      ["🐛", "bug defect issue"],
      ["🔧", "wrench fix tool"],
      ["📝", "memo note docs write"],
      ["📌", "pin important"],
      ["🚢", "ship shipped release"],
      ["🧪", "test experiment lab"],
      ["🔒", "lock security private"],
      ["⏳", "hourglass waiting slow"],
      ["📈", "chart up growth"],
      ["📉", "chart down drop"],
      ["💸", "money cost spend"],
      ["☕", "coffee break"],
    ],
  },
];

/// The row above the picker: what this workspace reaches for most often, so
/// the common case is one click and no search.
const QUICK = ["👍", "✅", "🎉", "👀", "🙏", "🔥"];

export function ReactionPicker({
  at,
  onPick,
  onClose,
}: {
  at: { x: number; y: number };
  onPick: (emoji: string) => void;
  onClose: () => void;
}) {
  const root = useRef<HTMLDivElement>(null);
  const [query, setQuery] = useState("");

  useEffect(() => {
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) onClose();
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [onClose]);

  const needle = query.trim().toLowerCase();
  const sets = useMemo(
    () =>
      SETS.map((set) => ({
        name: set.name,
        emoji: set.emoji.filter(
          ([glyph, terms]) => !needle || terms.includes(needle) || glyph === needle,
        ),
      })).filter((set) => set.emoji.length > 0),
    [needle],
  );

  const width = 292;
  const height = 320;
  const style: React.CSSProperties = {
    position: "fixed",
    zIndex: 90,
    left: Math.min(Math.max(8, at.x - width / 2), window.innerWidth - width - 8),
    // Prefer above the message, the way the hover toolbar sits above it.
    top:
      at.y - height - 8 > 8 ? at.y - height - 8 : Math.min(at.y + 8, window.innerHeight - height - 8),
    width,
  };

  return createPortal(
    <div className="emoji-picker" ref={root} style={style}>
      <div className="emoji-quick">
        {QUICK.map((glyph) => (
          <button key={glyph} className="emoji" onClick={() => onPick(glyph)}>
            {glyph}
          </button>
        ))}
      </div>
      <div className="emoji-search">
        <SearchIcon size={15} />
        <input
          autoFocus
          spellCheck={false}
          placeholder="Search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              const first = sets[0]?.emoji[0]?.[0];
              if (first) onPick(first);
            }
          }}
        />
      </div>
      <div className="emoji-list">
        {sets.map((set) => (
          <div key={set.name}>
            <div className="emoji-group">{set.name}</div>
            <div className="emoji-grid">
              {set.emoji.map(([glyph]) => (
                <button key={glyph} className="emoji" onClick={() => onPick(glyph)}>
                  {glyph}
                </button>
              ))}
            </div>
          </div>
        ))}
        {sets.length === 0 && <div className="emoji-empty">Nothing matches that.</div>}
      </div>
    </div>,
    document.body,
  );
}

/// The pills under a message. Hovering one says who reacted, because "three
/// people agreed" is only useful when you know which three.
export function ReactionRow({
  message,
  onAdd,
}: {
  message: Message;
  onAdd: (at: { x: number; y: number }) => void;
}) {
  const app = useApp();
  const api = useApi();
  if (message.reactions.length === 0) return null;

  const who = (reaction: Reaction) => {
    const names = reaction.member_ids.map(
      (id) =>
        app.members.find((member) => member.id === id)?.display_name ?? "someone",
    );
    const mine = reaction.member_ids.includes(app.me?.id ?? "");
    const listed =
      names.length <= 3
        ? names.join(", ")
        : `${names.slice(0, 3).join(", ")} and ${names.length - 3} more`;
    return `${listed} reacted with ${reaction.emoji}${mine ? " — click to remove yours" : ""}`;
  };

  return (
    <div className="reactions">
      {message.reactions.map((reaction) => (
        <button
          key={reaction.emoji}
          className={`reaction${reaction.member_ids.includes(app.me?.id ?? "") ? " mine" : ""}`}
          title={who(reaction)}
          onClick={() => api.react(message.id, reaction.emoji)}
        >
          <span className="glyph">{reaction.emoji}</span>
          {reaction.member_ids.length}
        </button>
      ))}
      <button
        className="reaction add"
        title="Add a reaction"
        onClick={(event) => {
          const rect = event.currentTarget.getBoundingClientRect();
          onAdd({ x: rect.left + rect.width / 2, y: rect.top });
        }}
      >
        +
      </button>
    </div>
  );
}
