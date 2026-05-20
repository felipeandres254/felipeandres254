#!/bin/sh
set -eu

# ──────────────────────────────────────────────────────────────────
# backup.sh — upload/restore private files to/from S3
# ──────────────────────────────────────────────────────────────────
# Usage:
#   ./backup.sh                  upload files listed in .s3backup
#   ./backup.sh --restore        restore latest backup from S3
#
# Credentials (env — set via GitHub Codespace secrets):
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AWS_REGION               (default: us-east-1)
#   AWS_S3_BUCKET            (required for S3 ops)
#
# File list:
#   .s3backup in workspace root — one glob per line, # comments
#   If .s3backup doesn't exist: upload silently exits, restore skips.
#
# Retry mechanism:
#   --restore with missing credentials creates a pending flag.
#   .crontab retries every 5 min via --retry-restore.
#   Once restore succeeds the flag is removed and retry stops.
# ──────────────────────────────────────────────────────────────────

WORKSPACE="${WORKSPACE:-/workspaces/felipeandres254}"
REGION="${AWS_REGION:-us-east-1}"
S3BACKUP="$WORKSPACE/.s3backup"
RESTORE_PENDING="$WORKSPACE/.backup-restore-pending"
export AWS_DEFAULT_REGION="$REGION"
MODE="${1:-upload}"

has_credentials() {
  [ -n "${AWS_S3_BUCKET:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]
}

# ── Upload ────────────────────────────────────────────────────────
do_upload() {
  [ -f "$S3BACKUP" ] || { echo "No .s3backup — nothing to upload."; exit 0; }

  DATE=$(date -u +%Y%m%dT%H%M%SZ)
  PREFIX="backup/$DATE"

  echo "Upload to s3://${AWS_S3_BUCKET:?}/$PREFIX/"

  while IFS= read -r LINE; do
    LINE=${LINE%%#*}
    LINE=$(echo "$LINE" | xargs)
    [ -z "$LINE" ] && continue

    for MATCH in $WORKSPACE/$LINE; do
      [ -e "$MATCH" ] || continue
      REL=${MATCH#"$WORKSPACE/"}
      if [ -d "$MATCH" ]; then
        aws s3 sync "$MATCH" "s3://$AWS_S3_BUCKET/$PREFIX/$REL/" --quiet && echo "  ✓  $REL/"
      elif [ -f "$MATCH" ]; then
        aws s3 cp "$MATCH" "s3://$AWS_S3_BUCKET/$PREFIX/$REL" --quiet && echo "  ✓  $REL"
      fi
    done
  done < "$S3BACKUP"

  echo "$DATE" | aws s3 cp - "s3://$AWS_S3_BUCKET/backup/latest.txt" --quiet
  echo "Done — s3://$AWS_S3_BUCKET/$PREFIX/"
}

# ── Restore ───────────────────────────────────────────────────────
do_restore() {
  [ -f "$S3BACKUP" ] || { echo "No .s3backup — nothing to restore."; exit 0; }

  LATEST=$(aws s3 cp "s3://$AWS_S3_BUCKET/backup/latest.txt" - 2>/dev/null || true)
  [ -z "$LATEST" ] && { echo "No backup found. Skipping restore."; exit 0; }

  PREFIX="backup/$LATEST"
  echo "Restore from s3://$AWS_S3_BUCKET/$PREFIX/"

  while IFS= read -r LINE; do
    LINE=${LINE%%#*}
    LINE=$(echo "$LINE" | xargs)
    [ -z "$LINE" ] && continue

    for MATCH in $WORKSPACE/$LINE; do
      [ -e "$MATCH" ] || continue
      REL=${MATCH#"$WORKSPACE/"}
      DEST="$MATCH"
      SRC="s3://$AWS_S3_BUCKET/$PREFIX/$REL"
      if aws s3 ls "$SRC/" >/dev/null 2>&1; then
        aws s3 sync "$SRC/" "$DEST/" --quiet && echo "  ✓  $REL/  restored"
      elif aws s3 ls "$SRC" >/dev/null 2>&1; then
        aws s3 cp "$SRC" "$DEST" --quiet && echo "  ✓  $REL  restored"
      fi
    done
  done < "$S3BACKUP"

  echo "Restore complete — s3://$AWS_S3_BUCKET/$PREFIX/"
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
    # No creds yet → exit silently, cron retries later
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
