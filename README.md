# Minecraft modpack server images

One Dockerfile that builds a server image for **any** modpack on the
[modpacks.ch](https://modpacks.ch) index — both CurseForge packs (All the Mods,
Better MC, Prominence…) and FTB's own.

Some of the modpacks I play myself are on
[Docker Hub](https://hub.docker.com/repositories/dirnei).

## Quick start

```powershell
# Build All the Mods 10
.\src\build.ps1 -Pack atm10

# Run it
Copy-Item .env.example .env    # then set RCON_PASSWORD
docker compose up -d
docker compose logs -f
```

Updating to a newer pack version later:

```powershell
.\src\find-pack.ps1 atm10           # list versions, marking the one you have
.\src\build.ps1 -Pack atm10 -Latest # build the newest, update the pack file
docker compose up -d                # world survives the image swap
```

## Adding a pack

Add one file to `packs/`. Nothing else changes.

```ini
# packs/atm10.env
PACK_PROVIDER=curseforge     # curseforge | modpack
PACK_ID=925200               # CurseForge project id
PACK_VERSION=8558519         # CurseForge file id
IMAGE=dirnei/minecraft_atm_10
TAG=7.3
MEMORY=10G
EXCLUDE_MODS=colorwheel*     # optional: glob patterns of mods to drop
JAVA_VERSION=21              # optional: derived from the pack otherwise
```

Then `.\src\build.ps1 -Pack atm10`.

`EXCLUDE_MODS` takes space-separated globs, applied to `mods/` after install,
for mods the manifest wrongly marks as server-side. A pattern matching nothing
logs a warning rather than failing the build.

### Finding the ids

**`PACK_ID`** is on the pack's own page:

| Provider | Where |
| --- | --- |
| CurseForge | **Project ID** in the right-hand sidebar |
| FTB | the number in the pack URL — `/modpacks/103-ftb-skies` → `103` |

**`PACK_VERSION`** is a *file id*, not a version string. List them with:

```powershell
.\src\find-pack.ps1 atm10
```

```
All the Mods 10 - ATM10   [curseforge/925200]
newest targets Minecraft 1.21.1  neoforge 21.1.247

   PACK_VERSION version               type    released
-- ------------ -------               ----    --------
 *      8558519 All the Mods 10-7.3   release 2026-08-02
        8469481 All the Mods 10-7.2   release 2026-07-20
        8323938 All the Mods 10-7.1   release 2026-06-26

 * currently pinned in the pack file
```

For a pack with no pack file yet, pass the id directly. `-All` includes
alpha/beta, `-Count N` shows more:

```powershell
.\src\find-pack.ps1 -Provider curseforge -Id 925200
.\src\find-pack.ps1 -Provider modpack -Id 103 -All -Count 20
```

Or skip the lookup — `-Latest` resolves the newest release, builds it, and
writes `PACK_VERSION` and `TAG` back into the pack file.

There is no search-by-name; read the id off the page.

### build.ps1 options

| Flag | Effect |
| --- | --- |
| `-Pack <name>` | Which `packs/<name>.env` to build (required) |
| `-Latest` | Resolve the newest release from the API first; also tags `:latest` |
| `-TagLatest` | Force the `:latest` tag on a pinned build |
| `-PackVersion <id>` | One-off version override |
| `-JavaVersion <n>` | Override the derived JDK |
| `-Image` / `-Tag` | Override the image name from the pack file |
| `-Push` | Push after a successful build |
| `-NoCache` | Force a full rebuild |

## Runtime configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `EULA` | *(unset)* | Must be `true`. The server refuses to start otherwise. |
| `MEMORY` | *(pack default)* | Heap size; rewrites `user_jvm_args.txt` at startup. |
| `EXTRA_JVM_ARGS` | — | Space-separated extra JVM flags. |
| `MOTD` | — | Server list message. |
| `DIFFICULTY` | — | `peaceful` / `easy` / `normal` / `hard`. |
| `MAX_PLAYERS` | — | Player cap. |
| `LEVEL_SEED` | — | World seed (first run only). |
| `ENABLE_RCON` | `false` | Enables RCON; requires `RCON_PASSWORD`. |
| `RCON_PASSWORD` | — | Required when RCON is on. |
| `SERVER_PORT` | `25565` | Listen port. |
| `RCON_PORT` | `25575` | RCON port. |
| `PUID` / `PGID` | `1000` | Owner of `/data`; match your bind mount. |

Memory is a runtime setting — retune the heap without rebuilding.

## Persistence

Everything mutable lives in one volume at `/data`, symlinked into `/minecraft`:

```
/minecraft/world             -> /data/world
/minecraft/logs              -> /data/logs
/minecraft/backups           -> /data/backups
/minecraft/crash-reports     -> /data/crash-reports
/minecraft/server.properties -> /data/server.properties
/minecraft/ops.json          -> /data/ops.json
/minecraft/whitelist.json    -> /data/whitelist.json
/minecraft/banned-players.json, banned-ips.json, usercache.json
```

On first run each path is seeded from the image (or a sane default); afterwards
the volume wins. Updating the pack is a rebuild, and the world survives it.

## Notes and limits

- **Built and tested on linux/amd64.** `build.ps1` pins `--platform linux/amd64`.
  Nothing in the install is architecture-specific, so arm64 should work by
  changing that pin, but it is untested.
- **Images are large** — about 4 GB for ATM10, since the whole pack is baked in.
- `config/`, `kubejs/` and `defaultconfigs/` live in the image, not the volume,
  so a pack update applies. Hand edits to them are lost on rebuild.
- Base image is `eclipse-temurin:<JAVA_VERSION>-jdk`.
- `stop_grace_period` is 120s in the compose file. Don't lower it — a modded
  server killed mid-chunk-write corrupts region files.

## Ready-to-use images

### All the Mods 10

![Docker Pulls](https://img.shields.io/docker/pulls/dirnei/minecraft_atm_10?style=flat-square&logo=docker)
![Docker Image Version](https://img.shields.io/docker/v/dirnei/minecraft_atm_10?sort=date&style=flat-square&labelColor=re)

- [Modpack](https://www.curseforge.com/minecraft/modpacks/all-the-mods-10)
- [Docker](https://hub.docker.com/repository/docker/dirnei/minecraft_atm_10/general)

```bash
docker pull dirnei/minecraft_atm_10:latest
```

### FTB Skies

![Docker Pulls](https://img.shields.io/docker/pulls/dirnei/ftb-skies?style=flat-square&logo=docker)
![Docker Image Version](https://img.shields.io/docker/v/dirnei/ftb-skies?sort=date&style=flat-square&labelColor=re)

- [Modpack](https://feed-the-beast.com/modpacks/103-ftb-skies)
- [Docker](https://hub.docker.com/repository/docker/dirnei/ftb-skies/general)
