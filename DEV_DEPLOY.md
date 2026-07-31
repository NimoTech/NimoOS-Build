# NimoOS development and deployment guide

Paths below use `$WS` for your workspace — the directory holding the sibling
repositories:

```bash
export WS=~/nimoos     # wherever clone_all.sh put them
```

## systemd units and their sources

| systemd unit | binary | source | CGO |
|---|---|---|---|
| `nimoos.service` | `/usr/bin/nimoos` | `NimoOS/` | yes (SQLite) |
| `nimoos-gateway.service` | `/usr/bin/nimoos-gateway` | `NimoOS-Gateway/` | no |
| `nimoos-app-management.service` | `/usr/bin/nimoos-app-management` | `NimoOS-AppManagement/` | no |
| `nimoos-local-storage.service` | `/usr/bin/nimoos-local-storage` | `NimoOS-LocalStorage/` | no |
| `nimoos-message-bus.service` | `/usr/bin/nimoos-message-bus` | `NimoOS-MessageBus/` | no |
| `nimoos-user-service.service` | `/usr/bin/nimoos-user-service` | `NimoOS-UserService/` | no |
| `nimoos-search.service` | `/usr/bin/nimoos-search` | `NimoOS-Search/` | no |
| `nimoos-terminal.service` | `/usr/bin/nimoos-terminal` | `NimoOS-Terminal/` | no |
| `nimoos-ai.service` | `/usr/bin/nimoos-ai` | `NimoOS-AI/` | yes (go-systemd) |
| `nimoos-wiki.service` | `/usr/bin/nimoos-wiki` | `NimoOS-Wiki/` | yes (SQLite + go-systemd) |
| `nimoos-photos.service` | `/usr/bin/nimoos-photos` | `NimoOS-Photos/` | yes (SQLite + sqlite-vec) |
| `nimoos-parser.service` | `/opt/nimoos-parser/venv/bin/python` | `NimoOS-Parser/` | Python |
| `nimoos-agent.service` | `/var/lib/nimoos/ai/agent/venv/bin/python main.py` | `NimoOS-AI/agent/` | Python |

Configuration lives in `/etc/nimoos/`, so replacing a binary never touches it.

The two Python services do not follow the `cp` to `/usr/bin/` pattern:

- **agent** is deployed to `/usr/share/nimoos/agent/`. Update it with
  `NimoOS-Build/scripts/deploy-agent.sh`, or re-run `install-ai.sh`.
- **parser** is deployed to `/opt/nimoos-parser/`. Update it with
  `NimoOS-Build/scripts/deploy-parser.sh`.

## The one-line way

`deploy.sh` builds, injects the version, replaces the binary and restarts the
unit:

```bash
bash $WS/NimoOS-Build/scripts/deploy.sh <service>
```

`<service>` is one of: `nimoos`, `gateway`, `message-bus`, `user-service`,
`local-storage`, `app-management`, `ai`, `wiki`, `search`, `photos`, `terminal`.

Prefer this over doing it by hand — `deploy.sh` also stamps the build version via
ldflags, which a plain `go build` does not, leaving the service reporting an
unknown version in the UI.

## Doing it by hand

```bash
# 1. Build. Add CGO_ENABLED=1 for the services marked "yes" in the table above.
cd $WS/<source-directory>
go build -o <binary> .

# 2. Stop, replace, start
sudo systemctl stop <unit>
sudo cp <binary> /usr/bin/<binary>
sudo systemctl start <unit>

# 3. Confirm it came up
sudo journalctl -u <unit> -f
```

Two worked examples:

```bash
# a pure Go service
cd $WS/NimoOS-Gateway && \
  go build -o nimoos-gateway . && \
  sudo systemctl stop nimoos-gateway && \
  sudo cp nimoos-gateway /usr/bin/ && \
  sudo systemctl start nimoos-gateway

# a service that needs CGO
cd $WS/NimoOS-AI && \
  CGO_ENABLED=1 go build -o nimoos-ai . && \
  sudo systemctl stop nimoos-ai && \
  sudo cp nimoos-ai /usr/bin/ && \
  sudo systemctl start nimoos-ai
```

## Everyday commands

```bash
NIMO_UNITS="nimoos nimoos-gateway nimoos-app-management nimoos-local-storage \
nimoos-message-bus nimoos-user-service nimoos-ai nimoos-agent nimoos-wiki \
nimoos-search nimoos-photos nimoos-terminal nimoos-parser"

# status of every NimoOS service
systemctl status $NIMO_UNITS

# follow one service's log
sudo journalctl -u nimoos.service -f

# restart everything
sudo systemctl restart $NIMO_UNITS
```
