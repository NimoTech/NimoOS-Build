# NimoOS 开发与部署指南

## 服务与源码对照

| systemd 服务 | 二进制路径 | 源码目录 |
|---|---|---|
| `nimoos.service` | `/usr/bin/nimoos` | `NimoOS/` |
| `nimoos-gateway.service` | `/usr/bin/nimoos-gateway` | `NimoOS-Gateway/` |
| `nimoos-app-management.service` | `/usr/bin/nimoos-app-management` | `NimoOS-AppManagement/` |
| `nimoos-local-storage.service` | `/usr/bin/nimoos-local-storage` | `NimoOS-LocalStorage/` |
| `nimoos-message-bus.service` | `/usr/bin/nimoos-message-bus` | `NimoOS-MessageBus/` |
| `nimoos-user-service.service` | `/usr/bin/nimoos-user-service` | `NimoOS-UserService/` |
| `nimoos-ai.service` | `/usr/bin/nimoos-ai` | `NimoOS-AI/`（CGO） |
| `nimoos-agent.service` | `/var/lib/nimoos/ai/agent/venv/bin/python main.py` | `NimoOS-AI/agent/`（Python） |

配置文件统一在 `/etc/nimoos/` 下，替换二进制不影响配置。

> `nimoos-agent` 是 Python 服务，源码部署在 `/usr/share/nimoos/agent/`，不走 `cp /usr/bin/` 流程。更新方式：跑 `NimoOS-Build/scripts/deploy-agent.sh` 或重跑 `install-ai.sh`。

## 替换流程

以某服务为例（将 `<service>` 替换为实际名称，如 `nimoos`、`nimoos-app-management` 等）：

```bash
# 1. 编译
cd /home/nimo/nimoos/<源码目录>
go build -o <service> .

# 2. 停服务 → 替换二进制 → 重启
sudo systemctl stop <service>.service
sudo cp <service> /usr/bin/<service>
sudo systemctl start <service>.service

# 3. 查看日志确认启动正常
sudo journalctl -u <service>.service -f
```

## 各服务快速替换命令

```bash
# nimoos 主服务
cd /home/nimo/nimoos/NimoOS && \
  go build -o nimoos . && \
  sudo systemctl stop nimoos && \
  sudo cp nimoos /usr/bin/ && \
  sudo systemctl start nimoos

# nimoos-gateway
cd /home/nimo/nimoos/NimoOS-Gateway && \
  go build -o nimoos-gateway . && \
  sudo systemctl stop nimoos-gateway && \
  sudo cp nimoos-gateway /usr/bin/ && \
  sudo systemctl start nimoos-gateway

# nimoos-app-management
cd /home/nimo/nimoos/NimoOS-AppManagement && \
  go build -o nimoos-app-management . && \
  sudo systemctl stop nimoos-app-management && \
  sudo cp nimoos-app-management /usr/bin/ && \
  sudo systemctl start nimoos-app-management

# nimoos-local-storage
cd /home/nimo/nimoos/NimoOS-LocalStorage && \
  go build -o nimoos-local-storage . && \
  sudo systemctl stop nimoos-local-storage && \
  sudo cp nimoos-local-storage /usr/bin/ && \
  sudo systemctl start nimoos-local-storage

# nimoos-message-bus
cd /home/nimo/nimoos/NimoOS-MessageBus && \
  go build -o nimoos-message-bus . && \
  sudo systemctl stop nimoos-message-bus && \
  sudo cp nimoos-message-bus /usr/bin/ && \
  sudo systemctl start nimoos-message-bus

# nimoos-user-service
cd /home/nimo/nimoos/NimoOS-UserService && \
  go build -o nimoos-user-service . && \
  sudo systemctl stop nimoos-user-service && \
  sudo cp nimoos-user-service /usr/bin/ && \
  sudo systemctl start nimoos-user-service

# nimoos-ai （需要 CGO）
cd /home/nimo/nimoos/NimoOS-AI && \
  CGO_ENABLED=1 go build -o nimoos-ai . && \
  sudo systemctl stop nimoos-ai && \
  sudo cp nimoos-ai /usr/bin/ && \
  sudo systemctl start nimoos-ai

# nimoos-agent （Python，部署到 /usr/share/nimoos/agent/）
bash /home/nimo/nimoos/NimoOS-Build/scripts/deploy-agent.sh
```

也可直接用 `NimoOS-Build/scripts/deploy.sh <service>` 一行完成构建+替换+重启，可用服务名：
`nimoos | gateway | message-bus | user-service | local-storage | app-management | ai`。

## 常用运维命令

```bash
# 查看所有 NimoOS 服务状态
systemctl status nimoos nimoos-gateway nimoos-app-management nimoos-local-storage nimoos-message-bus nimoos-user-service nimoos-ai nimoos-agent

# 实时查看某服务日志
sudo journalctl -u nimoos.service -f

# 重启所有服务
sudo systemctl restart nimoos nimoos-gateway nimoos-app-management nimoos-local-storage nimoos-message-bus nimoos-user-service nimoos-ai nimoos-agent
```
