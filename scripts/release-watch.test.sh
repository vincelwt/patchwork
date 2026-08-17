#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/state"

cat > "$tmp/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
	"release view --repo example/repo --json tagName -q .tagName") echo v1.2.3 ;;
	"api repos/example/repo -q .default_branch")
		[ "$GH_SCENARIO" != failure ] || { echo 'GitHub API unavailable' >&2; exit 1; }
		echo trunk
		;;
	"api repos/example/repo/commits/v1.2.3 -q .sha") echo tag-sha ;;
	"api repos/example/repo/commits --method GET -f sha=trunk -f per_page=100 --paginate --jq .[].sha")
		printf '%s\n' head-sha merge-sha tag-sha
		;;
	"api repos/example/repo/pulls?state=all&sort=updated&direction=desc&per_page=1 -q .[0].updated_at")
		echo 2020-01-01T00:00:00Z
		;;
	*) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_watch() {
	PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" GH_SCENARIO="$1" \
		REPO=example/repo PATCHWORK_STATE_DIR="$tmp/state" \
		"$root/scripts/release-watch.sh"
}

: > "$tmp/gh.log"
due=$(run_watch due)
[ "$due" = "example/repo trunk is 2 commits ahead of v1.2.3; last pull-request activity 2020-01-01T00:00:00Z" ]
grep -F 'sha=trunk' "$tmp/gh.log" >/dev/null
if grep -F 'HEAD' "$tmp/gh.log" >/dev/null; then
	exit 1
fi

first_failure=$(run_watch failure)
second_failure=$(run_watch failure)
[ "$first_failure" = 'release watcher check failed (incident 1): GitHub API unavailable' ]
[ "$second_failure" = "$first_failure" ]
run_watch due >/dev/null
third_failure=$(run_watch failure)
[ "$third_failure" = 'release watcher check failed (incident 2): GitHub API unavailable' ]

printf 'release watcher checks passed\n'
