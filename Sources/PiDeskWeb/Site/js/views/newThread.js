import { h } from "../dom.js";
import { describeError } from "../api.js";

const MODES = ["xfast", "fast", "smart", "ultra"];

/**
 * There is no "list recent folders" endpoint in docs/daemon-api.md, so "recent working
 * directory" is derived client-side from the `cwd` of already-known threads (most recently
 * updated first) — the picker is "recent, or type any path", which is what the documented
 * contract actually supports.
 */
function recentCwds(threads) {
  const seen = new Set();
  const ordered = [...threads].sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  const result = [];
  for (const thread of ordered) {
    if (thread.cwd && !seen.has(thread.cwd)) {
      seen.add(thread.cwd);
      result.push(thread.cwd);
    }
  }
  return result.slice(0, 8);
}

function folderName(cwd) {
  const parts = cwd.split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : cwd;
}

export function renderNewThread(state, actions) {
  const cwdInput = h("input", {
    type: "text",
    name: "cwd",
    id: "new-cwd",
    required: true,
    placeholder: "/Users/you/code/project",
    "aria-describedby": "new-cwd-hint"
  });
  // A dedicated wrapper (not the chips themselves) so `paintChips` can freely replace its
  // contents — including going from "no chips yet" to populated once threads finish loading,
  // which happens on a direct/deep-link visit to this route before the list view has ever run.
  const chipRow = h("div", { class: "chip-row", role: "group", "aria-label": "Recent folders", hidden: true });

  function paintChips(threads) {
    const recents = recentCwds(threads);
    chipRow.hidden = recents.length === 0;
    const chips = recents.map((cwd) =>
      h(
        "button",
        {
          type: "button",
          class: "chip",
          "aria-pressed": String(cwd === cwdInput.value),
          onclick: (event) => {
            cwdInput.value = cwd;
            chipRow.querySelectorAll(".chip").forEach((chip) => chip.setAttribute("aria-pressed", String(chip === event.currentTarget)));
          }
        },
        folderName(cwd)
      )
    );
    chipRow.replaceChildren(...chips);
    // Only pre-fill the most-recent folder while the field is still untouched, so data arriving
    // late never clobbers something the user already typed.
    if (!cwdInput.value && recents[0]) cwdInput.value = recents[0];
  }
  paintChips(state.threads);

  const modeButtons = MODES.map((mode) =>
    h(
      "button",
      {
        type: "button",
        "aria-pressed": "false",
        "data-mode": mode,
        onclick: (event) => {
          const willSelect = event.currentTarget.getAttribute("aria-pressed") !== "true";
          modeButtons.forEach((btn) => btn.setAttribute("aria-pressed", String(btn === event.currentTarget && willSelect)));
        }
      },
      mode
    )
  );

  const nameInput = h("input", { id: "new-name", type: "text", name: "name", placeholder: "Untitled", autocomplete: "off" });
  const messageInput = h("textarea", { id: "new-message", name: "message", rows: "3", placeholder: "Leave blank to create an idle thread" });
  const errorBox = h("div", { class: "inline-error", role: "alert", hidden: true });
  const submit = h("button", { class: "btn btn-primary btn-block", type: "submit" }, "Create thread");

  const form = h(
    "form",
    {
      class: "content-pad",
      onsubmit: (event) => {
        event.preventDefault();
        const cwd = cwdInput.value.trim();
        if (!cwd) return;
        const mode = modeButtons.find((btn) => btn.getAttribute("aria-pressed") === "true");
        errorBox.hidden = true;
        submit.disabled = true;
        submit.textContent = "Creating\u2026";
        actions
          .createThread({
            cwd,
            name: nameInput.value.trim() || undefined,
            message: messageInput.value.trim() || undefined,
            mode: mode ? mode.dataset.mode : undefined
          })
          .catch((err) => {
            errorBox.hidden = false;
            errorBox.textContent = describeError(err);
          })
          .finally(() => {
            submit.disabled = false;
            submit.textContent = "Create thread";
          });
      }
    },
    h(
      "div",
      { class: "field" },
      h("label", { for: "new-cwd" }, "Working directory"),
      chipRow,
      cwdInput,
      h("div", { class: "field-hint", id: "new-cwd-hint" }, "Pick a recent folder or type any path on the Mac.")
    ),
    h("div", { class: "field" }, h("label", { for: "new-name" }, "Name (optional)"), nameInput),
    h(
      "div",
      { class: "field" },
      h("label", null, "Mode (optional)"),
      h("div", { class: "segmented", role: "group", "aria-label": "Mode" }, modeButtons)
    ),
    h("div", { class: "field" }, h("label", { for: "new-message" }, "First message (optional)"), messageInput),
    errorBox,
    submit
  );

  const node = h(
    "div",
    { class: "screen" },
    h(
      "header",
      { class: "topbar" },
      h("button", { class: "icon-btn", "aria-label": "Back", onclick: () => actions.navigate("/") }, "\u2039"),
      h("h1", { tabindex: "-1" }, "New thread")
    ),
    h("div", { class: "scroll" }, form)
  );

  return { node, onStateChange: (next) => paintChips(next.threads) };
}
