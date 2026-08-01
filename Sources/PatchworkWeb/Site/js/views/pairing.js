import { h, mount } from "../dom.js";

export function renderPairingScreen(state) {
  const body = h("div", { class: "pairing-body", role: "status", "aria-live": "polite" });
  const node = h(
    "div",
    { class: "token-screen pairing-screen" },
    h("div", { class: "pairing-mark", "aria-hidden": "true" }, "π"),
    h("h1", { tabindex: "-1" }, "Patchwork"),
    body
  );
  paint(body, state.relayPairing);
  return { node, onStateChange: (next) => paint(body, next.relayPairing) };
}

function paint(container, pairing) {
  const phase = pairing?.phase || "connecting";
  if (phase === "pending") {
    mount(container, [
      h("p", null, "Confirm this code on your Mac"),
      h("div", { class: "pairing-code", "aria-label": `Verification code ${pairing.verificationCode}` }, pairing.verificationCode),
      h("p", { class: "muted" }, "Keep this page open while you approve the device in Patchwork.")
    ]);
  } else if (phase === "paired") {
    mount(container, [h("span", { class: "spinner", "aria-hidden": "true" }), h("p", null, "Opening your conversations…")]);
  } else if (phase === "unpaired") {
    mount(container, [
      h("p", null, "Open Patchwork on your Mac and click the phone button in the sidebar."),
      h("p", { class: "muted" }, "Scan its QR code to pair this browser securely.")
    ]);
  } else if (phase === "error") {
    mount(container, [
      h("div", { class: "inline-error", role: "alert" }, pairing.message || "Pairing failed."),
      h("p", { class: "muted" }, "Generate a new code in Patchwork and scan it again.")
    ]);
  } else {
    mount(container, [h("span", { class: "spinner", "aria-hidden": "true" }), h("p", null, "Securing this device…")]);
  }
}
