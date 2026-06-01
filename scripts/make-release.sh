#!/usr/bin/env bash
# Build + upload the AAAgents desktop release (engine + trained models + GUI) to the
# private repo. Uses GNU tar (zip is not available here; tar handles large files
# natively and the bootstrap extracts with the in-box bsdtar). EXCLUDES all secrets
# and runtime cruft, and ABORTS if any secret-bearing file slips into the archive.
set -euo pipefail

REPO="gorg4444/aaagents-local"
TAG="${1:-v1}"
SRC_ENGINE_PARENT="/c/Users/gapel/aaagents-app"               # contains "AI Trading Bot"
SRC_GUI_PARENT="/c/Users/gapel/aaagents-app-gui-test/release" # contains "win-unpacked"
DIST="/c/Users/gapel/aaagents-local-repo/dist"
PART_BYTES=1900000000   # < 2 GB GitHub per-asset limit

mkdir -p "$DIST"
rm -f "$DIST"/aaagents-engine.tar "$DIST"/aaagents-engine.tar.part-* "$DIST"/aaagents-gui.tar "$DIST"/SHA256SUMS.txt

# 1. Engine + models archive (tar, no compression: weights barely compress) --------
echo "=== [1/5] archiving engine + models (the long part) ==="
ENGINE_TAR="$DIST/aaagents-engine.tar"
tar -cf "$ENGINE_TAR" -C "$SRC_ENGINE_PARENT" \
  --warning=no-file-changed --warning=no-file-removed \
  --exclude='.git' --exclude='.venv' --exclude='.venv-fresh' --exclude='venv' \
  --exclude='node_modules' --exclude='__pycache__' \
  --exclude='*.pyc' --exclude='*.log' --exclude='*.pem' --exclude='*.key' \
  --exclude='.env' --exclude='.env.*' \
  --exclude='AI Trading Bot/data/training' \
  --exclude='AI Trading Bot/data/*.parquet' \
  --exclude='AI Trading Bot/data/*.db' \
  --exclude='AI Trading Bot/data/*.db-wal' --exclude='AI Trading Bot/data/*.db-shm' \
  --exclude='AI Trading Bot/data/audit_chain.jsonl' \
  --exclude='AI Trading Bot/cloud_fallback_logs' \
  --exclude='AI Trading Bot/lightning_logs' \
  --exclude='AI Trading Bot/market_data_cache' \
  --exclude='AI Trading Bot/clean_training_data' \
  --exclude='AI Trading Bot/logs' \
  --exclude='AI Trading Bot/oss_audit_logs' \
  --exclude='cloudbuild*.yaml' --exclude='cloudbuild*.yml' \
  --exclude='Dockerfile*' --exclude='docker-compose*' \
  --exclude='train_cloud.py' \
  --exclude='AI Trading Bot/scripts/verify_cloud_env.py' \
  --exclude='AI Trading Bot/scripts/setup_cloud*' \
  --exclude='AI Trading Bot/scripts/setup_secrets.sh' \
  --exclude='AI Trading Bot/scripts/setup_load_balancer.*' \
  --exclude='AI Trading Bot/scripts/setup_monitoring.sh' \
  --exclude='AI Trading Bot/scripts/backup_to_gcs.sh' \
  --exclude='AI Trading Bot/scripts/upload_models_to_gcs.sh' \
  --exclude='AI Trading Bot/tests/integration/test_infra_cloudbuild.py' \
  --exclude='AI Trading Bot/tests/unit/test_dockerfile_torch_versions.py' \
  "AI Trading Bot"

# 2. SECRET-LEAK GATE — abort if any secret-bearing file is in the archive ---------
echo "=== [2/5] secret-leak gate ==="
if tar -tf "$ENGINE_TAR" \
   | grep -iE '(^|/)\.env(\.|$)|/[^/ ]*\.env$|\.pem$|\.key$|\.p12$|\.pfx$|/id_rsa$|/credentials\.json$|/service[_-]account[^/]*\.json$|/secrets?\.(json|ya?ml)$|/[^/]*_secret\.(json|txt|ya?ml)$' \
   | grep -vE '\.example$' ; then
  echo "ABORT: secret-bearing file found in engine archive (see above)."; exit 1
