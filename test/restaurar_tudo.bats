#!/usr/bin/env bats

setup() {
  TMPDIR_RES=$(mktemp -d)
  export DESTDIR="$TMPDIR_RES/restore"
  mkdir -p "$DESTDIR"

  PATH_SAVE="$PATH"
  STUBS="$TMPDIR_RES/stubs"
  mkdir "$STUBS"

  cat <<'EOS' > "$STUBS/sudo"
#!/bin/bash
cmd="$1"; shift
if [ "$cmd" = "mkdir" ]; then
  if [ "$1" = "-p" ]; then
    shift
    mkdir -p "$DESTDIR$1"
  else
    mkdir "$DESTDIR$1"
  fi
elif [ "$cmd" = "cp" ]; then
  src="$1"; dest="$2"
  cp "$src" "$DESTDIR$dest"
else
  "$cmd" "$@"
fi
EOS
  chmod +x "$STUBS/sudo"

  export PATH="$STUBS:$PATH"
}

teardown() {
  export PATH="$PATH_SAVE"
  rm -rf "$TMPDIR_RES"
}

@test "restaurar_tudo extracts all files" {
  archive="$TMPDIR_RES/test.zip"
  mkdir -p "$TMPDIR_RES/data/etc"
  echo "demo" > "$TMPDIR_RES/data/etc/test.conf"
  (cd "$TMPDIR_RES/data" && zip -r "$archive" etc >/dev/null)
  export ARCHIVE="$archive"

  script="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT="$script"
  run bash -c 'source "$SCRIPT" >/dev/null; echo "$ARCHIVE" | restaurar_tudo >/dev/null; test -f "$DESTDIR/etc/test.conf"'
  [ "$status" -eq 0 ]
}
