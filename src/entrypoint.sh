#!/usr/bin/env bash
#
# Container entrypoint for modpack servers installed by the modpacks.ch
# installer.
#
# It deliberately does NOT use the launcher script the pack ships. Those
# scripts prompt interactively for the EULA (which hangs forever with no TTY)
# and wrap the server in a restart loop (which fights Docker's restart policy
# and turns `docker stop` into a hard kill). Instead this script accepts the
# EULA from an env var and exec's java directly, so the JVM is PID 1 and gets
# SIGTERM for a clean world save.
#
set -euo pipefail

MC_DIR="${MC_DIR:-/minecraft}"
DATA_DIR="${DATA_DIR:-/data}"
# SERVER_PORT and RCON_PORT are intentionally left unset when not supplied.
# Defaulting them here would make "was it supplied?" unanswerable further down,
# and server.properties keys are only written when explicitly asked for. Use
# ${SERVER_PORT:-25565} at the point of use instead.
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

PROPS="${DATA_DIR}/server.properties"
JVM_ARGS_FILE="${MC_DIR}/user_jvm_args.txt"

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# EULA
# ---------------------------------------------------------------------------
case "${EULA:-}" in
  true|TRUE|True) ;;
  *) die "You must accept the Minecraft EULA (https://aka.ms/MinecraftEULA) by setting EULA=true." ;;
esac

# Written fresh on every start. Also short-circuits the interactive prompt in
# any pack launcher we might have to fall back to, since those all test for
# eula=true before asking.
printf '# accepted via the EULA environment variable on %s\neula=true\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${MC_DIR}/eula.txt"

# ---------------------------------------------------------------------------
# Persistent state
#
# Everything that survives a pack update lives in ${DATA_DIR} and is symlinked
# back into ${MC_DIR}. On first run each path is seeded from the image (or from
# a sane default); afterwards the image copy is discarded in favour of the
# volume. This is what lets you rebuild the image for a newer pack version
# without losing the world, ops or whitelist.
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}"

# Anything this script creates is created by root, so hand it to the server
# user explicitly. Relying on a single check of ${DATA_DIR}'s own ownership is
# not enough: a named volume inherits uid 1000 from the image, the check passes,
# and freshly created logs/ and ops.json would silently stay root-owned and
# unwritable by the server.
own() {
  [ "$(id -u)" = "0" ] || return 0
  chown "${PUID}:${PGID}" "$@" 2>/dev/null || true
}

# One deep pass up front, only when the tree is genuinely owned by someone else
# (typical for a bind mount created by another user). Done before seeding so the
# expensive recursion never has to repeat.
if [ "$(id -u)" = "0" ]; then
  if [ "$(stat -c %u "${DATA_DIR}")" != "${PUID}" ] || [ "$(stat -c %g "${DATA_DIR}")" != "${PGID}" ]; then
    log "fixing ownership of ${DATA_DIR} to ${PUID}:${PGID} (may take a moment on a large world)"
    chown -R "${PUID}:${PGID}" "${DATA_DIR}"
  fi

  # Individually mounted directories are separate filesystems, so the check
  # above says nothing about them - a world bind-mounted from a root-owned host
  # directory would leave the server unable to save. Read-only mounts are left
  # alone; chown would fail on them and they are not written anyway.
  for d in world logs backups crash-reports; do
    p="${DATA_DIR}/${d}"
    [ -d "${p}" ] || continue
    [ "$(stat -c %u "${p}")" = "${PUID}" ] && continue
    if chown "${PUID}:${PGID}" "${p}" 2>/dev/null; then
      log "fixing ownership of ${p}"
      chown -R "${PUID}:${PGID}" "${p}" 2>/dev/null || true
    else
      log "warning: ${p} is not owned by ${PUID} and cannot be changed (read-only mount?)"
    fi
  done
fi

# If the operator mounted something at this path themselves, it is theirs: use it
# where it is and do not manage it. Anything else is destructive - `mv` across
# filesystems copies then unlinks, so it empties a mounted directory before
# failing to remove it, and a later `rm -rf` would delete the contents outright.
#
# This also means both layouts work: mount ${DATA_DIR} as a whole, mount
# individual paths under ${DATA_DIR}, or mount them directly at ${MC_DIR} the way
# older versions of this image did.
is_self_mounted() {
  local path="$1" name="$2"
  mountpoint -q "${path}" 2>/dev/null || return 1
  log "${name} is mounted directly - using it as-is, not linked into ${DATA_DIR}"
  return 0
}

link_dir() {
  local name="$1"
  local src="${MC_DIR}/${name}" dst="${DATA_DIR}/${name}"

  if is_self_mounted "${src}" "${name}"; then return 0; fi

  if [ ! -e "${dst}" ]; then
    if [ -d "${src}" ] && [ ! -L "${src}" ]; then
      log "seeding ${name}/ into ${DATA_DIR} from the image"
      mv "${src}" "${dst}"
    else
      mkdir -p "${dst}"
    fi
    own "${dst}"
  fi

  rm -rf "${src}"
  ln -s "${dst}" "${src}"
}

