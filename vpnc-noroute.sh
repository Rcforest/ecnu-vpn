#!/bin/sh
# Minimal vpnc-script for macOS: configure utun IP/MTU only,
# do NOT touch default route or DNS.

IFCFG=/sbin/ifconfig
ROUTE=/sbin/route

# 从 openconnect 传入的环境变量里获取
# 常见：TUNDEV, INTERNAL_IP4_ADDRESS, INTERNAL_IP4_MTU
TUN="${TUNDEV:-}"
IP4="${INTERNAL_IP4_ADDRESS:-}"
MTU="${INTERNAL_IP4_MTU:-1400}"

case "$reason" in
  connect)
    if [ -n "$TUN" ] && [ -n "$IP4" ]; then
      # macOS 下 utun 用点对点写法：本地/对端都填自身 IP
      $IFCFG "$TUN" inet "$IP4" "$IP4" mtu "$MTU" up 2>/dev/null || exit 1
    fi
    ;;

  disconnect)
    # 不做任何更改；由主脚本收尾
    ;;

  *)
    # 其它阶段全部忽略
    ;;
esac

exit 0