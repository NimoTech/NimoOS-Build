# NimoOS-Build

Build and install scripts for NimoOS, plus the single version source
[`release/versions.conf`](./release/versions.conf).

> ### About
>
> NimoOS is a fork of [CasaOS](https://github.com/IceWhaleTech/CasaOS)
> (Apache-2.0), originally developed by IceWhale Technology Co., Ltd.
> Building on that foundation, NimoOS adds an AI agent, RAG-based retrieval,
> a knowledge layer, and a built-in web terminal.
>
> See [`NOTICE`](./NOTICE) for attribution details. CasaOS and IceWhale are
> trademarks of IceWhale Technology Co., Ltd.; NimoOS is an independent
> project and is not affiliated with IceWhale.
>
> This repository is NimoTech's own work and contains no CasaOS-derived code.

> ⚠️ Multi-user isolation is incomplete — Photos and Search are not yet
> per-user scoped. Read
> [SECURITY.md](https://github.com/NimoTech/NimoOS/blob/main/SECURITY.md#known-limitations)
> before deploying NimoOS for more than one person.

## Install

Supported today: **linux/amd64 only**. The installer refuses other
architectures rather than installing binaries that cannot run — arm64 and armv7
are not published yet.

```bash
curl -fsSL https://get.nimotech.ai/get/nimoos-install.sh | sudo bash
```

The AI and RAG stack (Qdrant, Parser, Ollama) is a separate step:

```bash
sudo bash scripts/nimoos-stack-install.sh
```

## What is in here

| Path | Purpose |
|---|---|
| `release/versions.conf` | **Single version source.** Change it here; the build injects it into every service via ldflags |
| `release/lib/` | Version injection and the component registry (`common.sh`, `version_inject.sh`) |
| `nimoos-install.sh` · `nimoos-update.sh` · `nimoos-uninstall.sh` | Install, update, uninstall |
| `scripts/install-*.sh` · `nimoos-stack-install.sh` | Per-component and AI/RAG stack installation |
| `scripts/deploy*.sh` | Development: build, replace the binary, restart the systemd unit |
| `scripts/fetch-ttyd.sh` | Fetches the ttyd dependency for the built-in terminal |
| `scripts/start-ai.sh` · `update-host-agent.sh` | AI service start/stop, in-place host agent update |
| `clone_all.sh` | Clones the service repositories |
| `DEV_DEPLOY.md` | systemd unit to source mapping, binary replacement procedure |

## Building from source

NimoOS is a multi-repository project. Every Go service uses a `replace`
directive pointing at the local `NimoOS-Common` checkout, so **a build needs the
full workspace**:

```bash
bash clone_all.sh          # clone the service repositories as siblings
```

Expected layout:

```
nimoos/
├── NimoOS-Build/          # this repository
├── NimoOS-Common/         # shared library; other services replace to it
├── NimoOS-MessageBus/     # generate this first
├── NimoOS/  NimoOS-Gateway/  NimoOS-UserService/  ...
└── NimoOS-UI/
```

**Generate MessageBus first.** Its generated code is not committed, and every
other service's `go generate` consumes its OpenAPI spec:

```bash
cd NimoOS-MessageBus && go generate ./...
```

**CGO matrix.** `nimoos` (SQLite), `ai` and `wiki` (go-systemd), and `photos`
(SQLite + sqlite-vec, needs the system `sqlite3.h`) require `CGO_ENABLED=1` and
gcc. `gateway`, `message-bus`, `user-service`, `local-storage`,
`app-management`, `search` and `terminal` are pure Go.

**Pinned versions.** Go services pin `go 1.21` and echo v4.12 —
**do not run `go mod tidy`**, it silently bumps them and breaks builds on
target machines.

Parser is a Python service; use `uv` with Python 3.11 (`rapidocr-onnxruntime`
has no wheel for 3.12 or later).

**The UI takes its version from the environment.** `pnpm build` on its own
produces a bundle labelled with a stale hardcoded version; `deploy-ui.sh`
exports `NIMOOS_VERSION` and `NIMOOS_BUILD` from `versions.conf` first, so build
it through that script (or export the same two variables yourself).

## Installing what you built

`scripts/deploy.sh <service>` replaces one binary and restarts its systemd unit,
so it presumes NimoOS is **already installed** — it is a development loop, not a
way to get from nothing to a running machine.

To install from source on a fresh machine, give the installer a build directory
instead of letting it download release tarballs:

```bash
sudo bash nimoos-install.sh -p /path/to/build
```

A release tarball is just one component's `build/` directory with its binary at
`build/sysroot/usr/bin/<name>` (see any `.goreleaser.yaml`), and the installer
untars all of them over each other before installing the union. So the build
directory `-p` wants is the merge of every component's `build/` tree with the
binaries you compiled dropped into `sysroot/usr/bin/` — including the
`cmd/migration-tool` binaries, which the migration scripts invoke.

The AI and RAG stack is a separate step and needs no build directory: each
`scripts/install-*.sh` builds from a sibling source tree when it finds one and
falls back to downloading a release tarball when it does not.

## Versioning

`NIMOOS_VERSION` in `versions.conf` is the only value you edit by hand.
Build-time injection produces:

- release artifacts — `<version>+<build>`
- development builds — `<version>+<build>.g<sha>`

`NIMOOS_VERSION_OVERRIDE` lets a caller pin a different version for one build
without editing the file.

## License

Apache-2.0 — see [`LICENSE`](./LICENSE).
