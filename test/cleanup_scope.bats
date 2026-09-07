#!/usr/bin/env bats
#
# The safe subset that --unattended selects, and the step gate behind it.
# These run against a sourced script, so nothing here touches the system.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export HOME="$TMP"
}

teardown() {
  rm -rf "$TMP"
}

@test "_step lets every step through in full scope" {
  run bash -c 'source "$SCRIPT" >/dev/null
    for s in update clean autoremove snap flatpak journal kernels docker steam leftovers tmp; do
      _step "$s" || { echo "full scope rejected $s"; exit 1; }
    done'
  [ "$status" -eq 0 ]
}

@test "_step in safe scope keeps only the non-destructive steps" {
  run bash -c 'source "$SCRIPT" >/dev/null
    CLEANUP_SCOPE=safe
    for s in clean flatpak journal leftovers tmp; do
      _step "$s" || { echo "safe scope rejected $s"; exit 1; }
    done'
  [ "$status" -eq 0 ]
}

@test "_step in safe scope refuses the steps that change what is installed" {
  run bash -c 'source "$SCRIPT" >/dev/null
    CLEANUP_SCOPE=safe
    for s in update autoremove kernels docker steam snap; do
      _step "$s" && { echo "safe scope allowed $s"; exit 1; }
    done
    exit 0'
  [ "$status" -eq 0 ]
}

@test "--cleanup --unattended --dry-run runs the safe scope end to end" {
  run bash "$SCRIPT" --cleanup --unattended --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting safe cleanup"* ]]
  [[ "$output" == *"Safe cleanup completed"* ]]
  # The steps the safe scope drops must not run.
  [[ "$output" != *"apt-get upgrade"* ]]
  [[ "$output" != *"apt-get autoremove"* ]]
  [[ "$output" != *"docker system prune"* ]]
  [[ "$output" != *"Steam shader cache"* ]]
}

@test "the progress bar reaches 100% in both scopes" {
  # The step gate and the steps array are two separate lists; if they
  # disagree the bar overshoots or stops short. That is the only visible
  # symptom, so assert on it directly.
  for flags in "--cleanup --dry-run" "--cleanup --unattended --dry-run"; do
    # shellcheck disable=SC2086
    last=$(bash "$SCRIPT" $flags 2>&1 | tr '\r' '\n' | grep -oE '[0-9]+%' | tail -1)
    [ "$last" = "100%" ] || { echo "$flags ended at $last"; return 1; }
  done
}

@test "--cleanup --dry-run runs every step and touches nothing" {
  run bash "$SCRIPT" --cleanup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting full cleanup"* ]]
  [[ "$output" == *"Full cleanup completed"* ]]
}

@test "dry-run never deletes the Steam compat data" {
  mkdir -p "$HOME/.steam/steam/steamapps/compatdata/440"
  mkdir -p "$HOME/.steam/steam/steamapps/shadercache/440"
  touch "$HOME/.steam/steam/steamapps/compatdata/440/save.dat"
  run bash "$SCRIPT" --cleanup --dry-run
  [ "$status" -eq 0 ]
  [ -f "$HOME/.steam/steam/steamapps/compatdata/440/save.dat" ]
}

@test "the script never removes compatdata, in any mode" {
  # Releases up to 2.0.0 wiped it as "compat cache"; Proton keeps game
  # saves there. Guard the string, not just the dry-run path.
  run grep -n "compatdata" "$SCRIPT"
  [ "$status" -eq 0 ]
  run grep -E "rm -rf.*compatdata" "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the safe step list matches what full_cleanup counts" {
  # A step present in _SAFE_STEPS but missing from the "safe" steps array
  # would make the progress bar overshoot 100%.
  run bash -c 'source "$SCRIPT" >/dev/null
    declared=$(echo $_SAFE_STEPS)
    counted=$(sed -n "s/^        steps=(\(.*\))$/\1/p" "$SCRIPT" | head -1 | tr -d \" )
    [ "$declared" = "$counted" ] || { echo "declared=[$declared] counted=[$counted]"; exit 1; }'
  [ "$status" -eq 0 ]
}
