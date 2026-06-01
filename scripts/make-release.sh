#!/usr/bin/env bash
# Build + upload the AAAgents desktop release (engine + trained models + GUI) to the
# private repo. Runs on a machine with the source trees. EXCLUDES all secrets and
# runtime cruft, and aborts if any secret-like file slips into the archive.
set -euo pipefail

REPO="gorg4444/aaagents-local"
TAG="${1:-v1}"
SRC_ENGINE_PARENT="/c/Users/gapel/aaagents-app"            # contains "AI Trading Bot"
SRC_GUI_PARENT="/c/Users/gapel/aaagents-app-gui-test/release"   # contains "win-unpacked"
DIST="/c/Users/gapel/aaagents-local-repo/dist"
PART_BYTES=1900000000   # < 2 GB GitHub per-asset limit

mkdir -p "$DIST"
rm -f "$DIST"/aaagents-engine.zip "$DIST"/aaagents-engine.zip.part-* "$DIST"/aaagents-gui.zip "$DIST"/SHA256SUMS.txt

# 1. Engine + models zip (store-only: models barely compress; speed over ratio) ----
echo "=== [1/5] zipping engine + models (this is the long part) ==="
cd "$SRC_ENGINE_PARENT"
ENGINE_ZIP="$DIST/aaagents-engine.zip"
zip -r -1 "$ENGINE_ZIP" "AI Trading Bot" \
  -x "AI Trading Bot/.git/*" \
  -x "AI Trading Bot/.venv/*" -x "AI Trading Bot/.venv-fresh/*" -x "AI Trading Bot/venv/*" \
  -x "AI Trading Bot/node_modules/*" \
  -x "*/__pycache__/*" -x "*.pyc" \
  -x "AI Trading Bot/.env" -x "AI Trading Bot/.env.*" -x "*/.env" -x "*/.env.*" \
  -x "*.key" -x "*.pem" -x "*secrets*.json" \
  -x "AI Trading Bot/data/training/*" \
  -x "AI Trading Bot/data/*.parquet" \
  -x "AI Trading Bot/data/*.db" -x "AI Trading Bot/data/*.db-wal" -x "AI Trading Bot/data/*.db-shm" \
  -x "AI Trading Bot/data/audit_chain.jsonl" \
  -x "AI Trading Bot/cloud_fallback_logs/*" \
  -x "AI Trading Bot/lightning_logs/*" \
  -x "AI Trading Bot/market_data_cache/*" \
  -x "AI Trading Bot/clean_training_data/*" \
  -x "AI Trading Bot/logs/*" \
  -x "AI Trading Bot/oss_audit_logs/*" \
  -x "*.log" >/dev/null

# 2. SECRET-LEAK GATE — abort if anything secret-like is in the archive ------------
echo "=== [2/5] secret-leak gate ==="
# Match actual secret-bearing files only (NOT source named *secret*, e.g. secret_manager_utils.py).
if unzip -l "$ENGINE_ZIP" \
   | grep -iE '/\.env(\.|$)|/[^/ ]*\.env$|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/credentials\.json$|/service[_-]account[^/]*\.json$|/secrets?\.(json|ya?ml)$|/[^/]*_secret\.(json|txt|ya?ml)$' \
   | grep -vE '\.example$' ; then
  echo "ABORT: secret-bearing file found in engine zip (see above)."; exit 1
fi
echo "ok: no secrets in engine archive"

# 3. GUI zip ----------------------------------------------------------------------
echo "=== [3/5] zipping GUI (win-unpacked) ==="
GUI_ZIP="$DIST/aaagents-gui.zip"
( cd "$SRC_GUI_PARENT" && zip -r -1 "$GUI_ZIP" "win-unpacked" >/dev/null )

# 4. Split engine zip into < 2 GB parts (bootstrap rejoins via copy /b) ------------
echo "=== [4/5] splitting + checksums ==="
ESIZE=$(stat -c%s "$ENGINE_ZIP")
echo "  hashing full engine zip ($((ESIZE/1024/1024)) MB) ..."
FULLHASH=$(sha256sum "$ENGINE_ZIP" | awk '{print $1}')
cd "$DIST"
if [ "$ESIZE" -gt "$PART_BYTES" ]; then
  split -b "$PART_BYTES" -d -a 2 "$ENGINE_ZIP" "aaagents-engine.zip.part-"
  rm -f "$ENGINE_ZIP"
  { sha256sum aaagents-engine.zip.part-* aaagents-gui.zip; echo "$FULLHASH  aaagents-engine.zip"; } > SHA256SUMS.txt
  UP=(aaagents-engine.zip.part-* aaagents-gui.zip SHA256SUMS.txt)
else
  sha256sum aaagents-engine.zip aaagents-gui.zip > SHA256SUMS.txt
  UP=(aaagents-engine.zip aaagents-gui.zip SHA256SUMS.txt)
fi
ls -lh "${UP[@]}"

# 5. Create + upload the release --------------------------------------------------
echo "=== [5/5] uploading release $TAG to $REPO ==="
unset GH_TOKEN
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  # Clear stale engine-part assets first (the part count can shrink between builds,
  # which would otherwise leave an orphan part that corrupts the rejoin).
  for a in $(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name' 2>/dev/null | grep -E '^aaagents-engine\.zip'); do
    echo "  removing stale asset: $a"; gh release delete-asset "$TAG" "$a" -R "$REPO" -y 2>/dev/null || true
  done
else
  gh release create "$TAG" -R "$REPO" -t "AAAgents desktop $TAG" \
    -n "Full no-Docker engine + trained models + desktop GUI (private). Run bootstrap.ps1."
fi
gh release upload "$TAG" -R "$REPO" "${UP[@]}" --clobber
echo "=== DONE: https://github.com/$REPO/releases/tag/$TAG ==="
