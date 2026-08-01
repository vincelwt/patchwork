import { h } from "../dom.js";
import { describeError } from "../api.js";

/**
 * The sign-in gate. `actions.connect(token)` validates against `GET /v1/health` and rejects with
 * the ApiError/NetworkError on failure, which this view shows inline without ever logging it.
 */
export function renderTokenScreen(state, actions) {
  const errorBox = h("div", { class: "inline-error", role: "alert", hidden: true });
  const input = h("input", {
    id: "token-input",
    name: "token",
    type: "password",
    inputmode: "text",
    autocomplete: "off",
    autocapitalize: "off",
    spellcheck: "false",
    required: true,
    placeholder: "Paste your token"
  });
  const submit = h("button", { class: "btn btn-primary btn-block", type: "submit" }, "Connect");

  const form = h(
    "form",
    {
      onsubmit: (event) => {
        event.preventDefault();
        const token = input.value.trim();
        if (!token) return;
        errorBox.hidden = true;
        submit.disabled = true;
        submit.textContent = "Connecting…";
        actions
          .connect(token)
          .catch((err) => {
            errorBox.hidden = false;
            errorBox.textContent = describeError(err);
          })
          .finally(() => {
            submit.disabled = false;
            submit.textContent = "Connect";
          });
      }
    },
    h("div", { class: "field" }, h("label", { for: "token-input" }, "Bearer token"), input),
    errorBox,
    submit
  );

  const node = h(
    "div",
    { class: "token-screen" },
    h("h1", { tabindex: "-1" }, "Patchwork"),
    h(
      "p",
      null,
      "Enter the token from ",
      h("code", null, "patchwork remote token"),
      " on your Mac, or ",
      h("code", null, "cat ~/Library/Application\u00A0Support/Pi\u00A0Desktop/daemon-token"),
      "."
    ),
    form
  );

  return { node };
}
