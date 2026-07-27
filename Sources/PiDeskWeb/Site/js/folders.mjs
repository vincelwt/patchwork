// Groups the thread list the way the Mac app's sidebar does, from the read-only folder tree
// `GET /v1/folders` exposes.
//
// The daemon has already resolved cycles, dangling parents, and the depth cap (see
// `FolderTree` in PiDeskKit), so this file deliberately contains *no* cycle logic of its own: it
// only buckets threads and sorts groups. Pure data in, pure data out, so the grouping rules are
// testable without a DOM (docs/js-checks/folders.test.mjs).
//
// The rules mirror `SidebarSnapshot` in the app:
//   - a thread filed into a virtual folder appears there, and only there
//   - every other thread groups under its filesystem project (`cwd`)
//   - a virtual folder can be nested in another folder or hosted by a project group
//   - an empty virtual folder still shows, so a folder made on the Mac is visible before
//     anything has been filed into it
//   - a group's own threads never include a descendant's, so each thread appears exactly once

const VIRTUAL_PREFIX = "virtual:";

/** The app's group-id scheme: `null` top level, a project path, or `virtual:<uuid>`. */
export function groupIdForFolder(folderId) {
  return `${VIRTUAL_PREFIX}${folderId}`;
}

export function folderIdFromGroupId(groupId) {
  return typeof groupId === "string" && groupId.startsWith(VIRTUAL_PREFIX)
    ? groupId.slice(VIRTUAL_PREFIX.length)
    : null;
}

function lastName(path) {
  const parts = String(path || "").split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : path || "Other";
}

function time(value) {
  const parsed = new Date(value || 0).getTime();
  return Number.isNaN(parsed) ? 0 : parsed;
}

function byRecency(a, b) {
  if (b.updatedAt !== a.updatedAt) return b.updatedAt - a.updatedAt;
  return a.name.localeCompare(b.name);
}

/**
 * Builds the nested render model.
 *
 * `folderTree` is the `GET /v1/folders` payload (`{folders, assignments}`); passing `null` — an
 * older daemon, a machine that never made a folder, or a failed request — yields plain project
 * grouping, which is exactly the pre-folder behaviour.
 */
export function buildThreadTree(threads, folderTree) {
  const folders = (folderTree && Array.isArray(folderTree.folders) ? folderTree.folders : []).filter(
    (folder) => folder && typeof folder.id === "string"
  );
  const assignments = (folderTree && folderTree.assignments) || {};
  const validIds = new Set(folders.map((folder) => folder.id));

  const threadsByFolder = new Map();
  const threadsByProject = new Map();
  for (const thread of threads || []) {
    const assigned = assignments[thread.path];
    const bucket = assigned && validIds.has(assigned) ? threadsByFolder : threadsByProject;
    const key = assigned && validIds.has(assigned) ? assigned : thread.cwd || "";
    if (!bucket.has(key)) bucket.set(key, []);
    bucket.get(key).push(thread);
  }

  // Same fallback the daemon already applies (`FolderTree.effectiveParentID`), repeated here so
  // a folder is never bucketed under a parent that will not be rendered: a dangling `virtual:`
  // parent lands at top level rather than taking its threads out of the list entirely. A
  // filesystem project parent is always accepted — projects are derived from live threads, so a
  // project group with no threads of its own is created below to host the folder.
  const childrenByParent = new Map();
  for (const folder of folders) {
    const virtualParent = folderIdFromGroupId(folder.parentId);
    const dangling = virtualParent !== null && !validIds.has(virtualParent);
    const key = dangling ? "" : folder.parentId || "";
    if (!childrenByParent.has(key)) childrenByParent.set(key, []);
    childrenByParent.get(key).push(folder);
  }

  const buildFolder = (folder) => {
    const own = (threadsByFolder.get(folder.id) || []).slice().sort((a, b) => time(b.updatedAt) - time(a.updatedAt));
    const children = (childrenByParent.get(groupIdForFolder(folder.id)) || []).map(buildFolder).sort(byRecency);
    return summarize({ id: groupIdForFolder(folder.id), name: folder.name, kind: "virtual", threads: own, children });
  };

  const projectPaths = new Set(threadsByProject.keys());
  for (const key of childrenByParent.keys()) {
    if (key && folderIdFromGroupId(key) === null) projectPaths.add(key);
  }

  const topFolders = (childrenByParent.get("") || []).map(buildFolder).sort(byRecency);
  const projects = [...projectPaths]
    .map((path) => {
      const own = (threadsByProject.get(path) || []).slice().sort((a, b) => time(b.updatedAt) - time(a.updatedAt));
      const children = (childrenByParent.get(path) || []).map(buildFolder).sort(byRecency);
      return summarize({ id: path, name: lastName(path), kind: "project", threads: own, children });
    })
    // Same rule as the app's sidebar: a project group survives if it holds threads *or* hosts a
    // folder. An empty one is not something a person made, just a path with nothing left in it.
    .filter((group) => group.total > 0 || group.children.length > 0)
    .sort(byRecency);

  return [...topFolders, ...projects];
}

/** Subtree totals, so a collapsed folder can still show what is inside it. */
function summarize(group) {
  const childTotals = group.children.reduce(
    (acc, child) => ({
      total: acc.total + child.total,
      unread: acc.unread + child.unread,
      running: acc.running + child.running,
      updatedAt: Math.max(acc.updatedAt, child.updatedAt)
    }),
    { total: 0, unread: 0, running: 0, updatedAt: 0 }
  );
  return {
    ...group,
    total: group.threads.length + childTotals.total,
    unread: group.threads.filter((thread) => thread.unread).length + childTotals.unread,
    running: group.threads.filter((thread) => thread.running).length + childTotals.running,
    updatedAt: Math.max(childTotals.updatedAt, ...group.threads.map((thread) => time(thread.updatedAt)), 0)
  };
}

/**
 * Depth-first render rows. `collapsed` is a Set of group ids; a collapsed group contributes its
 * own header row and nothing below it. `maxDepth` is an independent guard on top of the daemon's
 * own cap, so a hand-edited tree can never make this recurse without bound.
 */
export function flattenTree(groups, collapsed = new Set(), maxDepth = 24) {
  const rows = [];
  const walk = (list, depth) => {
    if (depth >= maxDepth) return;
    for (const group of list) {
      rows.push({ kind: "group", depth, group, collapsed: collapsed.has(group.id) });
      if (collapsed.has(group.id)) continue;
      for (const thread of group.threads) rows.push({ kind: "thread", depth: depth + 1, thread });
      walk(group.children, depth + 1);
    }
  };
  walk(groups, 0);
  return rows;
}

/** True when grouping would add nothing: a single project and no folders at all. */
export function isFlatList(groups) {
  return groups.length <= 1 && groups.every((group) => group.kind === "project" && group.children.length === 0);
}
