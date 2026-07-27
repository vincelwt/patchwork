import { h, mount } from "../dom.js";

// One dialog a daemon run is currently blocked on: an `ask_user_question` step, a permission
// prompt, or anything else Pi asked for over `extension_ui_request`.
//
// Two rules shape everything here:
//   1. Nothing is ever answered on the reader's behalf. There is no default selection, no
//      auto-submit, and no implicit "OK"; the only actions are ones a person took.
//   2. A dialog this build cannot render must still be *visible and escapable*. Pi is blocked
//      until it gets an answer, so an unknown method or an empty option list degrades to a card
//      that says so and offers Cancel, never to a silently skipped request.
//
// Values are submitted exactly as Pi offered them (`choices[].value`), so no option encoding is
// reconstructed on this side: a single-select answer is the raw option string, and a multi-select
// answer is the comma-separated 1-based index list the questionnaire plugin reads.

const ANSWERABLE = new Set(["select", "confirm", "input", "editor"]);

export function renderInteraction(interaction, { respond, describeError }) {
  const errorEl = h("div", { class: "inline-error", role: "alert", hidden: true });
  const body = h("div", { class: "interaction-body" });
  const actionsEl = h("div", { class: "interaction-actions" });

  const step =
    Number.isInteger(interaction.questionIndex) && Number.isInteger(interaction.questionCount)
      ? `Question ${interaction.questionIndex + 1} of ${interaction.questionCount}`
      : null;

  const node = h(
    "section",
    { class: "interaction", "aria-label": interaction.title || "Pi is asking" },
    h(
      "header",
      { class: "interaction-head" },
      h("span", { class: "interaction-chip" }, interaction.header || "Pi needs an answer"),
      step ? h("span", { class: "interaction-step" }, step) : null
    ),
    h("h2", { class: "interaction-title" }, interaction.title || "Pi is asking"),
    interaction.message ? h("p", { class: "interaction-message" }, interaction.message) : null,
    body,
    errorEl,
    actionsEl
  );

  let busy = false;

  function send(payload) {
    if (busy) return;
    busy = true;
    errorEl.hidden = true;
    node.setAttribute("aria-busy", "true");
    for (const control of node.querySelectorAll("button, input, textarea")) control.disabled = true;
    respond(payload).catch((err) => {
      busy = false;
      node.removeAttribute("aria-busy");
      for (const control of node.querySelectorAll("button, input, textarea")) control.disabled = false;
      errorEl.hidden = false;
      errorEl.textContent = describeError(err);
    });
  }

  const cancelBtn = h("button", { class: "btn", type: "button", onclick: () => send({ cancelled: true }) }, "Cancel");
  const method = interaction.method;
  const choices = Array.isArray(interaction.choices) && interaction.choices.length
    ? interaction.choices
    : (interaction.options || []).map((value, index) => ({ id: index, value, label: value }));

  if (method === "confirm") {
    mount(body, h("p", { class: "interaction-hint" }, "Answer on this device to let the run continue."));
    mount(actionsEl, [
      h("button", { class: "btn btn-primary", type: "button", onclick: () => send({ confirmed: true }) }, "Yes"),
      h("button", { class: "btn", type: "button", onclick: () => send({ confirmed: false }) }, "No"),
      cancelBtn
    ]);
  } else if (method === "select" && choices.length) {
    // A radio group, not a list of buttons: one tap must select, a second must submit, so a
    // mis-tap on a phone is recoverable instead of instantly answering for the reader.
    const name = `opt-${interaction.id}`;
    const submitBtn = h("button", { class: "btn btn-primary", type: "submit", disabled: true }, "Submit");
    const form = h(
      "form",
      {
        class: "interaction-options",
        role: "radiogroup",
        "aria-label": interaction.title || "Options",
        onsubmit: (event) => {
          event.preventDefault();
          const checked = form.querySelector("input:checked");
          if (checked) send({ value: checked.value });
        },
        onchange: () => {
          submitBtn.disabled = !form.querySelector("input:checked");
        }
      },
      choices.map((choice) => optionRow({ type: "radio", name, choice })),
      h("div", { class: "interaction-actions" }, submitBtn, cancelBtn)
    );
    mount(body, form);
  } else if (method === "input" && interaction.multiSelect && choices.length) {
    // The questionnaire plugin models a multi-select question as a typed `input` whose value is a
    // comma-separated 1-based index list. Checkboxes produce that string, so the reader never has
    // to know the encoding — and the free-text field below stays available for "none of these"
    // or an answer that is not on the list.
    const name = `opt-${interaction.id}`;
    const custom = h("input", {
      type: "text",
      class: "interaction-custom",
      "aria-label": "Type your own answer instead",
      placeholder: interaction.placeholder || "Or type your own answer"
    });
    const form = h(
      "form",
      {
        class: "interaction-options",
        "aria-label": interaction.title || "Options",
        onsubmit: (event) => {
          event.preventDefault();
          const typed = custom.value.trim();
          if (typed) return send({ value: typed });
          const selected = [...form.querySelectorAll("input[type=checkbox]:checked")].map((input) => input.value);
          // An empty multi-select is a real answer ("none of these"), which the plugin reads as
          // an empty input; it is the reader's choice, not a missing one.
          send({ value: selected.join(",") });
        }
      },
      choices.map((choice) => optionRow({ type: "checkbox", name, choice })),
      custom,
      h(
        "div",
        { class: "interaction-actions" },
        h("button", { class: "btn btn-primary", type: "submit" }, "Submit"),
        cancelBtn
      )
    );
    mount(body, form);
  } else if (method === "input" || method === "editor") {
    const field =
      method === "editor"
        ? h("textarea", { class: "interaction-text", rows: "6", "aria-label": interaction.title || "Answer" })
        : h("input", { type: "text", class: "interaction-text", "aria-label": interaction.title || "Answer" });
    if (interaction.placeholder) field.setAttribute("placeholder", interaction.placeholder);
    if (interaction.prefill) field.value = interaction.prefill;
    const form = h(
      "form",
      {
        class: "interaction-form",
        onsubmit: (event) => {
          event.preventDefault();
          send({ value: field.value });
        }
      },
      field,
      h(
        "div",
        { class: "interaction-actions" },
        h("button", { class: "btn btn-primary", type: "submit" }, "Submit"),
        cancelBtn
      )
    );
    mount(body, form);
  } else {
    // Either a method this build has never seen, or a known one whose payload cannot be answered
    // here (a `select` with no options). Say so plainly and leave exactly one safe way out.
    mount(
      body,
      h(
        "p",
        { class: "interaction-hint" },
        ANSWERABLE.has(method)
          ? "This prompt arrived without any options, so it cannot be answered here. Open the thread on your Mac, or cancel it."
          : "This kind of prompt needs the Mac app. Answer it there, or cancel it to let the run continue."
      )
    );
    mount(actionsEl, cancelBtn);
  }

  return node;
}

function optionRow({ type, name, choice }) {
  const input = h("input", { type, name, value: choice.value });
  return h(
    "label",
    { class: "interaction-option" },
    input,
    h(
      "span",
      { class: "interaction-option-text" },
      h("span", { class: "interaction-option-label" }, choice.label),
      choice.description ? h("span", { class: "interaction-option-desc" }, choice.description) : null,
      choice.preview ? h("pre", { class: "interaction-option-preview" }, choice.preview) : null
    )
  );
}
