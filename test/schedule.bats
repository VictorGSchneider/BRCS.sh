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

  # systemctl is stubbed per-test rather than inherited from the host: a
  # GitHub runner has a live --user manager and a container has none, and
  # the branch taken must not depend on which one you are standing in.
  export SYSTEMCTL_LOG="$TMP/systemctl.calls"
  : > "$SYSTEMCTL_LOG"

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
  stub_systemctl_absent
  run bash -c 'source "$SCRIPT" >/dev/null
    # Pretend systemctl is absent so the crontab branch is taken.
    systemctl() { return 127; }
    command() { if [ "$2" = "systemctl" ]; then return 1; fi; builtin command "$@"; }
    schedule_cleanup'
  [ "$status" -eq 0 ]
  grep -q -- "--cleanup --unattended" "$ROOT_CRONTAB"
  [ ! -s "$USER_CRONTAB" ]
}

@test "the source never schedules a privileged job in the user's crontab" {
  # The hazard is scheduling a job that will need sudo with no terminal to
  # authenticate on. The tell is a cron schedule token reaching a bare
  # `crontab -`. A pure filter pipeline emits no schedule, and a job that
  # is explicitly --user needs no privileges, so neither is the bug.
  while IFS= read -r line; do
    case "$line" in
      *"sudo crontab -"*) continue ;;   # root's crontab is already privileged
      *"--user"*)         continue ;;   # an unprivileged job; nothing to auth
    esac
    case "$line" in
      *@reboot*|*@daily*|*@weekly*|*@hourly*|*@monthly*|*CRON_CMD*|*cron_line*)
        echo "schedules a privileged job in the user crontab: $line"; return 1 ;;
    esac
  done < <(grep -nE "\\|[[:space:]]*crontab[[:space:]]+-[[:space:]]*$" "$SCRIPT")
}

@test "_unschedule_user_crontab keeps a legitimate --user entry" {
  # --schedule --user writes one of these. The legacy sweep runs on every
  # schedule_cleanup, and matching on the filename alone would delete the
  # entry the previous run just created.
  printf '@daily bash /home/me/BRCS.sh --cleanup --user\n@reboot bash /home/me/BRCS.sh --cleanup\n' > "$USER_CRONTAB"
  run bash -c 'source "$SCRIPT" >/dev/null; _unschedule_user_crontab'
  [ "$status" -eq 0 ]
  grep -q -- "--cleanup --user" "$USER_CRONTAB"
  run grep -q "cleanup$" "$USER_CRONTAB"
  [ "$status" -ne 0 ]
}

@test "_unschedule_user_crontab preserves the order of what it keeps" {
  printf 'a /one\n@reboot bash /home/me/BRCS.sh --cleanup\nb /two\n' > "$USER_CRONTAB"
  run bash -c 'source "$SCRIPT" >/dev/null; _unschedule_user_crontab'
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$USER_CRONTAB")" = "a /one" ]
  [ "$(sed -n 2p "$USER_CRONTAB")" = "b /two" ]
}

# No user manager: show-environment fails, so the cron path is taken.
stub_systemctl_absent() {
  cat <<'EOS' > "$STUBS/systemctl"
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
exit 1
EOS
  chmod +x "$STUBS/systemctl"
}

# A live user manager that accepts everything.
stub_systemctl_working() {
  cat <<'EOS' > "$STUBS/systemctl"
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
exit 0
EOS
  chmod +x "$STUBS/systemctl"
}

# Answers show-environment but refuses to enable — a real shape, and the
# one where reporting success would be a lie.
stub_systemctl_cannot_enable() {
  cat <<'EOS' > "$STUBS/systemctl"
#!/bin/bash
echo "$*" >> "$SYSTEMCTL_LOG"
case "$*" in *enable*) exit 1 ;; esac
exit 0
EOS
  chmod +x "$STUBS/systemctl"
}

@test "--schedule --user installs a systemd --user timer when one can run" {
  stub_systemctl_working
  run bash "$SCRIPT" --schedule --user </dev/null
  [ "$status" -eq 0 ]
  [ -f "$HOME/.config/systemd/user/brcs-cleanup.timer" ]
  grep -q -- "--cleanup --user" "$HOME/.config/systemd/user/brcs-cleanup.service"
  grep -q "enable --now brcs-cleanup.timer" "$SYSTEMCTL_LOG"
  # Nothing privileged, and no cron entry when the timer took.
  [ ! -s "$ROOT_CRONTAB" ]
  [ ! -s "$USER_CRONTAB" ]
}

@test "--schedule --user falls back to the user's own crontab with no user manager" {
  stub_systemctl_absent
  run bash "$SCRIPT" --schedule --user </dev/null
  [ "$status" -eq 0 ]
  grep -q -- "--cleanup --user" "$USER_CRONTAB"
  # It must never reach for root here.
  [ ! -s "$ROOT_CRONTAB" ]
}

@test "--schedule --user falls back rather than claim a timer it could not enable" {
  stub_systemctl_cannot_enable
  run bash "$SCRIPT" --schedule --user </dev/null
  [ "$status" -eq 0 ]
  # No half-installed units left for a later daemon-reload to find.
  [ ! -f "$HOME/.config/systemd/user/brcs-cleanup.timer" ]
  [ ! -f "$HOME/.config/systemd/user/brcs-cleanup.service" ]
  # And it actually scheduled something, by the other route.
  grep -q -- "--cleanup --user" "$USER_CRONTAB"
}

@test "--schedule --user is idempotent" {
  stub_systemctl_absent
  bash "$SCRIPT" --schedule --user </dev/null >/dev/null 2>&1
  bash "$SCRIPT" --schedule --user </dev/null >/dev/null 2>&1
  [ "$(grep -c -- "--cleanup --user" "$USER_CRONTAB")" -eq 1 ]
}

@test "--schedule --dry-run changes nothing" {
  : > "$USER_CRONTAB"
  run bash "$SCRIPT" --schedule --user --dry-run </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [ ! -s "$USER_CRONTAB" ]
  [ ! -s "$ROOT_CRONTAB" ]
}
