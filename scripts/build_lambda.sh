#!/usr/bin/env bash
# Build dist/vault-secrets-sync.zip for the arm64 python3.13 Lambda runtime using uv.
# The zip is deterministic (sorted entries, fixed timestamps), so Terraform's
# source_code_hash only changes when code or dependencies change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/lambda"
DIST="$ROOT/dist"
rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

cd "$ROOT/lambda"
uv export --frozen --no-dev --no-hashes --no-emit-project -o "$BUILD/requirements.txt" >/dev/null
uv pip install --quiet \
  --target "$BUILD/pkg" \
  --python-version 3.13 \
  --python-platform aarch64-manylinux2014 \
  --only-binary :all: \
  -r "$BUILD/requirements.txt"
cp -R src/vault_secrets_sync "$BUILD/pkg/"
find "$BUILD/pkg" -name '__pycache__' -type d -prune -exec rm -rf {} +

uv run --no-project python - "$BUILD/pkg" "$DIST/vault-secrets-sync.zip" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
files = sorted(
    os.path.relpath(os.path.join(d, f), src)
    for d, _, fs in os.walk(src) for f in fs
)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in files:
        info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(src, rel), "rb") as fh:
            z.writestr(info, fh.read())
print(f"wrote {out} ({len(files)} files)")
PY
