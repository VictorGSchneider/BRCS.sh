#!/usr/bin/env bats
#
# check_root is the guard that keeps an unattended run from spending the
# account's pam_faillock budget at the login screen. Exercise it as a
# non-root user, which is the only case where it does anything: the suite
# itself may well be running as root, so `id` is stubbed rather than
# assumed.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export TMP HOME="$TMP"
  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"
  PATH_SAVE="$PATH"
  export PATH="$STUBS:$PATH"
}

teardown() {
  export PATH="$PATH_SAVE"
  rm -rf "$TMP"
}

# Pretend to be an unprivileged user.
stub_nonroot() {
  cat <<'EOS' > "$STUBS/id"
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
EOS
  chmod +x "$STUBS/id"
}

# A sudo that would prompt: `sudo -n` fails, everything else succeeds.
stub_sudo_needs_password() {
  cat <<'EOS' > "$STUBS/sudo"
#!/bin/bash
[ "${1:-}" = "-n" ] && exit 1
exec "$@"
EOS
  chmod +x "$STUBS/sudo"
}

# A sudo already granted NOPASSWD: `sudo -n` succeeds.
stub_sudo_nopasswd() {
  cat <<'EOS' > "$STUBS/sudo"
#!/bin/bash
[ "${1:-}" = "-n" ] && shift
exec "$@"
EOS
  chmod +x "$STUBS/sudo"
}

check_root_status() {
  # Bats gives the test no controlling terminal, which is exactly the
  # condition under test: nothing to prompt a password on.
  bash -c 'source "$SCRIPT" >/dev/null; DRY_RUN="${DRY:-0}"; check_root' </dev/null
}

@test "root needs no further checks" {
  # No id stub: whatever the suite runs as, the sudo-less branch below
  # covers the other side.
  run bash -c 'source "$SCRIPT" >/dev/null
    id() { [ "$1" = "-u" ] && echo 0; }
    check_root'
  [ "$status" -eq 0 ]
}

@test "refuses when it is not root and sudo is not installed" {
  run bash -c 'source "$SCRIPT" >/dev/null
    id() { [ "$1" = "-u" ] && echo 1000; }
    command() { if [ "$2" = "sudo" ]; then return 1; fi; builtin command "$@"; }
    check_root'
  [ "$status" -eq 1 ]
  [[ "$output" == *"sudo is not installed"* ]]
}

@test "refuses when a password is needed and there is no terminal to ask on" {
  stub_nonroot
  stub_sudo_needs_password
  run check_root_status
  [ "$status" -eq 1 ]
  [[ "$output" == *"no terminal to ask for a password"* ]]
}

@test "allows it when sudo is already granted NOPASSWD" {
  stub_nonroot
  stub_sudo_nopasswd
  run check_root_status
  [ "$status" -eq 0 ]
}

@test "--dry-run is exempt: it executes nothing, so there is nothing to authenticate" {
  # Without this, the one mode that is safe to run unattended would be the
  # one mode you could not run unattended.
  stub_nonroot
  stub_sudo_needs_password
  DRY=1 run check_root_status
  [ "$status" -eq 0 ]
}

@test "a piped --cleanup --dry-run still completes as an unprivileged user" {
  stub_nonroot
  stub_sudo_needs_password
  run bash "$SCRIPT" --cleanup --dry-run </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Full cleanup completed"* ]]
}

@test "a piped --cleanup refuses as an unprivileged user" {
  stub_nonroot
  stub_sudo_needs_password
  run bash "$SCRIPT" --cleanup </dev/null
  [[ "$output" == *"no terminal to ask for a password"* ]]
  [[ "$output" != *"cleanup completed"* ]]
}
