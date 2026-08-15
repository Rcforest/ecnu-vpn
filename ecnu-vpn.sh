#!/usr/bin/env bash
set -euo pipefail

############################################################
# ECNU VPN one-touch (macOS)
# - 默认：全局模式（标准 vpnc-script 改默认路由/DNS）
# - 分流：--split 使用 vpn-slice，仅清单域名走 VPN
# - 密码来源：VPN_PASS_FILE > VPN_PASS > Keychain
# - PID/日志：可通过 .env 配置；相对路径会按脚本目录绝对化
############################################################

########## 目录/路径 ##########
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 尝试加载 .env（可选）
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"

# 默认配置（可被 .env 覆盖）
VPN_HOST="${VPN_HOST:-vpn-ct.ecnu.edu.cn}"
VPN_USER="${VPN_USER:-}"                              # ← 必填（学号/工号）
KEYCHAIN_LABEL="${KEYCHAIN_LABEL:-ECNU_VPN}"
USERAGENT="${USERAGENT:-AnyConnect Windows 4.10.06079}"
AUTHGROUP="${AUTHGROUP-}"                             # 可选
SECOND_FACTOR="${SECOND_FACTOR-}"                     # 可选（push 或 6位码）
SERVERCERT_PIN="${SERVERCERT_PIN-}"                   # 可选 pin-sha256:BASE64

TMPDIR="${TMPDIR:-$SCRIPT_DIR/tmp}"
LOGFILE="${LOGFILE:-$TMPDIR/ecnu-vpn.log}"
PIDFILE="${PIDFILE:-$TMPDIR/openconnect-ecnu.pid}"
DOMAINS_FILE="${DOMAINS_FILE:-$SCRIPT_DIR/domains.txt}"

# 默认行为：不开 split => 全局模式
WANT_SPLIT="${AUTO_SPLIT:-0}"

