# Shared helpers for the build scripts. Source, don't run.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$REPO/build"
DOWNLOADS="$BUILD/downloads"
SRC="$BUILD/src"
# shellcheck source=runtime-pins.env
source "$REPO/scripts/runtime-pins.env"

log() { printf '\n==> %s\n' "$*"; }

# fetch URL SHA256: download into $DOWNLOADS and verify the hash. The download goes to <file>.part,
# which an interrupted run resumes, and only becomes <file> once it matches; a mismatch deletes it,
# so the next run starts over instead of resuming onto bad bytes.
fetch() {
  local url=$1 sha=$2 file="$DOWNLOADS/$(basename "$1")"
  mkdir -p "$DOWNLOADS"
  if [[ -f $file ]] && echo "$sha  $file" | shasum -a 256 -c --status; then echo "$file"; return; fi
  rm -f "$file"
  for _ in 1 2 3 4 5; do
    curl -sS -fL -C - --speed-limit 20000 --speed-time 30 --retry 3 -o "$file.part" "$url" && break
  done
  if ! echo "$sha  $file.part" | shasum -a 256 -c --status; then
    rm -f "$file.part"
    echo "checksum mismatch for $url (the download was deleted; run again to retry)" >&2
    exit 1
  fi
  mv "$file.part" "$file"
  echo "$file"
}

# The CrossOver source tree (extracted once).
crossover_sources() {
  local dir="$SRC/crossover-$CROSSOVER_VERSION"
  if [[ ! -f $dir/.extracted ]]; then
    local tarball; tarball=$(fetch "$CROSSOVER_URL" "$CROSSOVER_SHA256")
    rm -rf "$dir" && mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir" sources/wine sources/gnutls
    touch "$dir/.extracted"
  fi
  echo "$dir/sources"
}

JOBS=$(( $(sysctl -n hw.logicalcpu) + $(sysctl -n hw.logicalcpu) / 2 ))
export MACOSX_DEPLOYMENT_TARGET=15.0
