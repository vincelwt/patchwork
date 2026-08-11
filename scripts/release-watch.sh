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
# agent once and a published release silences it again.
#
# ponytail: no retry of its own. If the release run fails, the line stays
# identical and nothing fires again until the next merge; run the automation by
# hand, or add a state file in $PATCHWORK_STATE_DIR if that stops being enough.
set -eu

REPO=${REPO:-vincelwt/patchwork}
QUIET_MINUTES=${QUIET_MINUTES:-60}

tag=$(gh release view --repo "$REPO" --json tagName -q .tagName)
ahead=$(gh api "repos/$REPO/compare/$tag...HEAD" -q .ahead_by)
[ "$ahead" -gt 0 ] || exit 0

# updated_at moves for a merge, a comment and a review alike, so one PR is all
# the "activity" this needs to look at.
last=$(gh api "repos/$REPO/pulls?state=all&sort=updated&direction=desc&per_page=1" \
	-q '.[0].updated_at')
[ "$last" \< "$(date -u -d "$QUIET_MINUTES minutes ago" +%Y-%m-%dT%H:%M:%SZ)" ] || exit 0

echo "$REPO is $ahead commits ahead of $tag; last pull-request activity $last"
