#!/bin/sh
# =============================================================================
# Rust.DDNS Linux 一键安装（文件就位 + 安装到本机星尘）
# -----------------------------------------------------------------------------
# 把 Rust.DDNS 部署到本机并以星尘（Pek.RAgent / C# StarAgent）子服务方式托管：
#   文件就位 → 停止旧实例 → 注册子服务（-AddService，注册即启用）→ 配置就绪检查。
#   config.json 未就绪（缺失或仍是模板占位）时：自动放置配置模板并「暂不启动」，
#   填好后一键启动，避免星尘对无效配置反复拉起。
#
# 参考实现：DHDeploy.Agent.Rust/deploy/install.sh、Pek.RAgent/packaging/install-app.sh
#
# 用法（在解压目录内执行）：
#   sudo sh install.sh                              就地安装（配置/日志都在本目录）
#   sudo sh install.sh /opt/rust-ddns               安装到指定目录
#   sudo sh install.sh --no-agent                   只部署文件，不注册（自行 systemd 运行）
#   sudo sh install.sh --agent-exe <星尘程序路径>   自动探测失败时手动指定
#   sudo sh install.sh --unregister                 从星尘注销（停止并移除条目；保留文件）
#   sudo sh install.sh --name <子服务名>             多实例：注册为不同子服务名（默认 Rust_DDNS）
#
# 说明：
#   - 本程序为常驻服务（按 config.json 的 interval_sec 轮询，默认 60 秒）；
#   - 升级＝直接覆盖 Rust_DDNS 程序文件——星尘监视到变动后自动重启（约 5~10 秒）；
#   - 星尘探测顺序：--agent-exe → systemd 单元（StarAgentRust/StarAgent）→ 运行中
#     进程（pek-ragent）→ 常见安装路径；C# 版星尘无 -AddService，按提示在面板注册。
# =============================================================================
set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_NAME="Rust_DDNS"
SERVICE_NAME="Rust_DDNS"

TARGET=""
AGENT_EXE=""
DO_REGISTER=1
DO_UNREGISTER=0

usage() {
    cat <<'EOF'
用法：
  sudo sh install.sh                              就地安装 + 注册进星尘
  sudo sh install.sh /opt/rust-ddns               安装到指定目录
  sudo sh install.sh --no-agent                   只部署文件，不注册
  sudo sh install.sh --agent-exe <星尘程序路径>   手动指定星尘程序（自动探测失败时）
  sudo sh install.sh --unregister                 从星尘注销（停止并移除条目）
  sudo sh install.sh --name <子服务名>             多实例：注册为不同子服务名（默认 Rust_DDNS）
  -h | --help                                     显示帮助
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-agent) DO_REGISTER=0; shift ;;
        --unregister) DO_UNREGISTER=1; shift ;;
        --name)
            [ -n "${2:-}" ] || { echo "错误：--name 缺少参数" >&2; exit 2; }
            SERVICE_NAME=$2; shift 2 ;;
        --agent-exe)
            [ -n "${2:-}" ] || { echo "错误：--agent-exe 缺少参数" >&2; exit 2; }
            AGENT_EXE=$2; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "未知参数：$1（-h 查看用法）" >&2; exit 2 ;;
        *) TARGET=$1; shift ;;
    esac
done
[ -n "$TARGET" ] || TARGET=$SELF_DIR

# ---- 星尘程序探测 ----
detect_agent_exe() {
    if [ -n "$AGENT_EXE" ]; then
        if [ -f "$AGENT_EXE" ]; then
            printf '%s\n' "$AGENT_EXE"
            return 0
        fi
        echo "警告：--agent-exe 指定的文件不存在：$AGENT_EXE" >&2
    fi
    # systemd 单元（StarAgentRust = Rust 版；StarAgent = C# 版/旧名）
    if command -v systemctl >/dev/null 2>&1; then
        for unit in StarAgentRust StarAgent staragent; do
            exe=$(systemctl show -p ExecStart --value "$unit" 2>/dev/null | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -n 1)
            if [ -n "$exe" ] && [ -f "$exe" ]; then
                printf '%s\n' "$exe"
                return 0
            fi
        done
    fi
    # 运行中进程
    if command -v pidof >/dev/null 2>&1; then
        pid=$(pidof pek-ragent 2>/dev/null | awk '{print $1}')
        if [ -n "$pid" ]; then
            exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
            if [ -n "$exe" ] && [ -f "$exe" ]; then
                printf '%s\n' "$exe"
                return 0
            fi
        fi
    fi
    # 常见安装路径
    for p in /www/Agent/pek-ragent /opt/staragent/pek-ragent /opt/StarAgentRust/pek-ragent /usr/local/bin/pek-ragent; do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# ---- 本地控制接口（Rust 星尘 5501 / C# 星尘 5500；用于注销停止）----
agent_http() {
    command -v curl >/dev/null 2>&1 || return 1
    for port in 5501 5500; do
        resp=$(curl -s -m 15 "http://127.0.0.1:$port/$1" 2>/dev/null) || continue
        [ -n "$resp" ] || continue
        case "$resp" in
            *'"Success":true'*) return 0 ;;
            *) return 1 ;;
        esac
    done
    return 1
}

