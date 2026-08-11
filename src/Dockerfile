# syntax=docker/dockerfile:1
#
# Modular Minecraft modpack server image.
#
# One Dockerfile for every pack on the modpacks.ch index, which covers both
# CurseForge packs and FTB's own. PACK_PROVIDER is the URL path segment that
# picks between them:
#
#   curseforge -> https://api.modpacks.ch/public/curseforge/<project-id>/<file-id>
#   modpack    -> https://api.modpacks.ch/public/modpack/<pack-id>/<version-id>
#
# install-pack.sh reads that manifest and installs the pack directly; see the
# comment at the top of it for why FTB's server-installer binary is not used.
#
# JAVA_VERSION must match the pack's Minecraft version. build.ps1 derives it
# from the manifest automatically; install-pack.sh fails the build with a clear
# message if it is wrong.
#
#   docker build --platform linux/amd64 \
#     --build-arg PACK_PROVIDER=curseforge \
#     --build-arg PACK_ID=925200 \
#     --build-arg PACK_VERSION=8558519 \
#     --build-arg JAVA_VERSION=21 \
#     -t dirnei/minecraft_atm_10:7.3 ./src

ARG JAVA_VERSION=21
FROM eclipse-temurin:${JAVA_VERSION}-jdk

ARG PACK_PROVIDER=curseforge
ARG PACK_ID=925200
ARG PACK_VERSION=8558519
# Space-separated glob patterns of mods to drop after install; see install-pack.sh.
ARG EXCLUDE_MODS=""

LABEL org.opencontainers.image.source="https://github.com/Leberkas-org/minecraft-ftb-docker" \
      net.modpacks.provider="${PACK_PROVIDER}" \
      net.modpacks.pack-id="${PACK_ID}" \
      net.modpacks.version-id="${PACK_VERSION}"

ENV MC_DIR=/minecraft \
    DATA_DIR=/data \
    SERVER_PORT=25565 \
    RCON_PORT=25575 \
    PUID=1000 \
    PGID=1000

# jq: reads the pack manifest. util-linux: setpriv, used to drop root at launch.
#
# The Ubuntu-based temurin images already ship a uid/gid 1000 ("ubuntu"), so
# creating the account is conditional. Ownership is applied numerically
# throughout - the entrypoint drops privileges with setpriv on numeric ids and
# never needs the account to be called "minecraft".
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq unzip procps util-linux passwd; \
    rm -rf /var/lib/apt/lists/*; \
    if ! getent group 1000 >/dev/null; then groupadd -g 1000 minecraft; fi; \
    if ! getent passwd 1000 >/dev/null; then \
      useradd -u 1000 -g 1000 -m -d /home/minecraft -s /usr/sbin/nologin minecraft; \
    fi; \
    mkdir -p "${MC_DIR}" "${DATA_DIR}"

WORKDIR ${MC_DIR}

COPY --chmod=0755 install-pack.sh /usr/local/bin/

# Downloads the whole pack (about 4 GB for ATM10) and runs the modloader
# installer. Ownership and the java-path marker are folded into this same layer:
# a separate `chown -R` step would duplicate every file into a second layer and
# roughly double the image size.
RUN set -eux; \
    EXCLUDE_MODS="${EXCLUDE_MODS}" \
      /usr/local/bin/install-pack.sh "${PACK_PROVIDER}" "${PACK_ID}" "${PACK_VERSION}" "${MC_DIR}"; \
    mkdir -p "${MC_DIR}/.docker"; \
    command -v java > "${MC_DIR}/.docker/java-path"; \
    java -version; \
    chown -R 1000:1000 "${MC_DIR}" "${DATA_DIR}"

# Deliberately copied *after* the install: these change often, and copying them
# earlier would invalidate the cache for the multi-GB download on every edit.
COPY --chmod=0755 entrypoint.sh healthcheck.sh /usr/local/bin/

EXPOSE 25565/tcp 25575/tcp

# A first boot of a large pack spends a long time generating spawn chunks, so
# the start period is generous - otherwise the container would report unhealthy
# before the server has ever opened its socket.
HEALTHCHECK --start-period=15m --interval=30s --timeout=5s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh

# No VOLUME instruction on purpose: all mutable state lives under /data, and an
# implicit VOLUME would silently accumulate anonymous volumes on every run.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
