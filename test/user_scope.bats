#!/usr/bin/env bats
#
# --user exists for a machine you do not administer. Its whole promise is
# that it never invokes sudo — not once, not on a step that "probably
# succeeds anyway". A single stray sudo on a locked-down box is a PAM
# prompt with nobody to answer it, which is how this script locked a
# login screen in the first place.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export TMP HOME="$TMP"
  # Never let the suite sweep the real /tmp. This step deletes files.
  export BRCS_TMP_DIRS="$TMP/scratch"
  mkdir -p "$TMP/scratch"
  export SUDO_LOG="$TMP/sudo.calls"
  : > "$SUDO_LOG"
  STUBS="$TMP/stubs"
  mkdir -p "$STUBS"

  # A sudo that records every call and refuses, the way a machine without
  # permission would. Anything reaching it is a bug in the scope gate.
  cat <<'EOS' > "$STUBS/sudo"
#!/bin/bash
echo "$*" >> "$SUDO_LOG"
exit 1
EOS
  chmod +x "$STUBS/sudo"

  # Not root, so check_root would otherwise refuse.
  cat <<'EOS' > "$STUBS/id"
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
[ "${1:-}" = "-un" ] && { echo tester; exit 0; }
exec /usr/bin/id "$@"
EOS
  chmod +x "$STUBS/id"

  PATH_SAVE="$PATH"
  export PATH="$STUBS:$PATH"
}

teardown() {
  export PATH="$PATH_SAVE"
  rm -rf "$TMP"
}

@test "a real --cleanup --user run never invokes sudo" {
  # Not a dry run: the commands actually execute.
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_LOG" ] || { echo "sudo was called:"; cat "$SUDO_LOG"; return 1; }
}

@test "a dry --cleanup --user run never invokes sudo either" {
  run bash "$SCRIPT" --cleanup --user --dry-run </dev/null
  [ "$status" -eq 0 ]
  [ ! -s "$SUDO_LOG" ] || { echo "sudo was called:"; cat "$SUDO_LOG"; return 1; }
}

@test "--cleanup --user succeeds as an unprivileged user with no terminal" {
  # The shape of the problem: no root, no tty. The privileged scopes
  # refuse here on purpose; this one is the answer to that.
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"User cleanup completed"* ]]
  [[ "$output" != *"no terminal to ask for a password"* ]]
}

@test "the privileged scopes still refuse there, and point at --user" {
  run bash "$SCRIPT" --cleanup </dev/null
  [[ "$output" == *"no terminal to ask for a password"* ]]
  [[ "$output" == *"--cleanup --user"* ]]
}

@test "it clears regenerable caches but not the rest of ~/.cache" {
  mkdir -p "$HOME/.cache/thumbnails/large" "$HOME/.cache/some-app"
  touch "$HOME/.cache/thumbnails/large/a.png" "$HOME/.cache/some-app/state.db"
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.cache/thumbnails/large/a.png" ]
  # ~/.cache is not cleared wholesale: applications keep real state there.
  [ -f "$HOME/.cache/some-app/state.db" ]
}

@test "it clears the Steam shader cache but never compatdata" {
  mkdir -p "$HOME/.steam/steam/steamapps/shadercache/440"
  mkdir -p "$HOME/.steam/steam/steamapps/compatdata/440"
  touch "$HOME/.steam/steam/steamapps/shadercache/440/cache.bin"
  touch "$HOME/.steam/steam/steamapps/compatdata/440/save.dat"
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.steam/steam/steamapps/shadercache/440/cache.bin" ]
  [ -f "$HOME/.steam/steam/steamapps/compatdata/440/save.dat" ]
}

@test "the scratch sweep takes this user's files and leaves others alone" {
  # Real files with real ownership, in a sandbox — not the machine's /tmp.
  touch "$TMP/scratch/mine.txt"
  touch "$TMP/scratch/theirs.txt"
  # nobody(65534) exists on essentially every Linux image; skip if not.
  chown 65534 "$TMP/scratch/theirs.txt" 2>/dev/null || skip "cannot chown"

  # id -un is stubbed to "tester"; point it at the real current user so the
  # -user predicate matches what actually owns mine.txt.
  rm -f "$STUBS/id"
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/scratch/mine.txt" ]
  [ -f "$TMP/scratch/theirs.txt" ]
}

@test "the sweep respects BRCS_TMP_DIRS and touches nothing outside it" {
  local outside="$TMP/not-scratch"
  mkdir -p "$outside"
  touch "$outside/keep.txt" "$TMP/scratch/go.txt"
  rm -f "$STUBS/id"
  run bash "$SCRIPT" --cleanup --user </dev/null
  [ "$status" -eq 0 ]
  [ -f "$outside/keep.txt" ]
}
