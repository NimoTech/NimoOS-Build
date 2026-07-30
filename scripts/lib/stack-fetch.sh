#!/usr/bin/env bash
# stack-fetch.sh — 共享库:为 install-*.sh 提供「双模式产物获取」
#
#   开发机(有源码)   → 直接用同级 NimoOS-* 源码目录(保持原有行为)
#   终端用户(无源码) → 从深圳 OSS 下载对应 release tar 并解包到临时目录
#
# 被各 install-*.sh 通过 `source .../lib/stack-fetch.sh` 引入。
# 下载域名/前缀/版本可由环境变量覆盖(供 nimoos-stack-install.sh 统一注入)。

# 上传与安装统一走深圳(与 release/versions.conf 的 DOWNLOAD_DOMAIN 一致)
: "${NIMO_DOWNLOAD_DOMAIN:=https://nimoos.oss-cn-shenzhen.aliyuncs.com/}"
: "${NIMO_OSS_PREFIX:=NimoTech}"
# 第三方依赖(qdrant / ollama 等官方二进制包)托管在 OSS 的 deps/ 下,
# 让无法直连 github.com / ollama.com 的机器也能装。布局:
#   ${NIMO_DEPS_BASE}/qdrant/qdrant-<arch>.tar.gz
#   ${NIMO_DEPS_BASE}/ollama/ollama-linux-<arch>.tar.zst
: "${NIMO_DEPS_BASE:=https://nimoos.oss-cn-shenzhen.aliyuncs.com/deps}"
# 各组件默认版本(可被环境变量覆盖,如 STACK_VERSION_PARSER)
: "${STACK_VERSION:=v1.9.1-alpha1}"

# uname -m → release 架构 token
stack_arch() {
    case "$(uname -m)" in
        x86_64)         echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l)         echo "arm-7" ;;
        riscv64)        echo "riscv64" ;;
        *)              echo "amd64" ;;
    esac
}

# stack_download <project> <version> <tarfile> <dest_dir>
#   把 OSS 上的 tar 下载并解包进 dest_dir(需已存在)。失败返回非 0。
stack_download() {
    local project="$1" version="$2" tarfile="$3" dest="$4"
    local url="${NIMO_DOWNLOAD_DOMAIN}${NIMO_OSS_PREFIX}/${project}/releases/download/${version}/${tarfile}"
    local tmp
    tmp="$(mktemp)"
    echo "[fetch] ${url}" >&2
    if ! curl -fSL --retry 3 --connect-timeout 10 -o "${tmp}" "${url}"; then
        rm -f "${tmp}"
        echo "[fetch] 下载失败: ${url}" >&2
        return 1
    fi
    if ! tar -xzf "${tmp}" -C "${dest}"; then
        rm -f "${tmp}"
        echo "[fetch] 解包失败: ${tarfile}" >&2
        return 1
    fi
    rm -f "${tmp}"
}

# stack_resolve <src_dir> <project> <version> <arch_mode> <token>
#   决定组件产物根目录并打印到 stdout:
#     - src_dir 存在 → 回显 src_dir(开发机源码模式,调用方按原逻辑 build/拷贝)
#     - 否则        → 下载 linux-<arch|all>-<token>-<version>.tar.gz 解到临时目录并回显该目录
#   解包后的目录布局与源码仓库一致(均含 build/sysroot/...),调用方无需区分。
#   返回值:0=源码模式, 10=OSS 模式(已下载), 非0=失败
stack_resolve() {
    local src_dir="$1" project="$2" version="$3" arch_mode="$4" token="$5"
    if [ -n "${src_dir}" ] && [ -d "${src_dir}" ]; then
        echo "${src_dir}"
        return 0
    fi
    local arch tarfile dest
    if [ "${arch_mode}" = "all" ]; then arch="all"; else arch="$(stack_arch)"; fi
    tarfile="linux-${arch}-${token}-${version}.tar.gz"
    dest="$(mktemp -d)"
    if ! stack_download "${project}" "${version}" "${tarfile}" "${dest}"; then
        rm -rf "${dest}"
        return 1
    fi
    echo "${dest}"
    return 10
}

# stack_fetch_dep <relpath> <dest_file>
#   从 OSS deps/ 下载第三方依赖包到 dest_file。relpath 形如 qdrant/qdrant-x86_64-...
#   成功返回 0,失败(网络/404)返回非 0,由调用方决定是否回退到上游官方源。
stack_fetch_dep() {
    local relpath="$1" dest="$2"
    local url="${NIMO_DEPS_BASE}/${relpath}"
    echo "[dep-fetch] ${url}" >&2
    curl -fSL --retry 3 --connect-timeout 10 -o "${dest}" "${url}"
}
