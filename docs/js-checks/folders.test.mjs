import test from "node:test";
import assert from "node:assert/strict";
import {
  buildThreadTree,
  flattenTree,
  folderIdFromGroupId,
  groupIdForFolder,
  isFlatList
} from "../../Sources/PiDeskWeb/Site/js/folders.mjs";

const thread = (id, cwd, extra = {}) => ({
  id,
  path: `/s/${id}.jsonl`,
  name: id,
  cwd,
  folder: cwd.split("/").pop(),
  updatedAt: "2026-01-01T00:00:00.000Z",
  ...extra
});

test("group ids round-trip and a project path is not a folder id", () => {
  assert.equal(groupIdForFolder("abc"), "virtual:abc");
  assert.equal(folderIdFromGroupId("virtual:abc"), "abc");
  assert.equal(folderIdFromGroupId("/Users/x/code"), null);
  assert.equal(folderIdFromGroupId(undefined), null);
});

test("no folder state at all degrades to plain project grouping", () => {
  const groups = buildThreadTree([thread("a", "/Users/x/code"), thread("b", "/Users/x/notes")], null);
  assert.deepEqual(groups.map((g) => g.name), ["code", "notes"]);
  assert.ok(groups.every((g) => g.kind === "project"));
  assert.equal(isFlatList(groups), false, "two projects are still worth grouping");

  const single = buildThreadTree([thread("a", "/Users/x/code")], { folders: [], assignments: {} });
  assert.equal(isFlatList(single), true, "one project and no folders needs no tree chrome");
});

test("assigned threads move into their folder and appear exactly once", () => {
  const threads = [thread("a", "/Users/x/code"), thread("b", "/Users/x/code")];
  const groups = buildThreadTree(threads, {
    folders: [{ id: "f1", name: "Review", parentId: null, depth: 0 }],
    assignments: { "/s/a.jsonl": "f1" }
  });

  const rows = flattenTree(groups);
  const threadIds = rows.filter((r) => r.kind === "thread").map((r) => r.thread.id);
  assert.deepEqual(threadIds.sort(), ["a", "b"]);
  assert.equal(groups[0].name, "Review");
  assert.deepEqual(groups[0].threads.map((t) => t.id), ["a"]);
  assert.deepEqual(groups[1].threads.map((t) => t.id), ["b"]);
});

test("an assignment naming an unknown folder falls back to the project group", () => {
  const groups = buildThreadTree([thread("a", "/Users/x/code")], {
    folders: [],
    assignments: { "/s/a.jsonl": "deleted-folder" }
  });
  assert.equal(groups.length, 1);
  assert.equal(groups[0].kind, "project");
  assert.deepEqual(groups[0].threads.map((t) => t.id), ["a"]);
});

test("an empty virtual folder is still shown", () => {
  const groups = buildThreadTree([thread("a", "/Users/x/code")], {
    folders: [{ id: "f1", name: "Someday", parentId: null, depth: 0 }],
    assignments: {}
  });
  assert.deepEqual(groups.map((g) => g.name), ["Someday", "code"]);
  assert.equal(groups[0].total, 0);
});

test("folders nest inside folders and inside project groups, with subtree counts", () => {
  const threads = [
    thread("a", "/Users/x/code", { unread: true }),
    thread("b", "/Users/x/code", { running: true }),
    thread("c", "/Users/x/code")
  ];
  const groups = buildThreadTree(threads, {
    folders: [
      { id: "top", name: "Top", parentId: null, depth: 0 },
      { id: "kid", name: "Kid", parentId: "virtual:top", depth: 1 },
      { id: "proj", name: "In project", parentId: "/Users/x/code", depth: 0 }
    ],
    assignments: { "/s/a.jsonl": "kid", "/s/b.jsonl": "proj" }
  });

  const top = groups.find((g) => g.name === "Top");
  assert.equal(top.threads.length, 0);
  assert.equal(top.children[0].name, "Kid");
  assert.equal(top.total, 1, "counts roll up from descendants");
  assert.equal(top.unread, 1);

  const project = groups.find((g) => g.kind === "project");
  assert.equal(project.running, 1, "a nested folder's running thread counts for its host");
  assert.deepEqual(project.threads.map((t) => t.id), ["c"]);
});

