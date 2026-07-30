#!/usr/bin/env bash
# install-qdrant.sh — 把 qdrant 从 docker 容器迁成原生 systemd 服务
#
# 为什么:
#   - Parser 的 unit 写了 After=qdrant.service / Wants=qdrant.service,
#     但目前 qdrant 是 `docker run`,没有 systemd unit,这层依赖等于空话,
#     重启后 parser 有可能比 qdrant 早起来导致连不上。
#   - NAS UI 的 AppManagement 会把这个独立容器当用户应用列出来,看着碍眼。
#
# 做什么:
#   - 从 github 下载 qdrant 二进制 (默认 v1.18.1,跟当前 docker image 同版本)
#   - 装到 /usr/local/bin/qdrant
#   - 写 /etc/qdrant/config.yaml(只监听 127.0.0.1,数据沿用 /opt/qdrant/storage)
#   - 装 /usr/lib/systemd/system/qdrant.service
#   - 停掉旧 docker 容器(不删,验证完再手动 docker rm)
#   - 启动并校验 6333 / 6334
#
# 用法:
#   sudo bash install-qdrant.sh [--version v1.18.1] [--tarball <path>] [--remove-docker]
#
#   --version        换其他版本
#   --tarball PATH   用本地已下好的 qdrant-*.tar.gz,不走网络下载
#   --remove-docker  原生 qdrant 起来并验证后,自动 docker rm 旧容器
#
# 数据兼容性:同版本同 storage_path = 原地启动即可,不需要 dump/restore。

set -e

((EUID)) && sudo_cmd="sudo" || sudo_cmd=""

QDRANT_VERSION="v1.18.1"
LOCAL_TARBALL=""
REMOVE_DOCKER=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) QDRANT_VERSION="$2"; shift 2 ;;
        --tarball) LOCAL_TARBALL="$2"; shift 2 ;;
        --remove-docker) REMOVE_DOCKER=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

###############################################################################
# Paths
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 复用 stack-fetch.sh 的 OSS deps 基址(standalone 运行时 lib 可能缺,用内置默认兜底)
if [[ -f "${SCRIPT_DIR}/lib/stack-fetch.sh" ]]; then
    # shellcheck source=lib/stack-fetch.sh
    source "${SCRIPT_DIR}/lib/stack-fetch.sh"
fi
: "${NIMO_DEPS_BASE:=https://nimoos.oss-cn-shenzhen.aliyuncs.com/deps}"

readonly SERVICE_FILE="qdrant.service"
readonly UNIT_DST="/usr/lib/systemd/system/${SERVICE_FILE}"
readonly BIN_DST="/usr/local/bin/qdrant"
readonly CONF_DIR="/etc/qdrant"
readonly CONF_FILE="${CONF_DIR}/config.yaml"
readonly STORAGE_DIR="/opt/qdrant/storage"
readonly SNAPSHOT_DIR="/opt/qdrant/snapshots"

###############################################################################
# Helpers
###############################################################################

log_info()  { echo -e "\e[32m[ INFO ]\e[0m $*"; }
log_ok()    { echo -e "\e[32m[  OK  ]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[ WARN ]\e[0m $*"; }
log_fail()  { echo -e "\e[31m[FAILED]\e[0m $*"; exit 1; }

###############################################################################
# Steps
###############################################################################

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64)  TARBALL_ARCH="x86_64-unknown-linux-gnu" ;;
        aarch64) TARBALL_ARCH="aarch64-unknown-linux-gnu" ;;
        *) log_fail "不支持的架构: $m" ;;
    esac
    log_ok "架构:$m → $TARBALL_ARCH"
}