# 路径绝对化（相对脚本目录）
make_abs() { local v; v="${!1-}"; [ -z "$v" ] && return 0; case "$v" in /*) ;; *) printf -v "$1" "%s/%s" "$SCRIPT_DIR" "$v" ;; esac; }
make_abs TMPDIR
make_abs LOGFILE
make_abs PIDFILE
make_abs DOMAINS_FILE

mkdir -p "$TMPDIR"

# PATH（优先 Homebrew）
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

########## 可执行体 ##########
OPENCONNECT_BIN="$(command -v openconnect || true)"
: "${OPENCONNECT_BIN:?未找到 openconnect，请先 brew install openconnect}"
export OPENCONNECT_BIN

# 标准 vpnc-script（全局模式用）
VPN_SCRIPT_GLOBAL="${VPN_SCRIPT_GLOBAL-}"
if [ -z "${VPN_SCRIPT_GLOBAL-}" ]; then
  for p in /opt/homebrew/etc/vpnc/vpnc-script /usr/local/etc/vpnc/vpnc-script /etc/vpnc/vpnc-script; do
    [ -x "$p" ] && VPN_SCRIPT_GLOBAL="$p" && break
  done
fi
: "${VPN_SCRIPT_GLOBAL:?未找到标准 vpnc-script；请先 brew install openconnect}"

########## 工具函数 ##########
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE" >&2; }
is_running(){ [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
ensure_sudo(){ [ "$(id -u)" -eq 0 ] || sudo -v; }

# 解析参数
SUBCMD="${1:-}"
shift || true
while (( "$#" )); do
  case "$1" in
    --split)    WANT_SPLIT=1 ;;
    --no-split) WANT_SPLIT=0 ;;
    *)          # 允许透传未知参数（若未来扩展）
                ;;
  esac
  shift || true
done

# Keychain / 环境 读取密码（带清理 & 2FA 拼接）
get_password() {
  : "${VPN_USER:?VPN_USER must not be empty}"
  # : "${VPN_PASS_FILE:-./secret.txt}"
  local pass
  if [ -n "${VPN_PASS_FILE-}" ]; then
    [ -r "$VPN_PASS_FILE" ] || { log "❌ VPN_PASS_FILE 不可读：$VPN_PASS_FILE"; exit 1; }
    pass="$(/bin/cat -- "$VPN_PASS_FILE")"
    log "🔑 已从文件读取密码（$VPN_PASS_FILE）"
  elif [ -n "${VPN_PASS-}" ]; then
    pass="$VPN_PASS"
    log "🔑 已从环境变量读取密码"
  else
    log "🔑 正在从钥匙串读取密码（account=$VPN_USER service=${KEYCHAIN_LABEL}）"
    # Shortcut 环境下 $HOME 可能为空，需要从系统获取或猜测
    local home_dir="${HOME:-}"
    if [ -z "$home_dir" ]; then
        # 尝试通过 id -P 获取 (macOS specific)
        home_dir="$(id -P "$(id -u)" 2>/dev/null | cut -d: -f9)" || true
    fi
    [ -z "$home_dir" ] && home_dir="/Users/$(id -un)"

    # 尝试显式指定 login keychain
    local kc_path="${home_dir}/Library/Keychains/login.keychain-db"
    [ -f "$kc_path" ] || kc_path="${home_dir}/Library/Keychains/login.keychain"

    # DEBUG: 输出调试信息到日志
    log "🔍 Debug: User=$(id -un), UID=$(id -u), HOME=$home_dir SUDO_USER=${SUDO_USER-}"

    local sec_out
    # 尝试 1: 直接读取 (当前用户)
    if sec_out="$(
      /usr/bin/perl -e 'alarm 3; exec @ARGV' \
        /usr/bin/security find-generic-password \
        -a "$VPN_USER" -s "$KEYCHAIN_LABEL" -w "$kc_path" 2>&1
    )"; then
      pass="$sec_out"
    elif [ "$(id -u)" -eq 0 ]; then
      # 尝试 2: 如果是 Root，尝试切换回真实用户读取
      # Shortcuts sudo 环境下 SUDO_USER 可能丢失，尝试作为脚本拥有者兜底
      local real_user="${SUDO_USER-}"
      local real_uid=""
      if [ -z "$real_user" ]; then
         real_user="$(stat -f '%Su' "$SCRIPT_DIR")"
         real_uid="$(stat -f '%u' "$SCRIPT_DIR")"
         log "⚠️ SUDO_USER 为空，推断真实用户为脚本拥有者: $real_user ($real_uid)"
      else
         real_uid="$(id -u "$real_user")"
      fi
      
      local user_home_kc=""
      if [ -d "/Users/$real_user" ]; then
         user_home_kc="/Users/$real_user/Library/Keychains/login.keychain-db"
         [ -f "$user_home_kc" ] || user_home_kc="/Users/$real_user/Library/Keychains/login.keychain"
      fi
      
      log "🔍 Debug (Root): Switching to user=$real_user (UID=$real_uid) via launchctl, TargetKC=$user_home_kc"

      local sec_err
      # 关键修正：使用 launchctl asuser 在用户 session 上下文中执行，
      # 这比单纯 sudo -u 更能获得正确的 Keychain 访问权限。
      if sec_out="$(
        launchctl asuser "$real_uid"  \
        /usr/bin/security find-generic-password \
          -a "$VPN_USER" -s "$KEYCHAIN_LABEL" -w ${user_home_kc:+"$user_home_kc"} 2>&1
      )"; then
         pass="$sec_out"
      else
         sec_err="$sec_out"
         log "❌ 无法从钥匙串读取密码（account=$VPN_USER service=${KEYCHAIN_LABEL}）"
         log "   Root尝试失败。错误详情：$sec_err"
         exit 1
      fi
    else
      log "❌ 无法从钥匙串读取密码（account=$VPN_USER service=${KEYCHAIN_LABEL}）"
      log "  错误详情：$sec_out"
      echo "   解决A：security add-generic-password -a \"$VPN_USER\" -s \"$KEYCHAIN_LABEL\" -w" >&2
      echo "   解决B：在 .env 中设置 VPN_PASS 或 VPN_PASS_FILE" >&2
      exit 1
    fi
  fi
  # 清理不可见字符/尾部空白
  pass="${pass%$'\n'}"; pass="${pass%$'\r'}"; pass="$(printf '%s' "$pass" | sed -e 's/[[:space:]]\+$//')"
  # 二次认证拼接
  if [ -n "${SECOND_FACTOR-}" ]; then
    pass="${pass},${SECOND_FACTOR}"
    log "🔒 已启用二次认证（SECOND_FACTOR）"
  fi
  printf '%s' "$pass"
}

# 保存/恢复默认路由（下线兜底；分流路径一般不需要改 default）
save_default_route(){
  local info; if info="$(route -n get default 2>/dev/null)"; then
    ORIG_GW="$(printf '%s\n' "$info" | awk '/gateway:/{print $2; exit}')"
    ORIG_IF="$(printf '%s\n' "$info" | awk '/interface:/{print $2; exit}')"
    printf "%s %s\n" "${ORIG_GW-}" "${ORIG_IF-}" > "$TMPDIR/.orig-gw"
  fi
}
restore_default_route(){
  if [ -s "$TMPDIR/.orig-gw" ]; then
    read -r ORIG_GW ORIG_IF < "$TMPDIR/.orig-gw" || true
    if [ -n "${ORIG_GW-}" ]; then
      ensure_sudo
      sudo route -n delete default >/dev/null 2>&1 || true
      sudo route -n add default "$ORIG_GW" >/dev/null 2>&1 || true
      log "↩️ 已恢复默认路由：$ORIG_GW ($ORIG_IF)"
    fi
    rm -f "$TMPDIR/.orig-gw"
  fi
}

# 生成 split-dns 的 wrapper（解析 domains.txt -> 环境变量 -> 调用 standard vpnc-script）
make_split_dns_wrapper(){
  local wrapper="$TMPDIR/vpn-split-wrapper.sh"
  
  cat > "$wrapper" <<'EOF'
#!/bin/bash
# 动态生成的 split-tunnel wrapper
set -u

DOMAINS_FILE="__DOMAINS_FILE__"
REAL_VPNC_SCRIPT="__REAL_VPNC_SCRIPT__"

# 1. 解析 domains.txt -> IP 列表
#    优化：
#    - 自动追加 www. 前缀（如果你写了 example.com，会自动多解一个 www.example.com）
#    - 多次 dig (3次) 以尝试捕获更多 CDN 轮询 IP
RESOLVED_IPS=()

resolve_domain() {
  local d="$1"
  # dig 3次，去重，合并输出
  local res
  res="$(for _ in 1 2 3; do dig +short +time=1 +tries=1 A "$d"; done | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  echo "$res"
}

if [ -f "$DOMAINS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    # 去除首尾空白
    domain="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$domain" ] && continue
    case "$domain" in \#*) continue ;; esac
    
    # 原始域名解析
    ips="$(resolve_domain "$domain")"
    if [ -n "$ips" ]; then
      while IFS= read -r ip; do RESOLVED_IPS+=("$ip"); done <<< "$ips"
    fi

    # 尝试自动加 www. (如果原本没有 www.)
    if [[ "$domain" != "www."* ]]; then
       ips_www="$(resolve_domain "www.$domain")"
       if [ -n "$ips_www" ]; then
         while IFS= read -r ip; do RESOLVED_IPS+=("$ip"); done <<< "$ips_www"
       fi
    fi

  done < "$DOMAINS_FILE"
fi

# 去重
SORTED_IPS=($(printf "%s\n" "${RESOLVED_IPS[@]}" | sort -u))

echo "==> [Split Tunneling] Resolved ${#SORTED_IPS[@]} IPs from $DOMAINS_FILE (incl. www & retries)" >&2

# 2. 设置 CISCO_SPLIT_INC_* 环境变量
#    这是 vpnc-script 识别分流列表的标准变量
#    格式：
#      CISCO_SPLIT_INC=N
#      CISCO_SPLIT_INC_0_ADDR=...
#      CISCO_SPLIT_INC_0_MASK=...
#      CISCO_SPLIT_INC_0_MASKLEN=32

count=0
for ip in "${SORTED_IPS[@]}"; do
  export CISCO_SPLIT_INC_${count}_ADDR="$ip"
  export CISCO_SPLIT_INC_${count}_MASK="255.255.255.255"
  export CISCO_SPLIT_INC_${count}_MASKLEN="32"
  count=$((count + 1))
done
export CISCO_SPLIT_INC="$count"

# 4. 关键修正：防止 vpnc-script 修改系统 DNS
#    在分流模式下，如果服务端推送了内网 DNS (如 10.x.x.x)，但该 IP 不在路由表中，
#    会导致系统 DNS 变为不可达，从而"断网"。
#    我们只想要路由分流，不需要 DNS 变更（使用本地公网 DNS 解析公网学术 IP 即可）。
unset INTERNAL_IP4_DNS
unset INTERNAL_IP6_DNS
unset CISCO_DEF_DOMAIN
unset CISCO_SPLIT_DNS

# 5. 调用真正的 vpnc-script
exec "$REAL_VPNC_SCRIPT"
EOF

  /usr/bin/sed -i '' "s#__DOMAINS_FILE__#${DOMAINS_FILE}#g" "$wrapper"
  /usr/bin/sed -i '' "s#__REAL_VPNC_SCRIPT__#${VPN_SCRIPT_GLOBAL}#g" "$wrapper"
  chmod +x "$wrapper"
  VPN_SCRIPT="$wrapper"
}


# 启动 openconnect（密码走 stdin；记录 PIDFILE；追加日志）
run_openconnect(){
  local pass args=()
  pass="$(get_password)"

  args+=("https://${VPN_HOST}")
  args+=(--protocol=anyconnect)
  args+=(--user="$VPN_USER")
  args+=(--useragent="$USERAGENT")
  args+=(--passwd-on-stdin)
  args+=(--script="$VPN_SCRIPT")
  args+=(--background --pid-file="$PIDFILE" --timestamp --verbose)

  [ -n "${AUTHGROUP-}" ]     && args+=(--authgroup "$AUTHGROUP")
  [ -n "${SERVERCERT_PIN-}" ]&& args+=(--servercert "pin-sha256:${SERVERCERT_PIN}")
  [ -n "${OPENCONNECT_DEBUG-}" ] && args+=(-vvv)

  log "OC cmd: $OPENCONNECT_BIN --protocol=anyconnect --user=$VPN_USER --script=\"$VPN_SCRIPT\" --background --pid-file=\"$PIDFILE\" https://$VPN_HOST"
  ensure_sudo
  # 把 stdin 明确传给 openconnect
  if ! printf "%s" "$pass" | sudo -E bash -c 'exec "$OPENCONNECT_BIN" "$@" <&0' _ "${args[@]}" >>"$LOGFILE" 2>&1; then
    log "❌ openconnect 启动失败。查看日志：$LOGFILE"
    exit 1
  fi
}

# 确保 PID 文件可用（必要时兜底用 pgrep）
ensure_pidfile(){
  if [ -f "$PIDFILE" ]; then
    local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
  fi
  local p; p="$(pgrep -n -f "openconnect.*${VPN_HOST}" || true)"
  [ -n "$p" ] && { printf "%s" "$p" > "$PIDFILE"; return 0; }
  return 1
}

########## 上下线/状态 ##########
do_up(){
  [ -n "$VPN_USER" ] || { log "❌ 未设置 VPN_USER（请在 .env 中配置）"; exit 1; }

  save_default_route
  log "🚀 正在连接 VPN..."
  run_openconnect
  # 等待后台进程就绪
  for _ in 1 2 3 4 5 6; do
    if ensure_pidfile; then break; fi
    sleep 0.5
  done
  if ! ensure_pidfile; then
    log "❌ 连接失败（未找到 openconnect 进程/PIDFILE）。查看日志：$LOGFILE"
    exit 1
  fi
  # 出口 IP（仅指当前默认路由下的对外 IP）
  local outip; outip="$(curl -4 -s --max-time 3 https://api.ipify.org || true)"
  log "✅ VPN 已连接（认证完成），出口 IP：${outip:-未知}"
}

do_down(){
  if ! is_running; then
    log "未连接。"
    [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    restore_default_route
    exit 0
  fi
  local pid; pid="$(cat "$PIDFILE")"
  log "🔌 正在断开 VPN..."
  ensure_sudo
  sudo kill -INT "$pid" 2>>"$LOGFILE" || true
  for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null && sleep 0.5 || break; done
  kill -0 "$pid" 2>/dev/null && sudo kill -9 "$pid" 2>>"$LOGFILE" || true
  rm -f "$PIDFILE"
  restore_default_route
  # 可选：清理日志（开启请在 .env 里设 CLEAN_ON_DOWN=1）
  [ "${CLEAN_ON_DOWN:-0}" = "1" ] && rm -f "$LOGFILE"
  log "✅ 已断开。"
}

do_status(){
  if is_running; then
    echo "✅ 已连接（PID $(cat "$PIDFILE")）。"
  else
    echo "❌ 未连接。"
  fi
}

########## 主流程：按是否 --split 切换脚本 ##########
case "${SUBCMD:-}" in
  up)
    if [ "$WANT_SPLIT" = "1" ]; then
      # —— 分流模式：Custom Split DNS —— #
      make_split_dns_wrapper
      # VPN_SCRIPT 已在 make_split_dns_wrapper 中被指向新 wrapper
      do_up
      log "🧭 当前模式：分流（$DOMAINS_FILE 走 VPN，其它直连）"
    else
      # —— 全局模式：标准 vpnc-script —— #
      VPN_SCRIPT="$VPN_SCRIPT_GLOBAL"
      do_up
      log "🌐 当前模式：全局（默认路由/DNS 走 VPN）"
    fi
    ;;

  down)
    do_down
    ;;

  status)
    do_status
    ;;

  *)
    echo "用法：$0 {up|down|status} [--split|--no-split]"
    echo "  up            全局模式连接"
    echo "  up --split    分流模式（仅 domains.txt 走 VPN）"
    echo "  down          断开并恢复默认路由"
    echo "  status        查看当前连接状态"
    exit 1
    ;;
esac