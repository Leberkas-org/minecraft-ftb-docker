#!/usr/bin/env bash
#
# Build-time modpack installer.
#
# Installs a pack straight from its modpacks.ch manifest rather than using FTB's
# server-installer binary, because neither build of that binary can install a
# CurseForge pack any more:
#
#   * the build the API serves (24.622.1046) dies with
#     "cannot unmarshal string into Go struct field VersionInfo.specs" - the
#     CurseForge namespace now returns "specs": "" where it expects an object
#   * the current release (v1.0.49) dropped the provider entirely
#     ("Valid providers are 'ftb'")
#
# The manifest is public and complete, so we read it ourselves. That also gives
# one code path for both providers and no dependency on a prebuilt x86-64 binary.
#
# Usage: install-pack.sh <provider> <pack-id> <version-id> [dest]
#
set -euo pipefail

PROVIDER="${1:?provider (curseforge|modpack)}"
PACK_ID="${2:?pack id}"
PACK_VERSION="${3:?version id}"
DEST="${4:-/minecraft}"

MANIFEST=/tmp/manifest.json
FILELIST=/tmp/files.txt

log() { printf '[install-pack] %s\n' "$*"; }
die() { printf '[install-pack] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
log "fetching manifest for ${PROVIDER}/${PACK_ID}/${PACK_VERSION}"
curl -fsSL --retry 5 --retry-delay 5 -o "${MANIFEST}" \
  "https://api.modpacks.ch/public/${PROVIDER}/${PACK_ID}/${PACK_VERSION}"

# modpacks.ch answers 200 with a status:error body for ids it does not know.
if [ "$(jq -r '.status // ""' "${MANIFEST}")" = "error" ]; then
  die "$(jq -r '.message // "unknown error"' "${MANIFEST}")"
fi

PACK_NAME="$(jq -r '.name // "unknown"' "${MANIFEST}")"
MC_VERSION="$(jq -r 'first(.targets[]? | select(.type=="game") | .version) // ""' "${MANIFEST}")"
LOADER="$(jq -r 'first(.targets[]? | select(.type=="modloader") | .name) // ""' "${MANIFEST}")"
LOADER_VERSION="$(jq -r 'first(.targets[]? | select(.type=="modloader") | .version) // ""' "${MANIFEST}")"

log "pack       : ${PACK_NAME}"
log "minecraft  : ${MC_VERSION:-unknown}"
log "modloader  : ${LOADER:-none} ${LOADER_VERSION:-}"

# ---------------------------------------------------------------------------
# Java sanity check
#
# The manifest's java target is not trustworthy - ATM10, a Minecraft 1.21.1
# pack, advertises "8.0.312+7" - so the requirement is derived from the
# Minecraft version and used only to verify the JDK baked into this image.
# ---------------------------------------------------------------------------
# Unrecognised versions fall through to the newest JDK rather than the oldest:
# an unknown version is far likelier to be newer than 1.21 than older than 1.7.
required_java_for() {
  case "$1" in
    "")                            echo 0  ;;   # unknown - skip the check
    1.7*|1.8*|1.9*)                echo 8  ;;
    1.1[0-6]*)                     echo 8  ;;
    1.1[789]*)                     echo 17 ;;
    1.20.5*|1.20.6*)               echo 21 ;;
    1.20*)                         echo 17 ;;
    *)                             echo 21 ;;
  esac
}

REQUIRED_JAVA="$(required_java_for "${MC_VERSION}")"
JAVA_MAJOR="$(java -version 2>&1 | awk -F'"' '/version/ {print $2}' | cut -d. -f1)"
[ "${JAVA_MAJOR}" = "1" ] && JAVA_MAJOR=8   # 1.8.0_x style version strings

if [ "${REQUIRED_JAVA}" != "0" ] && [ "${JAVA_MAJOR:-0}" -lt "${REQUIRED_JAVA}" ]; then
  die "Minecraft ${MC_VERSION} needs Java ${REQUIRED_JAVA} but this image has Java ${JAVA_MAJOR}. Rebuild with --build-arg JAVA_VERSION=${REQUIRED_JAVA}."
fi
log "java       : ${JAVA_MAJOR} (pack needs >= ${REQUIRED_JAVA})"

