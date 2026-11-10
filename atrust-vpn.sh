#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
log() { printf '%s\n' "$*" >&2; }
# Bash's /dev/tcp avoids depending on a particular netcat flavour.
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# .env supplies the account, the Keychain service name and an optional
# VPN_PASS fallback. Python prefers the Keychain and uses VPN_PASS only when
# the Keychain lookup fails.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  . "$SCRIPT_DIR/.env"
fi
export VPN_USER="${VPN_USER:-}" KEYCHAIN_LABEL="${KEYCHAIN_LABEL:-ECNU_VPN}"

command -v docker >/dev/null || { log "未找到 Docker，请先安装并启动 Docker（macOS 可用 OrbStack / Docker Desktop）。"; exit 2; }
command -v python3 >/dev/null || { log "未找到 Python 3，请先安装 Python 3.9 或更新版本。"; exit 2; }
cd "$SCRIPT_DIR"

case "${1:-up}" in
  up|login)
    action="${1:-up}"
    shift || true
    [[ $# -eq 0 || ( $# -eq 1 && "$1" == "--http-only" ) ]] || {
      log "用法：$0 {up|login} [--http-only]"; exit 2;
    }
    # Compose start reuses the existing container, network and persisted data.
    docker compose start atrust
    ready=0
    for (( attempt=0; attempt<30; attempt++ )); do
      if port_open 54631; then
        ready=1
        break
      fi
      sleep 1
    done
    [[ "$ready" == 1 ]] || { log "aTrust 的 54631 端口未就绪，请检查容器。"; exit 2; }
    mkdir -p "$SCRIPT_DIR/tmp"
    lock_dir="$SCRIPT_DIR/tmp/atrust-login.lock"
    mkdir "$lock_dir" 2>/dev/null || {
      log "已有登录操作正在进行；若上次异常退出，请删除 tmp/atrust-login.lock。"; exit 2;
    }
    trap 'rmdir "$lock_dir"' EXIT
    # Pass VPN_PASS through the environment only (never argv), and only here.
    VPN_PASS="${VPN_PASS:-}" python3 "$SCRIPT_DIR/atrust-login.py" "$action" "$@"
    ;;
  down)
    # Release the server-side session before stopping the client. A failed
    # logout must not prevent an explicitly requested container stop.
    if port_open 54631; then
      python3 "$SCRIPT_DIR/atrust-login.py" logout || log "客户端注销未完成，继续停止容器。"
    fi
    docker compose stop atrust
    log "○ OFF  ECNU aTrust 容器已停止"
    ;;
  status)
    exec python3 "$SCRIPT_DIR/atrust-login.py" status
    ;;
  *)
    log "用法：$0 {up|login|down|status} [--http-only]"
    exit 2
    ;;
esac