check_glibc() {
    # qdrant v1.10+ 的 -gnu 二进制需要 GLIBC 2.38+(Debian 12 只到 2.36)。
    # 撞墙就别浪费时间装了,直接退出建议留 docker。
    local need="2.38"
    local have
    have="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    if [[ -z "$have" ]]; then
        log_warn "无法探测 GLIBC 版本,继续(可能失败)"
        return
    fi
    # 比较 a >= b
    if [[ "$(printf '%s\n%s' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
        log_fail "宿主 GLIBC $have < $need。qdrant 二进制不兼容,继续留 docker,本脚本不适合你的发行版。"
    fi
    log_ok "GLIBC $have ≥ $need"
}

stop_docker_qdrant() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "未装 docker,跳过容器停止"
        return
    fi
    local cid
    cid="$(${sudo_cmd} docker ps -q --filter "ancestor=qdrant/qdrant" 2>/dev/null | head -1)"
    if [[ -z "$cid" ]]; then
        cid="$(${sudo_cmd} docker ps -q --filter "name=^/qdrant$" 2>/dev/null | head -1)"
    fi
    if [[ -n "$cid" ]]; then
        log_info "停止 docker qdrant 容器 $cid ..."
        ${sudo_cmd} docker stop "$cid" >/dev/null
        log_ok "docker qdrant 已停(容器保留,可后续 docker rm 或加 --remove-docker)"
    else
        log_info "未发现运行中的 docker qdrant 容器"
    fi
}

verify_storage() {
    if [[ ! -d "$STORAGE_DIR" ]]; then
        log_warn "数据目录 $STORAGE_DIR 不存在,首次启动 qdrant 会创建空库(若之前 docker 用的别处,迁移会丢数据,请确认)"
        ${sudo_cmd} mkdir -p "$STORAGE_DIR"
    else
        log_ok "保留现有数据目录:$STORAGE_DIR"
    fi
    ${sudo_cmd} mkdir -p "$SNAPSHOT_DIR" "$CONF_DIR"
}

download_binary() {
    if [[ -x "$BIN_DST" ]]; then
        local cur
        cur="$($BIN_DST --version 2>/dev/null | head -1 || echo '')"
        log_info "已有 $BIN_DST ($cur),覆盖安装 $QDRANT_VERSION ..."
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT

    local src
    if [[ -n "$LOCAL_TARBALL" ]]; then
        [[ -f "$LOCAL_TARBALL" ]] || log_fail "本地 tarball 不存在: $LOCAL_TARBALL"
        log_info "用本地 tarball:$LOCAL_TARBALL"
        src="$LOCAL_TARBALL"
    else
        # OSS deps 优先(国内/无 github 直连的机器),失败再回退 github 官方 release。
        local depfile="qdrant-${TARBALL_ARCH}.tar.gz"
        local oss_url="${NIMO_DEPS_BASE}/qdrant/${depfile}"
        local gh_url="https://github.com/qdrant/qdrant/releases/download/${QDRANT_VERSION}/${depfile}"
        log_info "下载 qdrant 二进制(OSS 优先)..."
        if curl -fL --retry 3 --connect-timeout 10 -o "$tmpdir/qdrant.tar.gz" "$oss_url"; then
            log_ok "从 OSS deps 下载成功:$oss_url"
        elif curl -fL --connect-timeout 10 -o "$tmpdir/qdrant.tar.gz" "$gh_url"; then
            log_ok "OSS 不可用,已从 GitHub 下载:$gh_url"
        else
            log_fail "下载失败(OSS deps 与 GitHub 均不可达),或先手动下好后用 --tarball <path>"
        fi
        src="$tmpdir/qdrant.tar.gz"
    fi

    log_info "解压 ..."
    tar -xzf "$src" -C "$tmpdir"
    local extracted
    extracted="$(find "$tmpdir" -maxdepth 2 -type f -name qdrant -executable | head -1)"
    [[ -n "$extracted" ]] || log_fail "tar 里没找到 qdrant 二进制"

    ${sudo_cmd} install -m 0755 "$extracted" "$BIN_DST"
    log_ok "已装 $BIN_DST ($($BIN_DST --version 2>/dev/null | head -1))"
}

write_config() {
    if [[ -f "$CONF_FILE" ]]; then
        log_info "保留已有配置:$CONF_FILE"
        return
    fi
    log_info "写最小化配置 → $CONF_FILE"
    ${sudo_cmd} tee "$CONF_FILE" >/dev/null <<EOF
# /etc/qdrant/config.yaml — 由 install-qdrant.sh 生成
# 监听 127.0.0.1 与 docker 原行为一致;若需 LAN 访问改 host 并加防火墙规则。
log_level: INFO

storage:
  storage_path: ${STORAGE_DIR}
  snapshots_path: ${SNAPSHOT_DIR}

service:
  host: 127.0.0.1
  http_port: 6333
  grpc_port: 6334
  enable_tls: false

telemetry_disabled: true
EOF
}

write_unit() {
    log_info "写 systemd unit → $UNIT_DST"
    ${sudo_cmd} tee "$UNIT_DST" >/dev/null <<EOF
[Unit]
Description=Qdrant vector database (native)
Documentation=https://qdrant.tech/documentation/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${BIN_DST} --config-path ${CONF_FILE}
WorkingDirectory=/opt/qdrant
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=qdrant

[Install]
WantedBy=multi-user.target
EOF
    ${sudo_cmd} systemctl daemon-reload
    ${sudo_cmd} systemctl enable --force --no-ask-password "$SERVICE_FILE"
}

start_and_verify() {
    log_info "启动 $SERVICE_FILE ..."
    ${sudo_cmd} systemctl start "$SERVICE_FILE"

    log_info "等待端口 6333 监听 (最多 15s) ..."
    local ok=0
    for _ in $(seq 1 15); do
        if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:6333'; then ok=1; break; fi
        sleep 1
    done
    if [[ "$ok" -eq 1 ]]; then
        log_ok "qdrant 起来了 (127.0.0.1:6333)"
        curl -sf http://127.0.0.1:6333/collections 2>/dev/null | head -c 200; echo
    else
        log_warn "15s 内未见 6333 监听,看 journalctl -u $SERVICE_FILE -n 50"
    fi

    ${sudo_cmd} systemctl status "$SERVICE_FILE" --no-pager -l --lines=8 || true
}

maybe_remove_docker() {
    if [[ "$REMOVE_DOCKER" -ne 1 ]]; then
        log_info "如确认原生 qdrant 正常,手动清掉旧容器:"
        echo "    sudo docker rm qdrant"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then return; fi
    local cid
    cid="$(${sudo_cmd} docker ps -aq --filter "name=^/qdrant$" 2>/dev/null | head -1)"
    if [[ -n "$cid" ]]; then
        log_info "移除 docker qdrant 容器 $cid ..."
        ${sudo_cmd} docker rm -f "$cid" >/dev/null
        log_ok "docker 容器已删,NAS 应用列表会刷新"
    fi
}

restart_dependents() {
    # parser 在 docker qdrant 停的那一瞬间会丢连接,起来后建议拉一下重连
    if systemctl is-active --quiet nimoos-parser 2>/dev/null; then
        log_info "重启 nimoos-parser 让它重连新 qdrant ..."
        ${sudo_cmd} systemctl restart nimoos-parser.service || true
    fi
}

###############################################################################
# Main
###############################################################################

log_info "=== Qdrant 原生安装 / docker 迁移 ==="
log_info "版本:$QDRANT_VERSION"
log_info "数据:$STORAGE_DIR (沿用 docker 原数据)"

detect_arch
check_glibc
verify_storage
download_binary
write_config
stop_docker_qdrant
write_unit
start_and_verify
restart_dependents
maybe_remove_docker

echo ""
log_ok "迁移完成。"
echo ""
echo "  二进制:  $BIN_DST"
echo "  配置:    $CONF_FILE"
echo "  数据:    $STORAGE_DIR"
echo "  日志:    journalctl -u $SERVICE_FILE -f"
echo "  集合:    curl http://127.0.0.1:6333/collections"
echo "  回滚:    sudo systemctl disable --now qdrant && sudo docker start qdrant"