link_file() {
  local name="$1" default="${2-}"
  local src="${MC_DIR}/${name}" dst="${DATA_DIR}/${name}"

  if is_self_mounted "${src}" "${name}"; then return 0; fi

  if [ ! -e "${dst}" ]; then
    if [ -f "${src}" ] && [ ! -L "${src}" ]; then
      log "seeding ${name} into ${DATA_DIR} from the image"
      mv "${src}" "${dst}"
    else
      printf '%s' "${default}" > "${dst}"
    fi
    own "${dst}"
  fi

  rm -f "${src}"
  ln -s "${dst}" "${src}"
}

# crash-reports is persisted deliberately: a crash kills the container, and
# without this the report explaining why dies with it.
for d in world logs backups crash-reports; do
  link_dir "${d}"
done

link_file server.properties ''
# All of these are JSON arrays; an empty file makes the server complain on load.
for f in ops.json whitelist.json banned-players.json banned-ips.json usercache.json; do
  link_file "${f}" '[]'
done

# ---------------------------------------------------------------------------
# Overlay
#
# Any other file placed under ${DATA_DIR} is linked into ${MC_DIR} at the same
# relative path, so single files can be overridden - server-icon.png, one config
# out of the pack's hundred - without mounting all of ${MC_DIR} or knowing which
# directory the server reads them from. The big state directories are pruned so
# this never walks a multi-GB world.
# ---------------------------------------------------------------------------
overlay_extras() {
  local f rel link
  while IFS= read -r -d '' f; do
    rel="${f#"${DATA_DIR}/"}"

    # Managed above; linked the other way round.
    case "${rel}" in
      server.properties|ops.json|whitelist.json|banned-players.json|banned-ips.json|usercache.json)
        continue ;;
    esac

    link="${MC_DIR}/${rel}"
    [ -L "${link}" ] && [ "$(readlink "${link}")" = "${f}" ] && continue

    mkdir -p "$(dirname "${link}")"
    rm -rf "${link}"
    ln -s "${f}" "${link}"
    log "overlay ${rel}"
  done < <(
    find "${DATA_DIR}" \
      -path "${DATA_DIR}/world" -prune -o \
      -path "${DATA_DIR}/logs" -prune -o \
      -path "${DATA_DIR}/backups" -prune -o \
      -path "${DATA_DIR}/crash-reports" -prune -o \
      -type f -print0 2>/dev/null
  )
}
overlay_extras

# ---------------------------------------------------------------------------
# server.properties
# ---------------------------------------------------------------------------
props_set() {
  local key="$1" val="$2" esc
  # Escape the characters sed would otherwise interpret in the replacement.
  esc="$(printf '%s' "${val}" | sed -e 's/[\\&|]/\\&/g')"

  if grep -qE "^[#[:space:]]*${key}=" "${PROPS}"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${esc}|" "${PROPS}"
  else
    printf '%s=%s\n' "${key}" "${val}" >> "${PROPS}"
  fi
}

if [ ! -s "${PROPS}" ]; then
  # FTB packs ship a default-server.properties with pack-tuned values; prefer it
  # over inventing our own.
  if [ -f "${MC_DIR}/default-server.properties" ]; then
    log "seeding server.properties from the pack's default-server.properties"
    cat "${MC_DIR}/default-server.properties" > "${PROPS}"
  else
    log "generating a default server.properties"
    printf 'motd=Minecraft modpack server\n' > "${PROPS}"
  fi

  # allow-flight and max-tick-time are the two settings almost every modded pack
  # needs - flight-granting items trip the anticheat, and worldgen or a heavy mod
  # tick routinely exceeds the 60s watchdog - but never override a pack that
  # already made its own choice.
  grep -qE '^[[:space:]]*allow-flight=' "${PROPS}"  || printf 'allow-flight=true\n'    >> "${PROPS}"
  grep -qE '^[[:space:]]*max-tick-time=' "${PROPS}" || printf 'max-tick-time=180000\n' >> "${PROPS}"
  grep -qE '^[[:space:]]*server-port=' "${PROPS}"   || printf 'server-port=%s\n' "${SERVER_PORT:-25565}" >> "${PROPS}"
fi

# Only keys whose environment variable was actually supplied are written. After
# the first run ${PROPS} belongs to the operator: hand edits survive restarts,
# and nothing is re-asserted behind their back. Re-asserting server-port and
# enable-rcon on every start used to silently revert exactly the two settings
# someone is most likely to change by hand.
[ -n "${SERVER_PORT:-}" ] && props_set server-port "${SERVER_PORT}"
[ -n "${MOTD:-}" ] && props_set motd "${MOTD}"
[ -n "${DIFFICULTY:-}" ] && props_set difficulty "${DIFFICULTY}"
[ -n "${MAX_PLAYERS:-}" ] && props_set max-players "${MAX_PLAYERS}"
[ -n "${LEVEL_SEED:-}" ] && props_set level-seed "${LEVEL_SEED}"

