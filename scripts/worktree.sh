#!/usr/bin/env bash
# Manage git worktrees for parallel Patchwork work.
#
#   scripts/worktree.sh new <name> [base-ref]   create ../patchwork-worktrees/<name> on feat/<name>
#   scripts/worktree.sh list                    show worktrees and their branches
#   scripts/worktree.sh rm <name> [--force]     remove the worktree (keeps the branch)
#   scripts/worktree.sh clean                   prune stale worktree metadata
#
# Worktrees live outside the repo so SwiftPM builds, dist bundles, and Pi
# session folders stay separate per agent. Override the location with
# PATCHWORK_WORKTREE_ROOT.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_ROOT="${PATCHWORK_WORKTREE_ROOT:-$(dirname "$ROOT")/patchwork-worktrees}"
BRANCH_PREFIX="feat"

cd "$ROOT"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_commit() {
    git rev-parse --verify HEAD >/dev/null 2>&1 ||
        die "the repository has no commits yet; commit a baseline before creating worktrees"
}

case "${1:-}" in
new)
    name="${2:-}"
    [ -n "$name" ] || die "usage: worktree.sh new <name> [base-ref]"
    require_commit
    base="${3:-HEAD}"
    branch="$BRANCH_PREFIX/$name"
    path="$WORKTREE_ROOT/$name"

    [ -e "$path" ] && die "$path already exists"
    git show-ref --verify --quiet "refs/heads/$branch" && die "branch $branch already exists"

    mkdir -p "$WORKTREE_ROOT"
    git worktree add -b "$branch" "$path" "$base"

    printf '\nWorktree ready\n  path:   %s\n  branch: %s\n  base:   %s\n\n' \
        "$path" "$branch" "$(git rev-parse --short "$base")"
    printf 'Next:\n  cd %s\n  swift build && swift test\n\n' "$path"
    printf 'One writer per worktree. Merge back with:\n  git -C %s merge --no-ff %s\n' "$ROOT" "$branch"
    ;;
list)
    git worktree list
    ;;
rm | remove)
    name="${2:-}"
    [ -n "$name" ] || die "usage: worktree.sh rm <name> [--force]"
    path="$WORKTREE_ROOT/$name"
    [ -d "$path" ] || die "$path does not exist"
    git worktree remove "$path" ${3:-}
    printf 'Removed %s. Branch %s/%s still exists; delete it with:\n  git branch -D %s/%s\n' \
        "$path" "$BRANCH_PREFIX" "$name" "$BRANCH_PREFIX" "$name"
    ;;
clean)
    git worktree prune -v
    ;;
"" | -h | --help | help)
    usage
    ;;
*)
    die "unknown command: $1 (try --help)"
    ;;
esac
