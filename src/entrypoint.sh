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
SERVER_PORT="${SERVER_PORT:-25565}"
RCON_PORT="${RCON_PORT:-25575}"
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
fi

link_dir() {
  local name="$1"
  local src="${MC_DIR}/${name}" dst="${DATA_DIR}/${name}"

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
fi

props_set server-port "${SERVER_PORT}"
[ -n "${MOTD:-}" ] && props_set motd "${MOTD}"
[ -n "${DIFFICULTY:-}" ] && props_set difficulty "${DIFFICULTY}"
[ -n "${MAX_PLAYERS:-}" ] && props_set max-players "${MAX_PLAYERS}"
[ -n "${LEVEL_SEED:-}" ] && props_set level-seed "${LEVEL_SEED}"

if [ "${ENABLE_RCON:-false}" = "true" ]; then
  [ -n "${RCON_PASSWORD:-}" ] || die "ENABLE_RCON=true requires RCON_PASSWORD to be set."
  props_set enable-rcon true
  props_set rcon.port "${RCON_PORT}"
  props_set rcon.password "${RCON_PASSWORD}"
  log "RCON enabled on port ${RCON_PORT}"
else
  props_set enable-rcon false
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