if [ -n "${ENABLE_RCON:-}" ]; then
  if [ "${ENABLE_RCON}" = "true" ]; then
    [ -n "${RCON_PASSWORD:-}" ] || die "ENABLE_RCON=true requires RCON_PASSWORD to be set."
    props_set enable-rcon true
    props_set rcon.port "${RCON_PORT:-25575}"
    props_set rcon.password "${RCON_PASSWORD}"
    log "RCON enabled on port ${RCON_PORT:-25575}"
  else
    props_set enable-rcon false
  fi
fi

# ---------------------------------------------------------------------------
# JVM arguments
#
# user_jvm_args.txt is what the modloader's generated arg file reads, so tune
# it rather than trying to pass -Xmx alongside it.
# ---------------------------------------------------------------------------
if [ -n "${MEMORY:-}" ] || [ -n "${EXTRA_JVM_ARGS:-}" ] || [ ! -f "${JVM_ARGS_FILE}" ]; then
  {
    echo "# Regenerated on every start. Set MEMORY / EXTRA_JVM_ARGS instead of editing this."
    printf -- '-Xms%s\n-Xmx%s\n' "${MEMORY:-4G}" "${MEMORY:-4G}"
    if [ -n "${EXTRA_JVM_ARGS:-}" ]; then
      # Intentionally unquoted: EXTRA_JVM_ARGS is a space-separated arg list.
      # shellcheck disable=SC2086
      for arg in ${EXTRA_JVM_ARGS}; do printf '%s\n' "${arg}"; done
    fi
  } > "${JVM_ARGS_FILE}"
  log "heap set to ${MEMORY:-4G}"
fi

# ---------------------------------------------------------------------------
# Ownership of what this script wrote into ${MC_DIR}
# (the ${DATA_DIR} tree was handled above, before seeding)
# ---------------------------------------------------------------------------
own "${MC_DIR}/eula.txt" "${JVM_ARGS_FILE}"
if [ "$(id -u)" = "0" ]; then
  chown -h "${PUID}:${PGID}" "${MC_DIR}" "${MC_DIR}"/* 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Launch
#
# Loader-agnostic detection, in order of preference. This is what replaces the
# per-Minecraft-version Dockerfiles: NeoForge, Forge, Fabric and plain vanilla
# packs all land in one of these three branches.
# ---------------------------------------------------------------------------
JAVA="$(cat "${MC_DIR}/.docker/java-path" 2>/dev/null || true)"
if [ -z "${JAVA}" ] || [ ! -x "${JAVA}" ]; then
  JAVA="$(command -v java || true)"
fi
[ -n "${JAVA}" ] || die "no java runtime found in the image."

cd "${MC_DIR}"

run_as() {
  if [ "$(id -u)" = "0" ]; then
    exec setpriv --reuid="${PUID}" --regid="${PGID}" --clear-groups "$@"
  fi
  exec "$@"
}

# 1. NeoForge / Forge: the modloader installer emits an args file listing the
#    module path and main class.
ARGS_FILE="$(find "${MC_DIR}/libraries" -type f -name unix_args.txt 2>/dev/null | sort | head -n1 || true)"
if [ -n "${ARGS_FILE}" ]; then
  log "launching via modloader args file ${ARGS_FILE#"${MC_DIR}"/}"
  run_as "${JAVA}" "@${JVM_ARGS_FILE}" "@${ARGS_FILE}" nogui
fi

# 2. Fabric / vanilla-style packs: a single launch jar.
for jar in fabric-server-launch.jar server.jar minecraft_server.jar forge-server.jar; do
  if [ -f "${MC_DIR}/${jar}" ]; then
    log "launching ${jar}"
    mapfile -t JVM_ARGS < <(grep -vE '^[[:space:]]*(#|$)' "${JVM_ARGS_FILE}")
    run_as "${JAVA}" "${JVM_ARGS[@]}" -jar "${MC_DIR}/${jar}" nogui
  fi
done

# 3. Last resort: the pack's own launcher. The EULA prompt is already
#    satisfied above; the restart loop is suppressed where the pack honours a
#    well-known env var.
export ATM10_RESTART=false ATM9_RESTART=false RESTART=false
for script in start.sh run.sh ServerStart.sh startserver.sh; do
  if [ -f "${MC_DIR}/${script}" ]; then
    log "no args file or launch jar found; falling back to the pack's ${script}"
    chmod +x "${MC_DIR}/${script}" 2>/dev/null || true
    run_as bash "${MC_DIR}/${script}"
  fi
done

printf '[entrypoint] contents of %s:\n' "${MC_DIR}" >&2
ls -la "${MC_DIR}" >&2
die "no launcher found in ${MC_DIR}."
