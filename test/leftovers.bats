#!/usr/bin/env bats
#
# Step 10 deletes files. Everything it deletes is either a superseded
# archive of ours or debris nothing has written to in a month — these
# tests fix both the "does delete" and the far more important "does not
# delete" halves of that.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export TMP
  export HOME="$TMP"
  export BRCS_BACKUP_DIR="$TMP/backups"
  mkdir -p "$BRCS_BACKUP_DIR" "$TMP/.cache" "$TMP/.config" "$TMP/.local/share"
}

teardown() {
  rm -rf "$TMP"
}

# Make a file and set its mtime N days into the past.
aged() {
  local days="$1" path="$2"
  mkdir -p "$(dirname "$path")"
  : > "$path"
  touch -d "$days days ago" "$path"
}

run_leftovers() {
  bash -c 'source "$SCRIPT" >/dev/null
    CLEANUP_SCOPE=safe
    _SAFE_STEPS=" leftovers "
    DRY_RUN="${DRY:-0}"
    full_cleanup' 2>&1
}

@test "keeps the two newest config archives and prunes the rest" {
  aged 40 "$BRCS_BACKUP_DIR/host.confs.20250101.zip"
  aged 30 "$BRCS_BACKUP_DIR/host.confs.20250201.zip"
  aged 20 "$BRCS_BACKUP_DIR/host.confs.20250301.zip"
  aged 10 "$BRCS_BACKUP_DIR/host.confs.20250401.zip"
  run_leftovers >/dev/null
  [ ! -f "$BRCS_BACKUP_DIR/host.confs.20250101.zip" ]
  [ ! -f "$BRCS_BACKUP_DIR/host.confs.20250201.zip" ]
  [ -f "$BRCS_BACKUP_DIR/host.confs.20250301.zip" ]
  [ -f "$BRCS_BACKUP_DIR/host.confs.20250401.zip" ]
}

@test "prunes pre-restore archives on their own count, not pooled" {
  aged 40 "$BRCS_BACKUP_DIR/host.confs.20250101.zip"
  aged 30 "$BRCS_BACKUP_DIR/host.confs.20250201.zip"
  aged 20 "$BRCS_BACKUP_DIR/pre_restore_20250301_000000.zip"
  aged 10 "$BRCS_BACKUP_DIR/pre_restore_20250401_000000.zip"
  run_leftovers >/dev/null
  # Two of each kind, so nothing is old enough to be superseded.
  [ "$(find "$BRCS_BACKUP_DIR" -name '*.zip' | wc -l)" -eq 4 ]
}

@test "sweeps stale debris from the places it is always debris" {
  aged 40 "$TMP/stray.log"
  aged 40 "$TMP/stray.bak"
  aged 40 "$TMP/.cache/old.log"
  aged 40 "$TMP/.config/app/settings.conf.bak"
  aged 40 "$TMP/.local/share/thing.bak"
  run_leftovers >/dev/null
  [ ! -f "$TMP/stray.log" ]
  [ ! -f "$TMP/stray.bak" ]
  [ ! -f "$TMP/.cache/old.log" ]
  [ ! -f "$TMP/.config/app/settings.conf.bak" ]
  [ ! -f "$TMP/.local/share/thing.bak" ]
}

@test "never sweeps a file younger than 30 days" {
  aged 5 "$TMP/recent.log"
  aged 5 "$TMP/.cache/recent.bak"
  run_leftovers >/dev/null
  [ -f "$TMP/recent.log" ]
  [ -f "$TMP/.cache/recent.bak" ]
}

@test "never sweeps a .log an application owns" {
  # Under ~/.config and ~/.local/share only .bak is debris; a .log there
  # may well be the application's real log.
  aged 90 "$TMP/.config/app/app.log"
  aged 90 "$TMP/.local/share/app/session.log"
  run_leftovers >/dev/null
  [ -f "$TMP/.config/app/app.log" ]
  [ -f "$TMP/.local/share/app/session.log" ]
}

@test "never touches anything that is not a .log, .bak or our own archive" {
  aged 90 "$TMP/notes.txt"
  aged 90 "$TMP/.config/app/settings.conf"
  aged 90 "$BRCS_BACKUP_DIR/someone-elses.zip"
  run_leftovers >/dev/null
  [ -f "$TMP/notes.txt" ]
  [ -f "$TMP/.config/app/settings.conf" ]
  [ -f "$BRCS_BACKUP_DIR/someone-elses.zip" ]
}

@test "dry-run reports what it would remove and removes nothing" {
  aged 40 "$BRCS_BACKUP_DIR/host.confs.20250101.zip"
  aged 40 "$BRCS_BACKUP_DIR/host.confs.20250201.zip"
  aged 20 "$BRCS_BACKUP_DIR/host.confs.20250301.zip"
  aged 10 "$BRCS_BACKUP_DIR/host.confs.20250401.zip"
  aged 40 "$TMP/stray.log"
  DRY=1 run_leftovers | grep -q "Would prune 2 old archive(s) and sweep 1 stale"
  [ -f "$BRCS_BACKUP_DIR/host.confs.20250101.zip" ]
  [ -f "$TMP/stray.log" ]
}
