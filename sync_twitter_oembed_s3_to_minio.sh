#!/usr/bin/env bash
set -euo pipefail

# --- helpers (portable lowercasing) ---
lc() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
is_true() { [ "$(lc "${1:-}")" = "true" ]; }

# --------- CONFIG / ENV -------------
SRC_BUCKET="${S3_BUCKET:-my-social-data}"
SRC_PREFIX="${S3_PREFIX:-twitter/oembed}"
SRC_URI="s3://${SRC_BUCKET}/${SRC_PREFIX}/"
SRC_REMOTE="${SRC_REMOTE:-aws-s3}"

DST_REMOTE="${DST_REMOTE:-minio}"
DST_BUCKET_URI="${DST_BUCKET_URI:-s3://social-data}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_USE_SSL="${MINIO_USE_SSL:-false}"

FORCE_DIR_PULL="${FORCE_DIR_PULL:-true}"
SYNC_MANIFESTS="${SYNC_MANIFESTS:-true}"
CLEAN_LOCAL_FILES="${CLEAN_LOCAL_FILES:-true}"
CLEAN_LOCAL_CACHE="${CLEAN_LOCAL_CACHE:-false}"
AUTO_FIX="${AUTO_FIX:-true}"
# -------------------------------------

import_dir() {
  local SRC="$1"       # s3://bucket/prefix/
  local DST="$2"       # local path to track
  local LABEL="$3"

  echo "==> Tracking ${LABEL} from ${SRC}"
  mkdir -p "$(dirname "${DST}")"

  if [[ ! -f "${DST}.dvc" ]]; then
    if is_true "${FORCE_DIR_PULL}"; then
      echo "FORCE_DIR_PULL=true → standard import for ${LABEL}"
      dvc import-url "${SRC}" "${DST}" -r "${SRC_REMOTE}" --force
    else
      if dvc import-url --to-remote "${SRC}" "${DST}" -r "${SRC_REMOTE}" --force; then
        echo "✅ ${LABEL}: imported with --to-remote"
      else
        echo "⚠️  ${LABEL}: --to-remote failed, fallback to standard import"
        dvc import-url "${SRC}" "${DST}" -r "${SRC_REMOTE}" --force
      fi
    fi
    git add "${DST}.dvc" .gitignore || true
    git commit -m "Import ${LABEL} from ${SRC} via ${SRC_REMOTE}" || true
  else
    echo "==> Updating ${LABEL}"
    # no --force here
    dvc update "${DST}.dvc" || true
    if ! git diff --quiet -- "${DST}.dvc"; then
      git add "${DST}.dvc"
      git commit -m "Update import snapshot for ${LABEL}"
    else
      echo "==> No pointer change for ${LABEL} (already up to date)"
    fi
  fi
}

echo "==> Source S3: ${SRC_URI}"
echo "==> DVC source remote : ${SRC_REMOTE}"
echo "==> DVC dest   remote : ${DST_REMOTE}"

# Ensure MinIO remote is configured
if is_true "${AUTO_FIX}"; then
  dvc remote modify "${DST_REMOTE}" endpointurl "${MINIO_ENDPOINT}" || true
  dvc remote modify "${DST_REMOTE}" use_ssl "${MINIO_USE_SSL}" || true
fi

# Imports
import_dir "${SRC_URI}" "data/tweets" "Tweets directory"
if is_true "${SYNC_MANIFESTS}"; then
  import_dir "${SRC_URI}" "data/tweets-manifests" "Manifests directory"
fi

# Sync cache and push to MinIO
echo "==> Fetching objects from source remote '${SRC_REMOTE}' into cache"
dvc fetch -r "${SRC_REMOTE}" -v

echo "==> Pushing objects to destination remote '${DST_REMOTE}'"
dvc push -r "${DST_REMOTE}" -v

# Optional cleanup
if is_true "${CLEAN_LOCAL_FILES}"; then
  echo "==> Removing local workspace files"
  rm -rf data/tweets data/tweets-manifests || true
fi
if is_true "${CLEAN_LOCAL_CACHE}"; then
  echo "==> Clearing local DVC cache"
  rm -rf .dvc/cache/*
fi

echo "==> Done. MinIO is in sync with the latest snapshot from ${SRC_URI}"
