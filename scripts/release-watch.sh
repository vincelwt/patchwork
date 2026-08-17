#!/bin/sh
# Prints one structured event when a GitHub release is due: the default branch
# is ahead of the latest release and nobody has touched a pull request for an
# hour. Silence means nothing to do, which is what a Patchwork `watch` wants:
#
#   patchwork automation create --name "Automatic releases after PR quiet period" \
#     --agent @developer --trigger watch --every 600 --action post-in-chat \
#     --command /home/vince/src/patchwork/scripts/release-watch.sh
#
# The event key changes with the release state, so a quiet period fires the
# agent once and a published release silences it again. Command failures stay
# non-zero and become visible watch failures in Patchwork.
set -eu

REPO=${REPO:-vincelwt/patchwork}
QUIET_MINUTES=${QUIET_MINUTES:-60}

tag=$(gh release view --repo "$REPO" --json tagName -q .tagName)
branch=$(gh api "repos/$REPO" -q .default_branch)
tag_sha=$(gh api "repos/$REPO/commits/$tag" -q .sha)
ahead=$(gh api "repos/$REPO/commits" --method GET -f sha="$branch" \
	-f per_page=100 --paginate --jq '.[].sha' |
	awk -v tag="$tag_sha" '$0 == tag { print NR - 1; found = 1; exit } END { if (!found) exit 1 }')
[ "$ahead" -gt 0 ] || exit 0

# updated_at moves for a merge, a comment and a review alike, so one PR is all
# the "activity" this needs to look at.
last=$(gh api "repos/$REPO/pulls?state=all&sort=updated&direction=desc&per_page=1" \
	-q '.[0].updated_at')
[ "$(date -u -d "$last" +%s)" -le "$(date -u -d "$QUIET_MINUTES minutes ago" +%s)" ] || exit 0

printf '{"event_key":"release:%s:%s:%s","condition_key":"patchwork:release-due","title":"Publish the pending Patchwork release","outcome":"The latest Patchwork changes are published in a GitHub release","context":{"repository":"%s","ahead_by":%s,"last_pull_request_activity":"%s"}}\n' \
	"$REPO" "$ahead" "$last" "$REPO" "$ahead" "$last"
