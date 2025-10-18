#!/usr/bin/env bash
set -euo pipefail

# === 载入 .env（位于脚本同目录）===
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; . "$SCRIPT_DIR/.env"; set +a
fi

# === PATH ===
export PATH="${PATH:-/usr/bin:/bin}"
for p in /opt/homebrew/bin /usr/local/bin; do
  [ -d "$p" ] && PATH="$p:$PATH"
done

# === 基础配置（支持 .env 覆盖）===
VPN_HOST="${VPN_HOST:-vpn-ct.ecnu.edu.cn}"
: "${VPN_USER:?Set VPN_USER in environment or .env}"
KEYCHAIN_LABEL="${KEYCHAIN_LABEL:-ECNU_VPN}"
USERAGENT="${USERAGENT:-AnyConnect Windows 4.10.06079}"
AUTHGROUP="${AUTHGROUP-}"
SECOND_FACTOR="${SECOND_FACTOR-}"
SERVERCERT_PIN="${SERVERCERT_PIN-}"

# 可执行文件：优先 env 指定，其次自动发现
if [ -z "${OPENCONNECT_BIN-}" ]; then
  if command -v openconnect >/dev/null 2>&1; then
    OPENCONNECT_BIN="$(command -v openconnect)"
  elif command -v brew >/dev/null 2>&1 && brew --prefix openconnect >/dev/null 2>&1; then
    OPENCONNECT_BIN="$(brew --prefix openconnect 2>/dev/null)/bin/openconnect"
  else
    echo "❌ 未找到 openconnect，请先安装（brew install openconnect）" >&2
    exit 1
  fi
fi

# 组件路径：默认相对脚本目录（.env 可覆盖）
VPN_SCRIPT="${VPN_SCRIPT:-$SCRIPT_DIR/vpnc-noroute.sh}"
SPLIT_MODULE="${SPLIT_MODULE:-$SCRIPT_DIR/ecnu-split.sh}"
DOMAINS_FILE_DEFAULT="${DOMAINS_FILE_DEFAULT:-$SCRIPT_DIR/academic-domains.txt}"

# === 运行时文件 ===
LOGFILE="${LOGFILE:-./tmp/ecnu-vpn.log}"
PIDFILE="${PIDFILE:-./tmp/openconnect-ecnu.pid}"
SPLIT_ROUTES_FILE="${SPLIT_ROUTES_FILE:-./tmp/ecnu-vpn.split-routes}"
SPLIT_LOGFILE="${SPLIT_LOGFILE:-./tmp/ecnu-vpn-routes.log}"

# 分流子模块（可选）
SPLIT_MODULE="${SPLIT_MODULE:-$HOME/Projects/scripts/ecnu-vpn/ecnu-split.sh}"
DOMAINS_FILE_DEFAULT="${DOMAINS_FILE_DEFAULT:-$HOME/Projects/scripts/ecnu-vpn/academic-domains.txt}"

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# === 把相对路径规范化为绝对路径（相对于脚本目录）===
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