# ---- 注销模式 ----
if [ "$DO_UNREGISTER" = 1 ]; then
    echo "注销子服务 [$SERVICE_NAME]（保留文件与配置）…"
    agent_http "StopService?serviceName=$SERVICE_NAME" \
        || echo "  （停止请求未受理：星尘可能未运行或服务不存在；继续尝试移除条目）"
    REMOVED=0
    if command -v curl >/dev/null 2>&1; then
        for port in 5501 5500; do
            resp=$(curl -s -m 15 -X POST -H 'Content-Type: application/json' \
                   -d "{\"serviceName\":\"$SERVICE_NAME\"}" \
                   "http://127.0.0.1:$port/star/removeService" 2>/dev/null) || continue
            [ -n "$resp" ] || continue
            REMOVED=1
            printf '%s\n' "$resp"
            break
        done
    fi
    if [ "$REMOVED" = 1 ]; then
        echo "完成：已请求星尘移除条目（可在面板「子服务」页确认）。"
    else
        echo "未完成自动移除（星尘未运行或接口不可达）。请在星尘面板「子服务」页删除 [$SERVICE_NAME]，"
        echo "或编辑星尘配置 Config/StarAgent.config 移除对应条目。"
    fi
    exit 0
fi

# ---- [1/4] 文件就位 ----
SRC="$SELF_DIR/$BIN_NAME"
[ -f "$SRC" ] || { echo "错误：未找到 $SRC（请在含 $BIN_NAME 的目录内运行本脚本）" >&2; exit 1; }
mkdir -p "$TARGET"
TARGET=$(CDPATH= cd -- "$TARGET" && pwd)
DST="$TARGET/$BIN_NAME"
if [ "$SRC" != "$DST" ]; then
    cp -f "$SRC" "$DST"
fi
chmod +x "$DST"
echo "[1/4] 文件就位：$DST"

# 配置模板：目标目录无 config.json 时，尝试从脚本目录放置 config.example.json
CONFIG="$TARGET/config.json"
if [ ! -f "$CONFIG" ] && [ -f "$SELF_DIR/config.example.json" ]; then
    cp "$SELF_DIR/config.example.json" "$CONFIG"
    echo "      已放置配置模板：$CONFIG（请填写域名与 DNSPod Token 等）"
fi

# ---- [2/4~3/4] 星尘探测与注册 ----
READY=0
REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
    STAR_EXE=$(detect_agent_exe || true)
    if [ -z "$STAR_EXE" ]; then
        echo "[2/4] 未探测到星尘（Pek.RAgent / StarAgent）"
        echo "[3/4] 跳过注册：如服务器装有星尘，可用 --agent-exe <路径> 指定后重跑；"
        echo "      或在星尘面板手动注册：名称 $SERVICE_NAME，程序 $DST，目录 $TARGET"
    else
        case "$STAR_EXE" in
            *pek-ragent*)
                echo "[2/4] 检测到星尘（Pek.RAgent）：$STAR_EXE"
                # 覆盖安装/升级：先停旧实例（不存在时静默忽略）
                "$STAR_EXE" -StopService "$SERVICE_NAME" >/dev/null 2>&1 || true
                echo "[3/4] 注册子服务：$SERVICE_NAME"
                "$STAR_EXE" -AddService "$SERVICE_NAME" "$DST" "$TARGET" \
                    || { code=$?; echo "注册失败（退出码 $code）：详见上方星尘输出" >&2; exit $code; }
                REGISTERED=1
                ;;
            *)
                echo "[2/4] 检测到非 Rust 版星尘：$STAR_EXE"
                echo "[3/4] 跳过自动注册：C# 版请在星尘面板注册 ——"
                echo "      名称 $SERVICE_NAME，程序 $DST，目录 $TARGET"
                ;;
        esac
    fi
else
    echo "[2/4] --no-agent：跳过星尘探测"
    echo "[3/4] 跳过注册（请自行以 systemd/前台方式运行）"
fi

# ---- [4/4] 配置就绪检查 ----
# 未就绪 = 无 config.json，或仍是模板占位（占位配置运行会退出，星尘将反复拉起）
if [ -f "$CONFIG" ] && ! grep -Eq "你的TokenId|example\.com" "$CONFIG" 2>/dev/null; then
    READY=1
fi

if [ "$READY" = 1 ]; then
    echo "[4/4] 配置就绪：$CONFIG"
    if [ "$REGISTERED" = 1 ]; then
        echo "      子服务已由星尘拉起；修改配置后重启生效（面板「子服务」页或 -RestartService $SERVICE_NAME）"
    fi
elif [ "$REGISTERED" = 1 ]; then
    # 占位/缺失配置：先停用，避免星尘反复拉起无效配置（-StopService 会同时禁用）
    "$STAR_EXE" -StopService "$SERVICE_NAME" >/dev/null 2>&1 || true
    echo "[4/4] 配置未就绪：已安装但「暂未启动」"
    echo "      ① 编辑配置：$CONFIG（域名 / DNSPod Token 等）"
    echo "      ② 启动子服务：「$STAR_EXE」 -StartService $SERVICE_NAME（或星尘面板「子服务」页启动）"
else
    echo "[4/4] 配置未就绪：$CONFIG（填写后即可运行）"
fi

echo ""
echo "=============================================================="
echo " [Rust.DDNS] 安装完成"
echo "   程序：$DST"
echo "   目录：$TARGET"
if [ "$REGISTERED" = 1 ]; then
    if [ "$READY" = 1 ]; then
        echo "   托管：由星尘守护（覆盖程序文件后自动重启升级）"
        echo "   状态：已启动"
    else
        echo "   托管：已注册进星尘（当前为停用状态，配置完成后启动）"
        echo "   状态：待配置"
    fi
elif [ "$DO_REGISTER" = 0 ]; then
    echo "   托管：未注册（自行管理）"
else
    echo "   托管：未注册进星尘（见上方 [2/4][3/4] 提示）"
fi
echo "   配置：$CONFIG"
echo "=============================================================="
