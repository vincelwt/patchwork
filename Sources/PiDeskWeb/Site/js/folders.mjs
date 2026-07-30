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
//   - virtual folders and real project groups can contain each other
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
  if (a.kind !== b.kind) return a.kind === "virtual" ? -1 : 1;
  if (b.updatedAt !== a.updatedAt) return b.updatedAt - a.updatedAt;
  return a.name.localeCompare(b.name);
}

/**
 * Builds the nested render model.
 *
 * `folderTree` is the `GET /v1/folders` payload (`{folders, assignments, projectAssignments}`); passing `null`, an
 * older daemon, a machine that never made a folder, or a failed request — yields plain project
 * grouping, which is exactly the pre-folder behaviour.
 */
export function buildThreadTree(threads, folderTree) {
  const folders = (folderTree && Array.isArray(folderTree.folders) ? folderTree.folders : []).filter(
    (folder) => folder && typeof folder.id === "string"
  );
  const assignments = (folderTree && folderTree.assignments) || {};
  const projectAssignments = (folderTree && folderTree.projectAssignments) || {};
  const validIds = new Set(folders.map((folder) => folder.id));
  const folderByGroupId = new Map(folders.map((folder) => [groupIdForFolder(folder.id), folder]));

  const threadsByFolder = new Map();
  const threadsByProject = new Map();
  for (const thread of threads || []) {
    const assigned = assignments[thread.path];
    const bucket = assigned && validIds.has(assigned) ? threadsByFolder : threadsByProject;
    const key = assigned && validIds.has(assigned) ? assigned : thread.cwd || "";
    if (!bucket.has(key)) bucket.set(key, []);
    bucket.get(key).push(thread);
  }

  const projectPaths = new Set([...threadsByProject.keys(), ...Object.keys(projectAssignments)]);
  for (const folder of folders) {
    if (folder.parentId && folderIdFromGroupId(folder.parentId) === null) projectPaths.add(folder.parentId);
  }

  // Both node kinds share the same parent-id scheme. The daemon has already flattened cycles;
  // the dangling checks keep this client backward-safe with malformed or older payloads.
  const childrenByParent = new Map();
  const appendChild = (parent, child) => {
    if (!childrenByParent.has(parent)) childrenByParent.set(parent, []);
    childrenByParent.get(parent).push(child);
  };
  for (const folder of folders) {
    const virtualParent = folderIdFromGroupId(folder.parentId);
    appendChild(virtualParent !== null && !validIds.has(virtualParent) ? "" : folder.parentId || "", groupIdForFolder(folder.id));
  }
  for (const path of projectPaths) {
    const assigned = projectAssignments[path];
    appendChild(assigned && validIds.has(assigned) ? groupIdForFolder(assigned) : "", path);
  }

  const buildGroup = (groupId, ancestors = new Set()) => {
    if (ancestors.has(groupId)) return null;
    const nextAncestors = new Set(ancestors).add(groupId);
    const children = (childrenByParent.get(groupId) || [])
      .map((child) => buildGroup(child, nextAncestors))
      .filter(Boolean)
      .sort(byRecency);
    const folder = folderByGroupId.get(groupId);
    const own = folder
      ? (threadsByFolder.get(folder.id) || []).slice()
      : (threadsByProject.get(groupId) || []).slice();
    own.sort((a, b) => time(b.updatedAt) - time(a.updatedAt));
    const group = summarize({
      id: groupId,
      name: folder ? folder.name : lastName(groupId),
      kind: folder ? "virtual" : "project",
      threads: own,
      children
    });
    return folder || group.total > 0 || children.length > 0 ? group : null;
  };

  return (childrenByParent.get("") || [])
    .map((groupId) => buildGroup(groupId))
    .filter(Boolean)
    .sort(byRecency);
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
 *
 * The cap counts *virtual folder* nesting only, exactly like the Mac sidebar: a project group is
 * a wrapper around folders, not a folder level, so a folder hosted by a project starts at 0 just
 * as a top-level one does. A folder at the cap still renders with its own sessions; only its
 * children are dropped. Indentation (`depth`) still counts every row, so the two never disagree
 * about what a row looks like, only about where the tree stops.
 */
export function flattenTree(groups, collapsed = new Set(), maxDepth = 24) {
  const rows = [];
  const walk = (list, depth, folderDepth) => {
    if (folderDepth > maxDepth) return;
    for (const group of list) {
      rows.push({ kind: "group", depth, group, collapsed: collapsed.has(group.id) });
      if (collapsed.has(group.id)) continue;
      for (const thread of group.threads) rows.push({ kind: "thread", depth: depth + 1, thread });
      walk(group.children, depth + 1, group.kind === "virtual" ? folderDepth + 1 : folderDepth);
    }
  };
  walk(groups, 0, 0);
  return rows;
}

/** True when grouping would add nothing: a single project and no folders at all. */
export function isFlatList(groups) {
  return groups.length <= 1 && groups.every((group) => group.kind === "project" && group.children.length === 0);
}
