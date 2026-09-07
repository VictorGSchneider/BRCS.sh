#!/usr/bin/env bats
#
# Whole caches belonging to programs you stopped using. This step removes
# directories outright, so the "must not" half matters more than the
# "must": age is the only signal, and it has to be read correctly.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../BRCS.sh"
  export SCRIPT
  TMP=$(mktemp -d)
  export TMP HOME="$TMP"
  export BRCS_TMP_DIRS="$TMP/scratch"
  mkdir -p "$TMP/scratch" "$HOME/.cache"
}

teardown() { rm -rf "$TMP"; }

# A cache directory whose newest content is $1 days old.
aged_cache() {
  local days="$1" name="$2" deep="${3:-}"
  local d="$HOME/.cache/$name"
  mkdir -p "$d${deep:+/$deep}"
  touch "$d${deep:+/$deep}/data.bin"
  # Set the leaf first, then the directories, deepest last.
  find "$d" -depth -exec touch -d "$days days ago" {} +
}

sweep() { bash "$SCRIPT" --cleanup --user </dev/null 2>&1; }

@test "removes a cache nothing has touched in over 90 days" {
  aged_cache 200 oldtool
  sweep >/dev/null
  [ ! -d "$HOME/.cache/oldtool" ]
}

@test "keeps a cache that is still in use" {
  aged_cache 5 activetool
  sweep >/dev/null
  [ -d "$HOME/.cache/activetool" ]
}

@test "reads age from the newest file anywhere inside, not the directory's own mtime" {
  # The regression this guards: a directory's mtime only moves when
  # entries are added or removed at its top level. A cache written deep
  # inside looks untouched for years, and an mtime-only check deletes a
  # cache that is in active use.
  aged_cache 200 deeptool "a/b/c"
  touch "$HOME/.cache/deeptool/a/b/c/data.bin"   # fresh, buried four levels down
  touch -d "200 days ago" "$HOME/.cache/deeptool"
  sweep >/dev/null
  [ -d "$HOME/.cache/deeptool" ]
}

@test "keeps expensive caches however old they are" {
  # Regenerable, but as gigabytes of re-download rather than seconds of
  # rebuild -- the same reasoning that keeps the Go module cache out.
  for name in huggingface torch ms-playwright pre-commit go-build bazel ccache; do
    aged_cache 400 "$name"
  done
  sweep >/dev/null
  for name in huggingface torch ms-playwright pre-commit go-build bazel ccache; do
    [ -d "$HOME/.cache/$name" ] || { echo "deleted an expensive cache: $name"; return 1; }
  done
}

@test "never touches loose files at the top of ~/.cache" {
  # Only whole directories are candidates; a stray file is not a cache.
  touch "$HOME/.cache/stray.conf"
  touch -d "400 days ago" "$HOME/.cache/stray.conf"
  sweep >/dev/null
  [ -f "$HOME/.cache/stray.conf" ]
}

@test "the age threshold is configurable" {
  aged_cache 40 midtool
  BRCS_STALE_CACHE_DAYS=30 sweep >/dev/null
  [ ! -d "$HOME/.cache/midtool" ]
}

@test "a longer threshold spares what a shorter one would take" {
  aged_cache 40 midtool
  BRCS_STALE_CACHE_DAYS=365 sweep >/dev/null
  [ -d "$HOME/.cache/midtool" ]
}

@test "dry-run names each cache and its size, and removes nothing" {
  aged_cache 200 oldtool
  run bash -c 'DRY=1; bash "$SCRIPT" --cleanup --user --dry-run </dev/null'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would remove stale cache: ~/.cache/oldtool"* ]]
  [ -d "$HOME/.cache/oldtool" ]
}

@test "says so plainly when there is nothing idle" {
  aged_cache 5 activetool
  run sweep
  [[ "$output" == *"No caches idle for 90+ days"* ]]
}
