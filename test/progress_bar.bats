#!/usr/bin/env bats

@test "progress_bar shows correct percentage" {
  run bash -c 'source ./BRCS.sh >/dev/null; progress_bar 10 5'
  [[ "$output" == *"50%"* ]]
}
