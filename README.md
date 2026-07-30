# NimoOS-Build

NimoOS 的**构建与安装脚本**，以及**版本单一源** [`release/versions.conf`](./release/versions.conf)。

> ### About / 关于本项目
>
> NimoOS is a fork of [CasaOS](https://github.com/IceWhaleTech/CasaOS)
> (Apache-2.0), originally developed by IceWhale Technology Co., Ltd.
> Building on that foundation, NimoOS adds an AI agent, RAG-based
> retrieval, a knowledge layer, and a built-in web terminal.
>
> NimoOS 基于 [CasaOS](https://github.com/IceWhaleTech/CasaOS)（Apache-2.0）
> fork 而来，原始项目由 IceWhale Technology Co., Ltd. 开发。在此基础上，
> NimoOS 重建了 AI Agent、RAG 检索、知识库与内置终端等能力。
>
> 归属详情见 [`NOTICE`](./NOTICE)。CasaOS 与 IceWhale 是 IceWhale Technology
> Co., Ltd. 的商标；NimoOS 是独立项目，与 IceWhale 无隶属关系。
>
> 本仓库是 NimoTech 原创，不含 CasaOS 衍生代码。

> ⚠️ Multi-user isolation is incomplete — Photos and Search are not yet
> per-user scoped. Read
> [SECURITY.md](https://github.com/NimoTech/NimoOS/blob/main/SECURITY.md#known-limitations)
> before deploying NimoOS for more than one person.
>
> ⚠️ 多用户隔离尚不完整（Photos 与搜索未按用户隔离）。若要给多人使用，请先阅读
> [SECURITY.md](https://github.com/NimoTech/NimoOS/blob/main/SECURITY.md#known-limitations)。

## 安装

```bash
curl -fsSL https://nimoos.oss-cn-shenzhen.aliyuncs.com/get/nimoos-install.sh | sudo bash
```

> 下载源在阿里云深圳，国际用户可能较慢。改用 GitHub Releases 分发是已知的
> 待办项，见 [NimoOS 的 ROADMAP](https://github.com/NimoTech/NimoOS/blob/main/ROADMAP.md)。

AI / RAG 栈（Qdrant、Parser、Ollama）另需一步：

```bash
sudo bash scripts/nimoos-stack-install.sh
```

## 仓库内容

| 路径 | 用途 |
|---|---|
| `release/versions.conf` | **版本单一源**。改这一处，构建期经 ldflags 注入到各服务 |
| `release/lib/` | 版本注入与组件注册表（`common.sh` / `version_inject.sh`） |
| `nimoos-install.sh` · `nimoos-update.sh` · `nimoos-uninstall.sh` | 一键装 / 更新 / 卸载 |
| `scripts/install-*.sh` · `nimoos-stack-install.sh` | 各组件与 AI/RAG 栈安装 |
| `scripts/deploy*.sh` | 开发用：构建 + 替换二进制 + 重启 systemd 单元 |
| `scripts/fetch-ttyd.sh` | 内置终端依赖的 ttyd 拉取 |
| `scripts/start-ai.sh` · `update-host-agent.sh` | AI 服务启停 / host agent 就地更新 |
| `clone_all.sh` | 批量克隆各服务仓库 |
| `DEV_DEPLOY.md` | systemd 单元 ↔ 源码对照、替换二进制流程 |

## 从源码构建

NimoOS 是多仓结构，各 Go 服务通过 `replace` 指向本地的 `NimoOS-Common`，
所以**构建需要完整 checkout**：

```bash
bash clone_all.sh          # 克隆各服务仓库到同级目录
```

目录布局：

```
nimoos/
├── NimoOS-Build/          # 本仓
├── NimoOS-Common/         # 共享库（其他服务经 replace 指向它）
├── NimoOS-MessageBus/     # ⚠️ 必须最先 go generate
├── NimoOS/  NimoOS-Gateway/  NimoOS-UserService/  ...
└── NimoOS-UI/
```

**MessageBus 必须最先生成** —— 它的生成代码不入库，其他服务的 `go generate`
依赖它的 OpenAPI spec：

```bash
cd NimoOS-MessageBus && go generate ./...
```

**CGO 矩阵**：`nimoos`（SQLite）、`ai` / `wiki`（go-systemd）、`photos`
（SQLite + sqlite-vec，需系统 `sqlite3.h`）需 `CGO_ENABLED=1` + gcc；
`gateway` / `message-bus` / `user-service` / `local-storage` /
`app-management` / `search` / `terminal` 是纯 Go。

**版本钉住**：各 Go 服务钉 `go 1.21` + echo v4.12，**不要跑 `go mod tidy`**。

Parser 是 Python 服务，用 `uv` 固定 Python 3.11（`rapidocr-onnxruntime` 无
3.12+ wheel）。

## 版本号

`versions.conf` 里的 `NIMOOS_VERSION` 是唯一手改处。构建期注入格式：

- 发布产物 `<版本>+<build 号>`
- dev 构建 `<版本>+<build 号>.g<sha>`

## 许可

Apache-2.0，见 [`LICENSE`](./LICENSE)。
