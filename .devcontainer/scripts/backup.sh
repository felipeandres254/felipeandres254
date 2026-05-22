#!/bin/sh
set -eu

# ──────────────────────────────────────────────────────────────────
# backup.sh — incremental upload/restore private files to/from S3
# ──────────────────────────────────────────────────────────────────
# Usage:
#   ./backup.sh                  upload files listed in .s3backup
#   ./backup.sh --restore        restore from S3
#
# Credentials (env — set via Codespace secrets or .env file):
#   S3_BACKUP_BASE     e.g. s3://my-bucket/some-prefix/
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_REGION         (default: us-east-1)
#
# File list:
#   .s3backup in workspace root — one glob per line, # comments
#   If .s3backup doesn't exist: upload silently exits, restore skips.
#
# Sync style:
#   Directories use aws s3 sync — mtime-based, only transfers changes.
#   Files use a local mtime cache — zero S3 calls when unchanged.
#   No timestamps — always writes to the same base path.
#
# Retry:
#   --restore with missing credentials creates a pending flag.
#   .crontab retries every 5 min via --retry-restore.
#   Once restore succeeds the flag is removed and retry stops.
# ──────────────────────────────────────────────────────────────────

# Ensure /usr/local/bin is on PATH (needed for cron which has a minimal PATH)
export PATH="/usr/local/bin:$PATH"

WORKSPACE="${WORKSPACE:-/workspaces/felipeandres254}"
S3BACKUP="$WORKSPACE/.s3backup"
RESTORE_PENDING="$WORKSPACE/.backup-restore-pending"
CACHEDIR="$WORKSPACE/.backup-cache"
MODE="${1:-upload}"

# Load .env so cron invocations pick up credentials
[ -f "$WORKSPACE/.env" ] && . "$WORKSPACE/.env"

# Export AWS vars so the aws CLI child process can see them
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

# Derive base S3 path: prefer S3_BACKUP_BASE, fall back to bucket + "backup/"
if [ -n "${S3_BACKUP_BASE:-}" ]; then
  S3_BASE="$S3_BACKUP_BASE"
else
  S3_BASE="s3://${AWS_S3_BUCKET:?AWS_S3_BUCKET or S3_BACKUP_BASE required}/backup/"
fi

has_credentials() {
  { [ -n "${S3_BACKUP_BASE:-}" ] || [ -n "${AWS_S3_BUCKET:-}" ]; } &&
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]
}

# ── Upload (incremental) ──────────────────────────────────────────
do_upload() {
  [ -f "$S3BACKUP" ] || { echo "No .s3backup — nothing to upload."; exit 0; }
  mkdir -p "$CACHEDIR"

  # Snapshot opencode session db + skills into workspace so .s3backup picks them up
  OCODE_DB="$HOME/.local/share/opencode"
  if [ -d "$OCODE_DB" ]; then
    mkdir -p "$WORKSPACE/.opencode"
    cp "$OCODE_DB"/opencode.db* "$WORKSPACE/.opencode/" 2>/dev/null || true
  fi
  OCODE_SKILLS="$HOME/.config/opencode/skills"
  if [ -d "$OCODE_SKILLS" ]; then
    mkdir -p "$WORKSPACE/.opencode/skills"
    rsync -a "$OCODE_SKILLS/" "$WORKSPACE/.opencode/skills/"
  fi

  echo "Syncing to ${S3_BASE}"

  while IFS= read -r LINE; do
    LINE=${LINE%%#*}
    LINE=$(echo "$LINE" | xargs)
    [ -z "$LINE" ] && continue

    for MATCH in $WORKSPACE/$LINE; do
      [ -e "$MATCH" ] || continue
      REL=${MATCH#"$WORKSPACE/"}
      REL=${REL%/}
      if [ -d "$MATCH" ]; then
        aws s3 sync "$MATCH" "${S3_BASE}${REL}/" --quiet && echo "  ✓  $REL/"
      elif [ -f "$MATCH" ]; then
        CACHEKEY=$(echo "$REL" | md5sum - 2>/dev/null | cut -d' ' -f1 || echo "$REL")
        CACHED_MTIME=$(cat "$CACHEDIR/$CACHEKEY" 2>/dev/null || echo "0")
        CURRENT_MTIME=$(stat -c %Y "$MATCH" 2>/dev/null || echo "0")
        if [ "$CURRENT_MTIME" != "$CACHED_MTIME" ]; then
          aws s3 cp "$MATCH" "${S3_BASE}${REL}" --quiet && \
            echo "$CURRENT_MTIME" > "$CACHEDIR/$CACHEKEY" && \
            echo "  ✓  $REL"
        else
          echo "  -  $REL  (unchanged)"
        fi
      fi
    done
  done < "$S3BACKUP"

  echo "Done — ${S3_BASE}"
}

# ── Restore ───────────────────────────────────────────────────────
do_restore() {
  [ -f "$S3BACKUP" ] || { echo "No .s3backup — nothing to restore."; exit 0; }

  echo "Restoring from ${S3_BASE}"

  while IFS= read -r LINE; do
    LINE=${LINE%%#*}
    LINE=$(echo "$LINE" | xargs)
    [ -z "$LINE" ] && continue

    for MATCH in $WORKSPACE/$LINE; do
      [ -e "$MATCH" ] || continue
      REL=${MATCH#"$WORKSPACE/"}
      DEST="$MATCH"
      SRC="${S3_BASE}${REL}"
      if aws s3 ls "${SRC}/" >/dev/null 2>&1; then
        aws s3 sync "${SRC}/" "${DEST}/" --quiet && echo "  ✓  ${REL}/  restored"
      elif aws s3 ls "${SRC}" >/dev/null 2>&1; then
        aws s3 cp "${SRC}" "${DEST}" --quiet && echo "  ✓  ${REL}  restored"
      fi
    done
  done < "$S3BACKUP"

  # Restore clears mtime cache — next upload re-uploads as needed
  rm -rf "$CACHEDIR"

  # Restore opencode session db + skills from workspace back to their homes
  OCODE_DB="$HOME/.local/share/opencode"
  if [ -f "$WORKSPACE/.opencode/opencode.db" ]; then
    mkdir -p "$OCODE_DB"
    cp "$WORKSPACE/.opencode/opencode.db"* "$OCODE_DB/" 2>/dev/null || true
    echo "  ✓  opencode session db restored"
  fi
  OCODE_SKILLS_TARGET="$HOME/.config/opencode/skills"
  if [ -d "$WORKSPACE/.opencode/skills" ]; then
    mkdir -p "$OCODE_SKILLS_TARGET"
    rsync -a "$WORKSPACE/.opencode/skills/" "$OCODE_SKILLS_TARGET/"
    echo "  ✓  skills restored"
  fi

  echo "Restore complete — ${S3_BASE}"
}

# ── Main ──────────────────────────────────────────────────────────
case "$MODE" in
  --restore|-r|restore)
    if has_credentials; then
      do_restore
      rm -f "$RESTORE_PENDING"
    else
      touch "$RESTORE_PENDING"
      echo "AWS credentials not available. Retry scheduled via crontab."
    fi
    ;;
  --retry-restore)
    if has_credentials; then
      do_restore
      rm -f "$RESTORE_PENDING"
    fi
    ;;
  upload|--upload|-u)
    if ! has_credentials; then
      echo "No AWS credentials — skipping upload."; exit 0
    fi
    do_upload
    ;;
  *)
    echo "Usage: $0 [--restore|upload]" >&2
    exit 1
    ;;
esac
