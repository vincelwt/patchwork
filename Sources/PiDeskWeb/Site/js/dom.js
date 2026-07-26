// Tiny DOM-builder helper so views read declaratively without a framework. Text children always
// go through `document.createTextNode`, which the browser never interprets as markup — the only
// way HTML ever enters the tree here is the explicit `html` attribute, and the only caller of
// that is thread-view rendering with `renderMarkdown()` output (see js/markdown.mjs), never raw
// text directly.

/** Creates one element. `attrs.html`, if present, is trusted pre-escaped HTML (see above). */
export function h(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === "html") node.innerHTML = value;
    else if (key === "class") node.className = value;
    else if (key.startsWith("on") && typeof value === "function") {
      node.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (typeof value === "boolean") {
      if (value) node.setAttribute(key, "");
    } else {
      node.setAttribute(key, String(value));
    }
  }
  append(node, children.flat());
  return node;
}

function append(node, children) {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    node.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

/** Replaces `container`'s children with `node` (or a fragment of nodes). */
export function mount(container, node) {
  container.replaceChildren();
  append(container, Array.isArray(node) ? node.flat() : [node]);
}

export const qs = (selector, root = document) => root.querySelector(selector);
