#!/usr/bin/env bats

setup() {
  TMPDIR_BCK=$(mktemp -d)
  export HOME="$TMPDIR_BCK"
  PATH_SAVE="$PATH"
  STUBS="$TMPDIR_BCK/stubs"
  mkdir "$STUBS"

  cat <<'EOS' > "$STUBS/locate"
#!/bin/bash
shift
# Output dummy paths; actual files are irrelevant
printf '/etc/dummy.conf\n'
EOS
  chmod +x "$STUBS/locate"

  cat <<'EOS' > "$STUBS/zip"
#!/bin/bash
archive="$1"
shift
# create archive file regardless of input
: > "$archive"
cat >/dev/null
EOS
  chmod +x "$STUBS/zip"

  export PATH="$STUBS:$PATH"
  cd "$TMPDIR_BCK"
}

teardown() {
  cd /
  export PATH="$PATH_SAVE"
  rm -rf "$TMPDIR_BCK"
}

@test "backup_configs creates a zip archive" {
  script="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT="$script"
  run bash -c 'source "$SCRIPT" >/dev/null; expected="$arq"; backup_configs >/dev/null; test -f "$expected"'
  [ "$status" -eq 0 ]
}