fi
echo "ok: no secrets in engine archive"

# 3. GUI archive ------------------------------------------------------------------
echo "=== [3/5] archiving GUI (win-unpacked) ==="
GUI_TAR="$DIST/aaagents-gui.tar"
tar -cf "$GUI_TAR" -C "$SRC_GUI_PARENT" "win-unpacked"

# 3b. Bundled relocatable Python (interpreter + all deps) — only if prebuilt.
# Build it once with: download python-build-standalone -> dist/python-bundle/python,
# then `python.exe -m pip install -r requirements.oss.txt` into it. Rarely changes.
PY_PRESENT=0
if [ -d "$DIST/python-bundle/python" ]; then
  echo "=== [3b] archiving bundled Python ==="
  tar -cf "$DIST/aaagents-python.tar" -C "$DIST/python-bundle" python
  PY_PRESENT=1
fi

# 4. Split + checksums ------------------------------------------------------------
echo "=== [4/5] splitting + checksums ==="
ESIZE=$(stat -c%s "$ENGINE_TAR")
echo "  hashing full engine tar ($((ESIZE/1024/1024)) MB) ..."
FULLHASH=$(sha256sum "$ENGINE_TAR" | awk '{print $1}')
cd "$DIST"
if [ "$ESIZE" -gt "$PART_BYTES" ]; then
  split -b "$PART_BYTES" -d -a 2 "$ENGINE_TAR" "aaagents-engine.tar.part-"
  rm -f "$ENGINE_TAR"
  { sha256sum aaagents-engine.tar.part-* aaagents-gui.tar; echo "$FULLHASH  aaagents-engine.tar"; } > SHA256SUMS.txt
  UP=(aaagents-engine.tar.part-* aaagents-gui.tar SHA256SUMS.txt)
else
  sha256sum aaagents-engine.tar aaagents-gui.tar > SHA256SUMS.txt
  UP=(aaagents-engine.tar aaagents-gui.tar SHA256SUMS.txt)
fi
# Fold in the bundled Python (single file, or split if it ever exceeds the limit).
if [ "$PY_PRESENT" = "1" ]; then
  PSIZE=$(stat -c%s aaagents-python.tar); PHASH=$(sha256sum aaagents-python.tar | awk '{print $1}')
  rm -f aaagents-python.tar.part-*
  UP=("${UP[@]:0:${#UP[@]}-1}")  # drop trailing SHA256SUMS.txt; re-added below
  if [ "$PSIZE" -gt "$PART_BYTES" ]; then
    split -b "$PART_BYTES" -d -a 2 aaagents-python.tar aaagents-python.tar.part-
    rm -f aaagents-python.tar
    { sha256sum aaagents-python.tar.part-*; echo "$PHASH  aaagents-python.tar"; } >> SHA256SUMS.txt
    UP+=(aaagents-python.tar.part-*)
  else
    sha256sum aaagents-python.tar >> SHA256SUMS.txt
    UP+=(aaagents-python.tar)
  fi
  UP+=(SHA256SUMS.txt)
fi
ls -lh "${UP[@]}"

# 5. Create + upload --------------------------------------------------------------
echo "=== [5/5] uploading release $TAG to $REPO ==="
unset GH_TOKEN
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  # Clear stale engine assets first (part count can shrink between builds).
  for a in $(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name' 2>/dev/null | grep -E '^aaagents-(engine|python)\.(tar|zip)'); do
    echo "  removing stale asset: $a"; gh release delete-asset "$TAG" "$a" -R "$REPO" -y 2>/dev/null || true
  done
else
  gh release create "$TAG" -R "$REPO" -t "AAAgents desktop $TAG" -n "Full no-Docker engine + trained models + desktop GUI (public, Apache-2.0). Run bootstrap.ps1."
fi
gh release upload "$TAG" -R "$REPO" "${UP[@]}" --clobber
echo "=== DONE: https://github.com/$REPO/releases/tag/$TAG ==="