make_abs() {
  # $1=var_name
  local v; v="${!1-}"
  [ -z "$v" ] && return 0
  case "$v" in
    /*) : ;;                                # 已经是绝对路径
    *)  printf -v "$1" "%s/%s" "$SCRIPT_DIR" "$v" ;;
  esac
}

make_abs LOGFILE
make_abs PIDFILE
make_abs SPLIT_ROUTES_FILE
make_abs SPLIT_LOGFILE
make_abs DOMAINS_FILE_DEFAULT
make_abs VPN_SCRIPT
make_abs SPLIT_MODULE

mkdir -p "$(dirname "$LOGFILE")" \
         "$(dirname "$SPLIT_LOGFILE")" \
         "$(dirname "$PIDFILE")" \
         "$(dirname "$SPLIT_ROUTES_FILE")"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE" >&2; }
is_running(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
ensure_sudo(){ [ "$(id -u)" -ne 0 ] && { sudo -n -v 2>/dev/null || { log "🔐 需要管理员密码（sudo -v）"; sudo -v; }; } || true; }

# ---- 密码 ----
get_password() {
  : "${VPN_USER:?VPN_USER must not be empty}"
  KEYCHAIN_LABEL="${KEYCHAIN_LABEL:-ECNU_VPN}"

  # —— 优先级：VPN_PASS_FILE > VPN_PASS > Keychain ——
  if [ -n "${VPN_PASS_FILE-}" ]; then
    if [ -r "$VPN_PASS_FILE" ]; then
      PASS="$(/bin/cat -- "$VPN_PASS_FILE")"
      log "🔑 已从文件读取密码（$VPN_PASS_FILE）"
    else
      log "❌ VPN_PASS_FILE 指向的文件不可读：$VPN_PASS_FILE"
      exit 1
    fi

  elif [ -n "${VPN_PASS-}" ]; then
    PASS="$VPN_PASS"
    log "🔑 已从环境变量读取密码"

  else
    log "🔑 正在从钥匙串读取密码（account=$VPN_USER service=${KEYCHAIN_LABEL}）"
    if PASS="$(
      /usr/bin/perl -e 'alarm 3; exec @ARGV' \
        /usr/bin/security find-generic-password \
        -a "$VPN_USER" -s "${KEYCHAIN_LABEL}" -w </dev/null 2>/dev/null
    )"; then
      :
    elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER-}" ] && PASS="$(
      /usr/bin/perl -e 'alarm 3; exec @ARGV' \
        sudo -u "$SUDO_USER" /usr/bin/security find-generic-password \
        -a "$VPN_USER" -s "${KEYCHAIN_LABEL}" -w </dev/null 2>/dev/null
    )"; then
      :
    else
      log "❌ 无法从钥匙串读取密码（account=$VPN_USER service=${KEYCHAIN_LABEL}）"
      echo "   解决A：security add-generic-password -a \"$VPN_USER\" -s \"${KEYCHAIN_LABEL}\" -w" >&2
      echo "   解决B：在 .env 里设置 VPN_PASS 或 VPN_PASS_FILE" >&2
      exit 1
    fi
  fi

  # 规范化 & 2FA 拼接（不在日志里打印明文或长度）
  PASS="${PASS%$'\n'}"
  if [ -n "${SECOND_FACTOR-}" ]; then
    PASS="${PASS},${SECOND_FACTOR}"
    log "🔒 已启用二次认证（SECOND_FACTOR）"
  fi
}

# ---- 连接 ----
run_openconnect(){
  local args=()
  args+=("https://${VPN_HOST}")
  args+=(--protocol=anyconnect)
  args+=(--user="$VPN_USER")
  args+=(--useragent="$USERAGENT")
  args+=(--passwd-on-stdin)
  args+=(--script="$VPN_SCRIPT")        # 只配置 utun；不改默认路由/DNS
  args+=(--background --pid-file="$PIDFILE" --timestamp --verbose)
  [ -n "${AUTHGROUP-}" ] && args+=(--authgroup "$AUTHGROUP")
  [ -n "${SERVERCERT_PIN-}" ] && args+=(--servercert "pin-sha256:${SERVERCERT_PIN}")
  printf "%s" "$PASS" | sudo env PATH="$PATH" "$OPENCONNECT_BIN" "${args[@]}"
}

# 启动后确保 PIDFILE 存在；否则用 pgrep 纠正并写入
ensure_pidfile() {
  # 先看指定 pidfile 是否已有
  if [ -f "$PIDFILE" ]; then
    local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  fi
  # 兜底：取“最新”的 openconnect 进程
  local p; p="$(pgrep -n -f "openconnect.*${VPN_HOST}" || true)"
  if [ -n "$p" ]; then
    printf "%s" "$p" > "$PIDFILE"
    return 0
  fi
  return 1
}

# ---- 子命令：up/down/status/split/unsplit/clean ----
do_up(){
  ensure_sudo; get_password
  log "🚀 正在连接 VPN..."
  if run_openconnect >>"$LOGFILE" 2>&1; then
    log "⌛ 等待进程与接口就绪..."
    for _ in 1 2 3 4 5 6; do
      if ensure_pidfile; then break; fi
      sleep 0.5
    done
    if ! ensure_pidfile; then
      log "❌ 连接失败（未找到 openconnect 进程/PIDFILE）。查看日志：$LOGFILE"
      exit 1
    fi
    if is_running; then
      local OUTIP; OUTIP="$(curl -4 -s --max-time 3 https://1.1.1.1/cdn-cgi/trace | awk -F= '/^ip=/{print $2}' || true)"
      [ -z "$OUTIP" ] && OUTIP="$(curl -4 -s --max-time 3 https://api.ipify.org || true)"
      log "✅ VPN 已连接（认证完成），出口 IP：${OUTIP:-未知}"
    else
      log "❌ 连接失败（进程未在运行）。查看日志：$LOGFILE"; exit 1
    fi
  else
    log "❌ openconnect 启动失败。查看日志：$LOGFILE"; exit 1
  fi
}

do_down(){
  if ! is_running; then log "未连接。"; [ -f "$PIDFILE" ] && rm -f "$PIDFILE"; exit 0; fi
  ensure_sudo
  local pid; pid="$(cat "$PIDFILE")"
  log "🔌 正在断开 VPN..."
  sudo kill -INT "$pid" 2>>"$LOGFILE" || true
  for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null && sleep 0.5 || break; done
  kill -0 "$pid" 2>/dev/null && sudo kill -9 "$pid" 2>>"$LOGFILE" || true
  rm -f "$PIDFILE"
  log "✅ 已断开。"
}

do_status(){ is_running && echo "✅ 已连接（PID $(cat "$PIDFILE")）。" || echo "❌ 未连接。"; }

# ---- 分流操作（调用子模块函数） ----
need_split_module(){
  [ -r "$SPLIT_MODULE" ] || { log "❌ 找不到分流模块：$SPLIT_MODULE"; exit 1; }
  # shellcheck source=/dev/null
  . "$SPLIT_MODULE"
}

do_split(){
  need_split_module
  local file="${1:-$DOMAINS_FILE_DEFAULT}"
  split::add "$file"
}

do_unsplit(){
  need_split_module
  split::del
}

do_clean() {
  # 清理所有临时/日志文件
  rm -f \
    "$PIDFILE" \
    "$LOGFILE" \
    "$SPLIT_ROUTES_FILE" \
    "$SPLIT_LOGFILE" 2>/dev/null || true
}

# ---- 参数解析 ----
# case "${1:-}" in
#   up)       shift; do_up ;;
#   down)     shift; do_unsplit; do_down ;;
#   status)   shift; do_status ;;
#   split)    shift; do_up; do_split "${1-}";;
#   unsplit)  shift; do_unsplit ;;
#   *) echo "用法：$0 {up|down|status|split|unsplit} [domains_file_for_split]"; exit 1 ;;
# esac

# ========== 统一参数解析 ==========
SUBCMD=""
WANT_SPLIT="${AUTO_SPLIT:-0}"
DOMAINS_FILE="${DOMAINS_FILE_DEFAULT}"

# 取子命令
if [ $# -gt 0 ]; then
  case "$1" in
    up|down|status|split|unsplit|clean) SUBCMD="$1"; shift ;;
    *) echo "未知子命令：$1"; exit 1 ;;
  esac
else
  cat >&2 <<'USAGE'
用法：
  ecnu-vpn.sh up [--split] [--domains FILE]
  ecnu-vpn.sh down
  ecnu-vpn.sh status
  ecnu-vpn.sh split [--domains FILE]
  ecnu-vpn.sh unsplit
USAGE
  exit 1
fi

# 通用选项（无论 up/down/split 都可出现）
while [ $# -gt 0 ]; do
  case "$1" in
    --split)       WANT_SPLIT=1 ;;
    --no-split)    WANT_SPLIT=0 ;;
    --domains)     shift; DOMAINS_FILE="${1:-$DOMAINS_FILE}" ;;
    --)            shift; break ;;
    *)             break ;;
  esac
  shift || true
done

# ========== 分发 ==========
case "$SUBCMD" in
  up)
    do_up                  # 仅负责连接/认证/日志
    if [ "$WANT_SPLIT" = "1" ]; then
      do_split
    fi
    ;;
  down)
    do_unsplit
    do_down                # 仅负责断开
    ;;
  status)
    do_status
    ;;
  split)
    do_split
    ;;
  unsplit)
    do_unsplit
    ;;
  clean)
    do_clean
    ;;
esac