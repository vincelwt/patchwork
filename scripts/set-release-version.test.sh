#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/desktop/src-tauri"
cp "$root/Cargo.toml" "$tmp/Cargo.toml"
cp "$root/desktop/package.json" "$root/desktop/package-lock.json" "$tmp/desktop/"
cp "$root/desktop/src-tauri/tauri.conf.json" "$tmp/desktop/src-tauri/"
cp "$root/scripts/set-release-version.sh" "$tmp/scripts/"

"$tmp/scripts/set-release-version.sh" v1.2.3-beta.4
python3 - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
assert 'version = "1.2.3-beta.4"' in (root / "Cargo.toml").read_text()
for relative in ("desktop/package.json", "desktop/package-lock.json", "desktop/src-tauri/tauri.conf.json"):
    assert json.loads((root / relative).read_text())["version"] == "1.2.3-beta.4"
assert json.loads((root / "desktop/package-lock.json").read_text())["packages"][""]["version"] == "1.2.3-beta.4"
PY

if "$tmp/scripts/set-release-version.sh" not-a-tag 2>/dev/null; then
    echo "invalid release tag was accepted" >&2
    exit 1
fi

echo "release version checks passed"
