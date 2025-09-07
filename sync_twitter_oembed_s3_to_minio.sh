#!/usr/bin/env bash
set -euo pipefail

# ==================== CONFIG (edit or export as env) ====================
# Source (AWS S3) — where tweet_oembed_to_aws_s3.py wrote the data
S3_BUCKET="${S3_BUCKET:-my-social-data}"
S3_PREFIX="${S3_PREFIX:-twitter/oembed}"            # no leading slash; "" = bucket root
# If you only want the tweets (and not manifests), keep as-is.
# Manifests live under the same prefix as _manifest_*.csv/.jsonl

# DVC remotes
SRC_REMOTE="${SRC_REMOTE:-aws-s3}"                  # DVC remote pointing to AWS S3 (read source)
DST_REMOTE="${DST_REMOTE:-minio}"                   # DVC remote pointing to MinIO (write destination)

# Local DVC-tracked paths (as directories)
IMPORT_DIR_TWEETS="${IMPORT_DIR_TWEETS:-data/tweets}"   # local logical path to track tweets dir
IMPORT_DIR_MF="${IMPORT_DIR_MF:-data/tweets-manifests}" # local logical path to track manifests dir

# Toggle whether to also import the manifests
SYNC_MANIFESTS="${SYNC_MANIFESTS:-true}"                # true|false

# Force refresh even if pointers unchanged (rarely needed)
FORCE="${FORCE:-false}"                                 # true|false
# ========================================================================

if ! command -v dvc >/dev/null 2>&1; then
  echo "❌ dvc not found on PATH"; exit 1
fi

S3_URI_TWEETS="s3://${S3_BUCKET}/${S3_PREFIX%/}/"    # directory-style import
S3_URI_MANIFESTS="${S3_URI_TWEETS}"                  # manifests live alongside tweets

echo "==> Source S3: ${S3_URI_TWEETS}"
echo "==> DVC source remote : ${SRC_REMOTE}"
echo "==> DVC dest   remote : ${DST_REMOTE}"
echo "==> Import tweets into: ${IMPORT_DIR_TWEETS}"
if [[ "${SYNC_MANIFESTS}" == "true" ]]; then
  echo "==> Import manifests into: ${IMPORT_DIR_MF}"
fi

# Helper: import a directory (to-remote) and commit pointer if new
import_dir() {
  local SRC_URI="$1"       # s3://bucket/prefix/
  local IMPORT_DIR="$2"    # local dvc logical dir
  local LABEL="$3"         # display label

  echo "==> Ensuring ${LABEL} is tracked as an import from ${SRC_URI}"
  # Ensure parent dir exists (for cleanliness; actual data stays in remotes)
  mkdir -p "$(dirname "${IMPORT_DIR}")"

  # Create or refresh .dvc import (directory import; --to-remote avoids local download)
  if [[ ! -f "${IMPORT_DIR}.dvc" ]]; then
    dvc import-url --to-remote "${SRC_URI}" "${IMPORT_DIR}" -r "${SRC_REMOTE}" ${FORCE:+--force}
    git add "${IMPORT_DIR}.dvc" .gitignore || true
    git commit -m "Import ${LABEL} from ${SRC_URI} (to-remote via ${SRC_REMOTE})" || true
  else
    echo "==> Checking for updates in ${LABEL} (dvc update)"
    dvc update "${IMPORT_DIR}.dvc" ${FORCE:+--force} || true
    if ! git diff --quiet -- "${IMPORT_DIR}.dvc"; then
      echo "==> Import updated for ${LABEL}; committing pointer change"
      git add "${IMPORT_DIR}.dvc"
      git commit -m "Update import snapshot for ${LABEL}"
    else
      echo "==> No pointer change detected for ${LABEL} (already up to date)"
    fi
  fi
}

# 1) Import tweets directory from S3 into the DVC graph (no local data)
import_dir "${S3_URI_TWEETS}" "${IMPORT_DIR_TWEETS}" "Tweets directory"

# 2) Optionally import manifests (same prefix; files named _manifest_*.csv/.jsonl)
if [[ "${SYNC_MANIFESTS}" == "true" ]]; then
  # We import the entire prefix (lightweight pointer), because DVC import-url (to-remote)
  # doesn’t support S3-side glob filtering; that's fine for small sidecars.
  import_dir "${S3_URI_MANIFESTS}" "${IMPORT_DIR_MF}" "Manifests directory"
fi

# 3) Pull objects from the source S3 remote into local cache (metadata only with to-remote)
echo "==> Fetching objects from source remote '${SRC_REMOTE}' into cache"
dvc fetch -r "${SRC_REMOTE}" -v

# 4) Push objects to MinIO remote
echo "==> Pushing objects to destination remote '${DST_REMOTE}'"
dvc push -r "${DST_REMOTE}" -v

echo "==> Done. MinIO is in sync with the latest snapshot from ${S3_URI_TWEETS}"