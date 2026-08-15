#!/bin/bash
# 动态生成的 split-tunnel wrapper
set -u

DOMAINS_FILE="/Users/river/Projects/ecnu-vpn/./domains.txt"
REAL_VPNC_SCRIPT="/opt/homebrew/etc/vpnc/vpnc-script"

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
