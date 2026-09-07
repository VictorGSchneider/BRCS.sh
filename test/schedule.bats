#!/usr/bin/env bats
#
# Scheduling has to end up with a *privileged* job. A @reboot line in the
# invoking user's crontab runs unprivileged with no terminal, so every
# sudo inside it is a PAM "conversation failed" that pam_faillock counts
# — three of those and the account is locked at the login screen on the
# next boot. These tests pin that down.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export TMP
  export HOME="$TMP"
  export USER_CRONTAB="$TMP/user.crontab"
  export ROOT_CRONTAB="$TMP/root.crontab"
  : > "$USER_CRONTAB"
  : > "$ROOT_CRONTAB"

  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"

  # crontab stub: -l prints the file, - reads stdin into it. Which file
  # depends on whether we were reached through the sudo stub.
  cat <<'EOS' > "$STUBS/crontab"
#!/bin/bash
target="${CRONTAB_TARGET:-$USER_CRONTAB}"
case "${1:-}" in
  -l) cat "$target" ;;
  -)  # Real crontab consumes all of stdin before installing; do the
      # same so a read-into-write pipeline is not a truncation race.
      tmp=$(mktemp); cat > "$tmp"; mv "$tmp" "$target" ;;
  *)  exit 2 ;;
esac
EOS
  chmod +x "$STUBS/crontab"

  cat <<'EOS' > "$STUBS/sudo"
#!/bin/bash
[ "${1:-}" = "-n" ] && shift
export CRONTAB_TARGET="$ROOT_CRONTAB"
exec "$@"
EOS
  chmod +x "$STUBS/sudo"

  # No systemd on this fake host, so the crontab branch is the one taken.
  cat <<'EOS' > "$STUBS/systemctl"
#!/bin/bash
exit 127
EOS
  : > "$STUBS/.keep"

  PATH_SAVE="$PATH"
  export PATH="$STUBS:$PATH"
}

teardown() {
  export PATH="$PATH_SAVE"
  rm -rf "$TMP"
}

@test "_unschedule_user_crontab drops a legacy BRCS.sh @reboot line" {
  printf '@reboot bash /home/me/BRCS.sh --cleanup\n0 3 * * * /usr/bin/backup-my-photos\n' > "$USER_CRONTAB"
  run bash -c 'source "$SCRIPT" >/dev/null; _unschedule_user_crontab'
  [ "$status" -eq 0 ]
  run grep -q "BRCS.sh --cleanup" "$USER_CRONTAB"
  [ "$status" -ne 0 ]
  # Anything that is not ours stays.
  grep -q "backup-my-photos" "$USER_CRONTAB"
}

@test "_unschedule_user_crontab also drops the line a fork wrote under its own name" {
  printf '@reboot bash /home/me/scripts/stoa-maintain.sh --cleanup\n' > "$USER_CRONTAB"
  run bash -c 'source "$SCRIPT" >/dev/null; _unschedule_user_crontab'
  [ "$status" -eq 0 ]
  [ ! -s "$USER_CRONTAB" ]
}

@test "_unschedule_user_crontab leaves an unrelated crontab untouched" {
  printf '0 3 * * * /usr/bin/backup-my-photos\n' > "$USER_CRONTAB"
  before=$(cat "$USER_CRONTAB")
  run bash -c 'source "$SCRIPT" >/dev/null; _unschedule_user_crontab'
  [ "$status" -eq 0 ]
  [ "$(cat "$USER_CRONTAB")" = "$before" ]
}

@test "schedule_cleanup without systemd writes to root's crontab, not the user's" {
  run bash -c 'source "$SCRIPT" >/dev/null
    # Pretend systemctl is absent so the crontab branch is taken.
    systemctl() { return 127; }
    command() { if [ "$2" = "systemctl" ]; then return 1; fi; builtin command "$@"; }
    schedule_cleanup'
  [ "$status" -eq 0 ]
  grep -q -- "--cleanup --unattended" "$ROOT_CRONTAB"
  [ ! -s "$USER_CRONTAB" ]
}

@test "the source never pipes a scheduled job into the user's crontab" {
  # Writing to a bare `crontab -` (as opposed to `sudo crontab -`) installs
  # an unprivileged job. The one legitimate use is the reverse: a `grep -v`
  # filter that only ever removes lines. Any other bare write is a bug.
  while IFS= read -r line; do
    case "$line" in
      *"sudo crontab -"*) continue ;;
      *"grep -v"*)        continue ;;
      *) echo "unprivileged crontab write: $line"; return 1 ;;
    esac
  done < <(grep -nE "\|[[:space:]]*crontab[[:space:]]+-[[:space:]]*$" "$SCRIPT")
}
