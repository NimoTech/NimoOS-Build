#!/bin/bash
# NimoOS 仓库批量克隆脚本
# 在另一台电脑上运行此脚本来克隆所有仓库(与 monorepo 目录结构一致)。
# 单个仓库失败不中断,末尾汇总;已存在的目录跳过(可重复运行)。
#
# 用法: ./clone_all.sh [目标目录]   (默认 ~/nimo_os)

DEST_DIR="${1:-$HOME/nimo_os}"
mkdir -p "$DEST_DIR"
cd "$DEST_DIR" || { echo "无法进入 $DEST_DIR"; exit 1; }

echo "克隆目标目录: $DEST_DIR"
echo ""

# NimoTech 组织下的仓库(顺序无关;NimoOS-get 克隆到 get 目录)
# 每行: <仓库名> [目标目录名]
NIMOTECH_REPOS=(
    "NimoOS"                # 核心:文件管理/系统监控/Samba/云存储挂载
    "NimoOS-Gateway"        # API 网关(唯一对外入口)
    "NimoOS-MessageBus"     # 服务间 pub/sub + WebSocket
    "NimoOS-UserService"    # 用户/JWT/JWKS
    "NimoOS-LocalStorage"   # 磁盘/MergerFS/USB
    "NimoOS-AppManagement"  # Docker Compose 应用 + AppStore
    "NimoOS-AI"             # LLM 路由 + Python Agent + 对外 MCP server
    "NimoOS-Search"         # RAG 检索 API
    "NimoOS-Wiki"           # 可见长期记忆(.wiki.md)
    "NimoOS-Photos"         # 相册(EXIF/缩略图/本地向量)
    "NimoOS-Parser"         # Python 索引服务(docling + 嵌入 → Qdrant)
    "NimoOS-AppStore"       # AppStore 应用清单与缓存(数据仓库)
    "NimoOS-Terminal"       # 面板内置远程 Web 终端(ttyd + tmux + 薄 Go 服务)
    "NimoOS-Common"         # 共享库:JWT/zap/HTTP/服务间 SDK
    "NimoOS-CLI"            # Cobra CLI 管理/诊断工具
    "NimoOS-UI"             # Vue 2 SPA
    "NimoOS-get get"        # 一键安装脚本(克隆到 get/)
)

success=0
failed=0
skipped=0
failed_list=()

clone_repo() {
    local url="$1" dir="$2"
    if [ -d "$dir/.git" ]; then
        echo "跳过(已存在): $dir"
        skipped=$((skipped + 1))
        return
    fi
    echo ">>> 克隆 $dir"
    if git clone "$url" "$dir"; then
        success=$((success + 1))
    else
        echo "[ERROR] 克隆失败: $url"
        failed=$((failed + 1))
        failed_list+=("$dir")
    fi
    echo ""
}

# 文档仓库(个人仓)
# nimo_os_docs 是内部文档仓(私有), 外部贡献者无需也无法克隆 —— 构建不依赖它
# clone_repo "git@github.com:leihaowen/nimo_os_docs.git" "nimo_os_docs"

# NimoTech 仓库
for entry in "${NIMOTECH_REPOS[@]}"; do
    repo="${entry%% *}"                       # 第一段:仓库名
    dir="${entry#* }"; [ "$dir" = "$entry" ] && dir="$repo"   # 第二段:目标目录名(缺省=仓库名)
    clone_repo "git@github.com:NimoTech/${repo}.git" "$dir"
done

echo ""
echo "全部克隆完成! 成功 $success, 跳过 $skipped, 失败 $failed"
[ "$failed" -gt 0 ] && echo "失败仓库: ${failed_list[*]}"
echo ""
echo "目录结构:"
ls -1 "$DEST_DIR"
