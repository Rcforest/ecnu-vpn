# ecnu-split.sh —— split-tunnel 子模块（供主脚本 source）
# 仅定义函数，不改 shell 选项；不主动退出。
# 导出函数：
#   split::add [domains_file]   # 添加分流路由
#   split::del                  # 删除上次添加的分流路由
#   split::refresh [file]       # 先删后加
# 依赖（可用 env 覆盖）：
#   SPLIT_ROUTES_FILE=./tmp/ecnu-vpn.split-routes
#   SPLIT_LOGFILE=./tmp/ecnu-vpn-routes.log
#   SPLIT_RESOLVERS="1.1.1.1 8.8.8.8"


# 允许主脚本传入 SCRIPT_DIR；否则以自身目录为基准
if [ -z "${SCRIPT_DIR-}" ]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

# 递归加载同目录 .env
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; . "$SCRIPT_DIR/.env"; set +a
fi

# 运行时文件
SPLIT_ROUTES_FILE="${SPLIT_ROUTES_FILE:-./tmp/ecnu-vpn.split-routes}"
SPLIT_LOGFILE="${SPLIT_LOGFILE:-./tmp/ecnu-vpn-routes.log}"
DOMAINS_FILE="${DOMAINS_FILE_DEFAULT:-./academic-domains.txt}"

# 公共 DNS（.env 可覆盖）
SPLIT_RESOLVERS="${SPLIT_RESOLVERS:-1.1.1.1 8.8.8.8}"
split::log(){ echo "[$(date '+%F %T')] $*" | tee -a "$SPLIT_LOGFILE" >&2; }

split::detect_utun(){
  local last=""
  for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun' | sort -V); do last="$i"; done
  [ -n "$last" ] || return 1
  echo "$last"
}

# 解析 IPv4：优先 dig，其次 host，最后 nslookup；固定公共 DNS 且严格超时
split::resolve_v4(){
  local d="$1" r
  if command -v dig >/dev/null 2>&1; then
    for r in $SPLIT_RESOLVERS; do
      dig +time=2 +tries=1 +retry=0 +nodnssec +short A "$d" @"$r" \
        | grep -E '^[0-9.]+$' | sort -u
      return 0
    done
  elif command -v host >/dev/null 2>&1; then
    for r in $SPLIT_RESOLVERS; do
      host -W 2 -t A "$d" "$r" 2>/dev/null | awk '/has address/{print $NF}' \
        | grep -E '^[0-9.]+$' | sort -u
      return 0
    done
  else
    for r in $SPLIT_RESOLVERS; do
      /usr/bin/perl -e 'alarm 2; exec @ARGV' nslookup -query=A "$d" "$r" 2>/dev/null \
        | awk '/^Address: /{print $2}' | grep -E '^[0-9.]+$' | sort -u
      return 0
    done
  fi
}

split::add(){
  : >"$SPLIT_ROUTES_FILE"
  local utun; utun="$(split::detect_utun)" || { split::log "⚠️ 未找到 utun 接口，跳过分流"; return 0; }

  if [ ! -f "$DOMAINS_FILE" ]; then
    split::log "⚠️ 域名清单不存在：$DOMAINS_FILE（跳过分流）"; return 0
  fi

  split::log "🔀 分流：通过 ${utun} 转发清单域名"
  while IFS= read -r d; do
    d="${d%%#*}"; d="${d//[[:space:]]/}"
    [ -z "$d" ] && continue
    split::log "  ▶ 解析并添加：$d"
    local ips; ips="$(split::resolve_v4 "$d")" || ips=""
    if [ -z "$ips" ]; then split::log "  • $d 解析为空或超时，跳过"; continue; fi
    while read -r ip; do
      [ -z "$ip" ] && continue
      if sudo route -n add -host "$ip" -interface "$utun" 2>/dev/null; then
        printf "%s %s %s\n" "$ip" if "$utun" >>"$SPLIT_ROUTES_FILE"
        split::log "    + $d → $ip via -interface $utun"
      else
        if netstat -rn | awk '{print $1,$4}' | grep -qE "^$ip[[:space:]]$utun$"; then
          printf "%s %s %s\n" "$ip" if "$utun" >>"$SPLIT_ROUTES_FILE"
          split::log "    ≈ $d → $ip 路由已存在"
        else
          split::log "    ❌ $d → $ip 添加失败"
        fi
      fi
    done <<<"$ips"
    split::log "  ✔ 完成：$d"
  done < "$DOMAINS_FILE"
}

split::del(){
  [ -f "$SPLIT_ROUTES_FILE" ] || { split::log "（无分流记录可清理）"; return 0; }
  while read -r ip mode arg; do
    [ -z "$ip" ] && continue
    if [ "$mode" = "if" ]; then
      sudo route -n delete -host "$ip" -interface "$arg" 2>/dev/null || true
    else
      sudo route -n delete -host "$ip" 2>/dev/null || true
    fi
  done < "$SPLIT_ROUTES_FILE"
  rm -f "$SPLIT_ROUTES_FILE"
  split::log "🧹 已清理分流路由"
}

split::refresh(){ split::del; split::add "${1-}"; }

# 允许独立调试：直接运行本文件时提供简单 CLI
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  case "${1:-}" in
    add)      split::add "${2-}";;
    del)      split::del;;
    refresh)  split::refresh "${2-}";;
    *) echo "用法：$0 {add|del|refresh} [domains_file]"; exit 1;;
  esac
fi