test("flattening respects collapse state and its own depth guard", () => {
  const groups = buildThreadTree([thread("a", "/Users/x/code")], {
    folders: [{ id: "f1", name: "Review", parentId: null, depth: 0 }],
    assignments: { "/s/a.jsonl": "f1" }
  });

  const expanded = flattenTree(groups, new Set());
  assert.equal(expanded.filter((r) => r.kind === "thread").length, 1);

  const collapsed = flattenTree(groups, new Set(["virtual:f1"]));
  assert.equal(collapsed.filter((r) => r.kind === "thread").length, 0);
  assert.equal(collapsed[0].collapsed, true);

  // The cap is the deepest folder that still renders, matching the Mac sidebar: at 0 the top
  // folder is drawn and only its children are dropped.
  assert.equal(flattenTree(groups, new Set(), 0).filter((r) => r.kind === "group").length, 1);
});

/** A chain of `count` folders nested one inside the other, optionally hosted by a project. */
const folderChain = (count, parentId = null) =>
  Array.from({ length: count }, (_, index) => ({
    id: `f${index}`,
    name: `F${index}`,
    parentId: index === 0 ? parentId : `virtual:f${index - 1}`,
    depth: index
  }));

test("the depth cap counts folders, and the folder at the cap keeps its sessions", () => {
  // The Mac renders the folder *at* `sidebarMaxFolderDepth` with its sessions and drops only its
  // children. Stopping a level early here would hide a folder — and the thread inside it — that
  // the same machine shows in its own sidebar.
  const maxDepth = 3;
  const groups = buildThreadTree([thread("deep", "/Users/x/code"), thread("deeper", "/Users/x/code")], {
    folders: folderChain(maxDepth + 3),
    assignments: { "/s/deep.jsonl": `f${maxDepth}`, "/s/deeper.jsonl": `f${maxDepth + 1}` }
  });

  const rows = flattenTree(groups, new Set(), maxDepth);
  assert.deepEqual(
    rows.filter((r) => r.kind === "group").map((r) => r.group.name),
    ["F0", "F1", "F2", "F3"],
    "every folder up to and including the cap"
  );
  assert.deepEqual(
    rows.filter((r) => r.kind === "thread").map((r) => r.thread.id),
    ["deep"],
    "the last visible folder still renders its own sessions"
  );
});

test("a project wrapper does not cost a folder level", () => {
  // A project group hosts folders; it is not one. The app starts a project's folders at depth 0
  // exactly like top-level ones, so the same chain must survive in either position.
  const maxDepth = 3;
  const groups = buildThreadTree([thread("deep", "/Users/x/code")], {
    folders: folderChain(maxDepth + 3, "/Users/x/code"),
    assignments: { "/s/deep.jsonl": `f${maxDepth}` }
  });

  const rows = flattenTree(groups, new Set(), maxDepth);
  assert.deepEqual(
    rows.filter((r) => r.kind === "group").map((r) => r.group.name),
    ["code", "F0", "F1", "F2", "F3"]
  );
  assert.deepEqual(
    rows.filter((r) => r.kind === "thread").map((r) => r.thread.id),
    ["deep"],
    "a session in the last folder is reachable from a project-hosted chain too"
  );
  assert.deepEqual(
    rows.filter((r) => r.kind === "group").map((r) => r.depth),
    [0, 1, 2, 3, 4],
    "indentation still counts every row, including the wrapper"
  );
});

test("a folder whose parent no longer exists falls back to top level, keeping its threads", () => {
  // The daemon already rewrites a dangling parent, but a client must never be the reason a
  // thread disappears from the list: an unrenderable parent degrades to top level here too.
  const groups = buildThreadTree([thread("a", "/Users/x/code")], {
    folders: [{ id: "orphan", name: "Orphan", parentId: "virtual:gone", depth: 0 }],
    assignments: { "/s/a.jsonl": "orphan" }
  });
  const rows = flattenTree(groups);
  assert.deepEqual(
    rows.filter((r) => r.kind === "group").map((r) => r.group.name),
    ["Orphan"]
  );
  assert.deepEqual(
    rows.filter((r) => r.kind === "thread").map((r) => r.thread.id),
    ["a"],
    "the thread is still reachable"
  );
});

test("a project group is created to host a folder even with no threads of its own", () => {
  const groups = buildThreadTree([], {
    folders: [{ id: "f1", name: "Docs", parentId: "/Users/x/code", depth: 0 }],
    assignments: {}
  });
  assert.deepEqual(groups.map((g) => g.name), ["code"]);
  assert.deepEqual(groups[0].children.map((g) => g.name), ["Docs"]);
});
