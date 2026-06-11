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

# AWS CLI timeout — prevents hangs on network/credential issues
_CLI_READ_TIMEOUT="${CLI_READ_TIMEOUT:-30}"
_CLI_CONNECT_TIMEOUT="${CLI_CONNECT_TIMEOUT:-10}"
_AWS="aws --cli-read-timeout $_CLI_READ_TIMEOUT --cli-connect-timeout $_CLI_CONNECT_TIMEOUT"

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

  TOTAL_START=$(date +%s)

  # S3 sync picks up .opencode/opencode.db* via .s3backup glob -- no copy needed
  WOKWI="$HOME/.wokwi"
  if [ -d "$WOKWI" ]; then
    mkdir -p "$WORKSPACE/.wokwi"
    rsync -a "$WOKWI/" "$WORKSPACE/.wokwi/"
  fi

  OCODE_SKILLS="$HOME/.config/opencode/skills"
  if [ -d "$OCODE_SKILLS" ]; then
    mkdir -p "$WORKSPACE/.opencode/skills"
    rsync -a "$OCODE_SKILLS/" "$WORKSPACE/.opencode/skills/"
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Syncing to ${S3_BASE}"

  MANIFEST_FILE="$CACHEDIR/.manifest"
  MANIFEST_NEXT="$CACHEDIR/.manifest.next"
  : > "$MANIFEST_NEXT"

  while IFS= read -r LINE; do
    LINE=${LINE%%#*}
    LINE=$(echo "$LINE" | xargs)
    [ -z "$LINE" ] && continue

    for MATCH in $WORKSPACE/$LINE; do
      [ -e "$MATCH" ] || continue
      REL=${MATCH#"$WORKSPACE/"}
      REL=${REL%/}

      ITEM_START=$(date +%s)

      if [ -d "$MATCH" ]; then
        $_AWS s3 sync "$MATCH" "${S3_BASE}${REL}/" --delete --quiet && \
          echo "  ✓  $REL/  ($(($(date +%s) - ITEM_START))s)"
      elif [ -f "$MATCH" ]; then
        echo "$REL" >> "$MANIFEST_NEXT"
        CACHEKEY=$(echo "$REL" | md5sum - 2>/dev/null | cut -d' ' -f1 || echo "$REL")
        CACHED_MTIME=$(cat "$CACHEDIR/$CACHEKEY" 2>/dev/null || echo "0")
        CURRENT_MTIME=$(stat -c %Y "$MATCH" 2>/dev/null || echo "0")
        if [ "$CURRENT_MTIME" != "$CACHED_MTIME" ]; then
          $_AWS s3 cp "$MATCH" "${S3_BASE}${REL}" --quiet && \
            echo "$CURRENT_MTIME" > "$CACHEDIR/$CACHEKEY" && \
            echo "  ✓  $REL  ($(($(date +%s) - ITEM_START))s)"
        else
          echo "  -  $REL  (unchanged)"
        fi
      fi
    done
  done < "$S3BACKUP"

  # ── Cleanup pass: delete stale singleton files from S3 ──────────
  # Compare this run's manifest against the previous run's manifest.
  # Any file in the old manifest but not in the current one was removed locally.
  if [ -f "$MANIFEST_FILE" ]; then
    while IFS= read -r STALE; do
      [ -n "$STALE" ] || continue
      ITEM_START=$(date +%s)
      if $_AWS s3 rm "${S3_BASE}${STALE}" --quiet 2>/dev/null; then
        CACHEKEY=$(echo "$STALE" | md5sum - 2>/dev/null | cut -d' ' -f1)
        [ -n "$CACHEKEY" ] && rm -f "$CACHEDIR/$CACHEKEY"
        echo "  ✗  $STALE  (stale)  ($(($(date +%s) - ITEM_START))s)"
      fi
    done <<STALE_EOF
$(grep -v -x -F -f "$MANIFEST_NEXT" "$MANIFEST_FILE" || true)
STALE_EOF
  fi
  mv "$MANIFEST_NEXT" "$MANIFEST_FILE"

  echo "Done — ${S3_BASE}  (total: $(($(date +%s) - TOTAL_START))s)"
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
      if $_AWS s3 ls "${SRC}/" >/dev/null 2>&1; then
        $_AWS s3 sync "${SRC}/" "${DEST}/" --quiet && echo "  ✓  ${REL}/  restored"
      elif $_AWS s3 ls "${SRC}" >/dev/null 2>&1; then
        $_AWS s3 cp "${SRC}" "${DEST}" --quiet && echo "  ✓  ${REL}  restored"
      fi
    done
  done < "$S3BACKUP"

  # Restore clears mtime cache — next upload re-uploads as needed
  rm -rf "$CACHEDIR"

  # Restore Wokwi state from workspace copy to home
  WOKWI_TARGET="$HOME/.wokwi"
  if [ -d "$WORKSPACE/.wokwi" ]; then
    mkdir -p "$WOKWI_TARGET"
    rsync -a "$WORKSPACE/.wokwi/" "$WOKWI_TARGET/"
    echo "  ✓  .wokwi/ restored"
  fi

  # Ensure global opencode.db resolves to workspace (DB restored by S3 sync via .s3backup)
  mkdir -p "$HOME/.local/share/opencode"
  rm -f "$HOME/.local/share/opencode/opencode.db"
  ln -sf "$WORKSPACE/.opencode/opencode.db" "$HOME/.local/share/opencode/opencode.db"
  echo "  ✓  opencode session db linked"

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
    echo; exit 0;
    ;;
  --retry-restore)
    if has_credentials; then
      do_restore
      rm -f "$RESTORE_PENDING"
    fi
    echo; exit 0;
    ;;
  upload|--upload|-u)
    if ! has_credentials; then
      echo "No AWS credentials — skipping upload.";
      echo; exit 0;
    fi
    do_upload
    echo; exit 0;
    ;;
  *)
    echo "Usage: $0 [--restore|upload]" >&2
    echo; exit 1;
    ;;
esac
