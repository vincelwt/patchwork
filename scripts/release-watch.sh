#!/bin/sh
# Prints one line when a GitHub release is due: the default branch is ahead of
# the latest release and nobody has touched a pull request for an hour. Silence
# means nothing to do, which is what a Patchwork `watch` automation wants:
#
#   patchwork automation create --name "Automatic releases after PR quiet period" \
#     --agent @developer --trigger watch --every 600 --action post-in-chat \
#     --command /home/vince/src/patchwork/scripts/release-watch.sh
#
# The line only changes when the situation changes, so a quiet period fires the
# agent once and a published release silences it again. Failed checks print one
# stable incident line while Patchwork keeps polling; a successful check clears
# the incident so a later failure is observable too.
set -eu

REPO=${REPO:-vincelwt/patchwork}
QUIET_MINUTES=${QUIET_MINUTES:-60}

check_release() {
	tag=$(gh release view --repo "$REPO" --json tagName -q .tagName)
	branch=$(gh api "repos/$REPO" -q .default_branch)
	tag_sha=$(gh api "repos/$REPO/commits/$tag" -q .sha)
	ahead=$(gh api "repos/$REPO/commits" --method GET -f sha="$branch" \
		-f per_page=100 --paginate --jq '.[].sha' |
		awk -v tag="$tag_sha" '$0 == tag { print NR - 1; found = 1; exit } END { if (!found) exit 1 }')
	[ "$ahead" -gt 0 ] || return 0

	# updated_at moves for a merge, a comment and a review alike, so one PR is all
	# the "activity" this needs to look at.
	last=$(gh api "repos/$REPO/pulls?state=all&sort=updated&direction=desc&per_page=1" \
		-q '.[0].updated_at')
	[ "$(date -u -d "$last" +%s)" -le "$(date -u -d "$QUIET_MINUTES minutes ago" +%s)" ] || return 0

	echo "$REPO $branch is $ahead commits ahead of $tag; last pull-request activity $last"
}

if output=$(check_release 2>&1); then
	[ -z "${PATCHWORK_STATE_DIR:-}" ] || rm -f "$PATCHWORK_STATE_DIR/release-watch-failure"
	[ -z "$output" ] || printf '%s\n' "$output"
	exit 0
fi

incident=manual
if [ -n "${PATCHWORK_STATE_DIR:-}" ] && mkdir -p "$PATCHWORK_STATE_DIR"; then
	active="$PATCHWORK_STATE_DIR/release-watch-failure"
	sequence="$PATCHWORK_STATE_DIR/release-watch-failure-sequence"
	if [ -f "$active" ]; then
		incident=$(cat "$active")
	else
		incident=$(($(cat "$sequence" 2>/dev/null || echo 0) + 1))
		printf '%s\n' "$incident" > "$sequence"
		printf '%s\n' "$incident" > "$active"
	fi
fi
error=$(printf '%s\n' "$output" | sed -n '1p')
printf 'release watcher check failed (incident %s): %s\n' "$incident" "${error:-unknown error}"
