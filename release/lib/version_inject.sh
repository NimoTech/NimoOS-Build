# shellcheck shell=bash
# Shared version/build resolution for deploy.sh & release.sh.
# Requires NIMOOS_VERSION in scope (source versions.conf first).

# _build_number_floor: 从 builds.log 取历史出现过的最大 build 号, 作为下界。
# 计数器文件若丢失/被清空/损坏 (如换机迁移), 用它兜底, 保证 build 号【只增不减、
# 不与历史重复】。兼容两种历史行格式: "build=<n>" 与 "version=<ver>+<n>"。
# $1 = 计数器文件路径 (builds.log 与其同目录)。读不到时返回 0。
_build_number_floor() {
  local log; log="$(dirname "$1")/builds.log"
  [ -r "$log" ] || { printf '0'; return 0; }
  awk '{
    for (i=1;i<=NF;i++) {
      if ($i ~ /^build=[0-9]+$/)            { n=substr($i,7)+0; if(n>m)m=n }
      else if ($i ~ /^version=.*\+[0-9]/)   { k=$i; sub(/^.*\+/,"",k); n=k+0; if(n>m)m=n }
    }
  } END { printf "%d", m+0 }' "$log" 2>/dev/null || printf '0'
}

# _next_build_number: 原子地取下一个【机器级单调、只增不减】build 号 (dev 部署与 release 共用)。
# 计数器文件默认 ~/.nimoos-ci/build-number, 可用 NIMOOS_BUILD_COUNTER 覆盖。
# 用 flock 串行化 read-modify-write, 防 deploy.sh 与打包定时器并发时撞号。
# 起点 = max(计数器当前值, builds.log 历史最大号); 文件缺失/损坏也绝不回退到 1、
# 不重复历史号。任何一步失败 (目录不可写等) 都退化为 0, 绝不让调用方 (set -e) 中断。
_next_build_number() {
  local f="${NIMOOS_BUILD_COUNTER:-$HOME/.nimoos-ci/build-number}"
  mkdir -p "$(dirname "$f")" 2>/dev/null || { printf '0'; return 0; }
  (
    flock 200 2>/dev/null || true
    cur="$(cat "$f" 2>/dev/null)"
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac       # 缺失/非数字 -> 0
    floor="$(_build_number_floor "$f")"             # 历史高水位 (可跨重置恢复)
    [ "$floor" -gt "$cur" ] && cur="$floor"         # 只增不减: 起点不低于历史
    c=$(( cur + 1 ))
    printf '%s\n' "$c" > "$f" 2>/dev/null || true
    printf '%s' "$c"
  ) 200>"${f}.lock" 2>/dev/null || printf '0'
}

# resolve_full_version: prints "$NIMOOS_VERSION+$build".
#   NIMOOS_BUILD 已设 (release/CI 显式传入)  -> <ver>+<NIMOOS_BUILD>          (如 1.9.3-alpha1+15)
#   未设 (deploy.sh 等 dev 构建)             -> <ver>+<N>.g<sha>[-dirty]      (如 1.9.3-alpha1+16.g730794d)
#     N = 机器级单调 build 号 (每次调用分配一个, 与 release 共用同一计数器)
#     g<sha> 保留提交溯源, 也让 dev 构建一眼区别于发布产物 (后者无 .g<sha> 尾巴)
# 注意: dev 分支【有副作用】—— 每次调用都会分配 (递增) 一个新 build 号。
#       调用方每次构建应只调用一次 (deploy.sh / deploy-ui.sh / deploy-parser.sh 均如此)。
resolve_full_version() {
  local build="${NIMOOS_BUILD:-}"
  if [ -z "$build" ]; then
    local n sha
    n="$(_next_build_number)"
    sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [ -n "$(git status --porcelain 2>/dev/null)" ] && sha="${sha}-dirty"
    build="${n}.g${sha}"
  fi
  printf '%s+%s' "${NIMOOS_VERSION}" "${build}"
}

# GO_VERSION_SYM: deploy.sh service key -> ldflags -X target (pkg.Var)
declare -gA GO_VERSION_SYM=(
  [nimoos]="github.com/NimoTech/NimoOS/common.VERSION"
  [gateway]="github.com/NimoTech/NimoOS-Gateway/common.Version"
  [message-bus]="github.com/NimoTech/NimoOS-MessageBus/common.MessageBusVersion"
  [user-service]="github.com/NimoTech/NimoOS-UserService/common.Version"
  [local-storage]="github.com/NimoTech/NimoOS-LocalStorage/common.Version"
  [app-management]="github.com/NimoTech/NimoOS-AppManagement/common.AppManagementVersion"
  [ai]="github.com/NimoTech/NimoOS-AI/common.AIVersion"
  [wiki]="github.com/NimoTech/NimoOS-Wiki/common.WikiVersion"
  [search]="github.com/NimoTech/NimoOS-Search/common.Version"
  [photos]="github.com/NimoTech/NimoOS-Photos/common.PhotosVersion"
  [terminal]="github.com/NimoTech/NimoOS-Terminal/config.Version"
)
