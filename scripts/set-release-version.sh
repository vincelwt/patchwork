#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

python3 - "$root" "${1:-}" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
match = re.fullmatch(r"v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)", sys.argv[2])
if not match:
    raise SystemExit("release tag must be v<semver>")
version = match.group(1)

for relative in ("desktop/package.json", "desktop/package-lock.json", "desktop/src-tauri/tauri.conf.json"):
    path = root / relative
    data = json.loads(path.read_text())
    data["version"] = version
    if relative.endswith("package-lock.json"):
        data["packages"][""]["version"] = version
    path.write_text(json.dumps(data, indent=2) + "\n")

cargo = root / "Cargo.toml"
text, replacements = re.subn(
    r'(\[workspace\.package\]\nversion = ")[^"]+("\n)',
    rf"\g<1>{version}\g<2>",
    cargo.read_text(),
)
if replacements != 1:
    raise SystemExit("workspace version not found")
cargo.write_text(text)
print(f"release version set to {version}")
PY