# ---------------------------------------------------------------------------
# Files
#
# clientonly entries are skipped - putting those on a server is one of the
# things that made the old "unzip the CurseForge server pack" approach flaky.
#
# The work list is one field per line and consumed with `xargs -d '\n'`, not
# plain whitespace splitting: mod filenames do contain spaces (4 of ATM10's do).
# NUL delimiting would be the usual answer but jq cannot emit a NUL byte - it
# silently drops it - so newlines it is, which is safe because filenames cannot
# contain one.
# ---------------------------------------------------------------------------
TOTAL="$(jq '.files | length' "${MANIFEST}")"
jq -r '
  .files[]
  | select((.clientonly // false) | not)
  | .url,
    (((.path // "./") + "/" + .name) | gsub("/+"; "/")),
    (.sha1 // "")
' "${MANIFEST}" > "${FILELIST}"

WANTED="$(jq '[.files[] | select((.clientonly // false) | not)] | length' "${MANIFEST}")"
log "files      : ${WANTED} to download (${TOTAL} in pack, $((TOTAL - WANTED)) client-only skipped)"

download_one() {
  local url="$1" rel="$2" sha="$3"
  local out="${DEST}/${rel#./}"

  # A few FTB manifest URLs carry unencoded spaces (e.g. ".../FTB Omnia-1.0.0/")
  # which curl rejects outright with "URL using bad/illegal format". Everything
  # else in these URLs is already percent-encoded, so encoding the space is the
  # whole fix - do not touch % itself or the encoding would be doubled.
  url="${url// /%20}"

  mkdir -p "$(dirname "${out}")"
  if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --retry-connrefused \
       --max-time 900 -o "${out}" "${url}"; then
    rm -f "${out}"
    return 1
  fi

  if [ -n "${sha}" ]; then
    local actual
    actual="$(sha1sum "${out}" | cut -d' ' -f1)"
    if [ "${actual}" != "${sha}" ]; then
      echo "[install-pack] sha1 mismatch for ${rel}: got ${actual}, want ${sha}" >&2
      rm -f "${out}"
      return 1
    fi
  fi
}
export -f download_one
export DEST

# Rebuild the work list from what is actually missing or corrupt on disk.
remaining_list() {
  local src="$1" dst="$2" url rel sha out actual need
  : > "${dst}"
  while IFS= read -r url && IFS= read -r rel && IFS= read -r sha; do
    out="${DEST}/${rel#./}"
    need=0
    if [ ! -s "${out}" ]; then
      need=1
    elif [ -n "${sha}" ]; then
      actual="$(sha1sum "${out}" | cut -d' ' -f1)"
      if [ "${actual}" != "${sha}" ]; then rm -f "${out}"; need=1; fi
    fi
    if [ "${need}" = "1" ]; then
      printf '%s\n%s\n%s\n' "${url}" "${rel}" "${sha}" >> "${dst}"
    fi
  done < "${src}"
}

THREADS="${THREADS:-$(( $(nproc) * 2 ))}"
[ "${THREADS}" -gt 8 ] && THREADS=8

# Large packs (FTB Skies is 1858 files) get throttled by the CDN when hit hard,
# and those failures are not sticky - a calmer retry pass picks them up. Fail
# only if a file is still missing after backing off to a single connection.
TODO=/tmp/todo.txt
cp "${FILELIST}" "${TODO}"

for attempt in 1 2 3; do
  count=$(( $(wc -l < "${TODO}") / 3 ))
  if [ "${count}" -eq 0 ]; then break; fi

  parallel="${THREADS}"
  if [ "${attempt}" -eq 2 ]; then parallel=2; fi
  if [ "${attempt}" -ge 3 ]; then parallel=1; fi

  log "download pass ${attempt}: ${count} file(s), ${parallel} parallel"
  xargs -d '\n' -n 3 -P "${parallel}" bash -c 'download_one "$1" "$2" "$3"' _ < "${TODO}" || true

  remaining_list "${TODO}" "${TODO}.next"
  mv "${TODO}.next" "${TODO}"
done

STILL_MISSING=$(( $(wc -l < "${TODO}") / 3 ))
if [ "${STILL_MISSING}" -ne 0 ]; then
  echo "[install-pack] still missing after 3 passes:" >&2
  while IFS= read -r u && IFS= read -r r && IFS= read -r s; do
    echo "  ${r} <- ${u}" >&2
  done < "${TODO}"
  die "${STILL_MISSING} file(s) could not be downloaded"
fi
rm -f "${TODO}"
log "downloaded ${WANTED} files"

# ---------------------------------------------------------------------------
# CurseForge overrides
#
# A CurseForge pack ships its configs, scripts and defaultconfigs inside the
# client zip rather than as individual manifest entries. The manifest flags that
# archive with type "cf-extract"; its overrides/ directory has to be merged over
# the install. Skip this and the server boots with none of the pack's
# configuration - no config/, no kubejs/, no defaultconfigs/.
# ---------------------------------------------------------------------------
while IFS= read -r rel; do
  [ -n "${rel}" ] || continue
  archive="${DEST}/${rel#./}"
  [ -f "${archive}" ] || continue

  log "extracting $(basename "${archive}")"
  tmp="$(mktemp -d)"
  unzip -q "${archive}" -d "${tmp}"

  if [ -d "${tmp}/overrides" ]; then
    cp -a "${tmp}/overrides/." "${DEST}/"
  else
    # Some packs zip the override contents at the archive root instead.
    rm -f "${tmp}/manifest.json" "${tmp}/modlist.html"
    cp -a "${tmp}/." "${DEST}/"
  fi

  rm -rf "${tmp}" "${archive}"
done < <(jq -r '.files[] | select(.type=="cf-extract") | (((.path // "./") + "/" + .name) | gsub("/+"; "/"))' "${MANIFEST}")

# ---------------------------------------------------------------------------
# Per-pack mod exclusions
#
# The manifest's clientonly flags are curated by hand and are sometimes wrong.
# ATM10 7.3 ships colorwheel unflagged even though it hard-requires iris, which
# IS flagged clientonly - so a server install gets colorwheel without its
# dependency and NeoForge refuses to start. EXCLUDE_MODS is the escape hatch:
# space-separated glob patterns, set per pack in packs/<name>.env.
# ---------------------------------------------------------------------------
if [ -n "${EXCLUDE_MODS:-}" ]; then
  set -f   # split EXCLUDE_MODS on whitespace without the shell expanding the globs
  for pattern in ${EXCLUDE_MODS}; do
    set +f
    matched=0
    while IFS= read -r victim; do
      [ -n "${victim}" ] || continue
      log "excluding $(basename "${victim}")"
      rm -f "${victim}"
      matched=$((matched + 1))
    done < <(find "${DEST}/mods" -maxdepth 1 -type f -name "${pattern}" 2>/dev/null)
    if [ "${matched}" -eq 0 ]; then
      log "warning: EXCLUDE_MODS pattern '${pattern}' matched nothing"
    fi
    set -f
  done
  set +f
fi

# ---------------------------------------------------------------------------
# Modloader
# ---------------------------------------------------------------------------
case "${LOADER}" in
  neoforge)
    LOADER_URL="https://maven.neoforged.net/releases/net/neoforged/neoforge/${LOADER_VERSION}/neoforge-${LOADER_VERSION}-installer.jar"
    ;;
  forge)
    LOADER_URL="https://maven.minecraftforge.net/net/minecraftforge/forge/${MC_VERSION}-${LOADER_VERSION}/forge-${MC_VERSION}-${LOADER_VERSION}-installer.jar"
    ;;
  fabric|"")
    LOADER_URL=""   # fabric packs ship their own launch jar among the files
    ;;
  *)
    die "unsupported modloader '${LOADER}'"
    ;;
esac

if [ -n "${LOADER_URL}" ]; then
  log "installing ${LOADER} ${LOADER_VERSION}"
  curl -fsSL --retry 5 --retry-delay 5 -o /tmp/loader-installer.jar "${LOADER_URL}"
  ( cd "${DEST}" && java -jar /tmp/loader-installer.jar --installServer )
  rm -f /tmp/loader-installer.jar "${DEST}/loader-installer.jar.log"
fi

# The modloader installer emits user_jvm_args.txt; guarantee one exists either
# way so the entrypoint can always pass @user_jvm_args.txt.
if [ ! -f "${DEST}/user_jvm_args.txt" ]; then
  printf -- '-Xms4G\n-Xmx4G\n' > "${DEST}/user_jvm_args.txt"
fi

rm -f "${MANIFEST}" "${FILELIST}"
log "done: ${PACK_NAME} installed into ${DEST}"
