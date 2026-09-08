#!/data/data/com.termux/files/usr/bin/bash
# Termux startup script — launches sshd + dsh web so the box is reachable
# right after you open Termux. Idempotent: re-running skips anything already up.
# Usage:  bash ~/start.sh     (or ~/start.sh after chmod +x)
set -uo pipefail
log(){ printf '\033[1;36m[start]\033[0m %s\n' "$*"; }

# ---- 1. sshd (port 8022) — remote ssh access ----
if pgrep -x sshd >/dev/null 2>&1; then
  log "sshd already running (port 8022)"
else
  if command -v sshd >/dev/null 2>&1; then
    log "starting sshd (port 8022)..."
    sshd
    sleep 1
    pgrep -x sshd >/dev/null 2>&1 && log "sshd started (port 8022)" || log "WARN: sshd failed to start (pkg install openssh?)"
  else
    log "WARN: sshd not installed (run: pkg install openssh)"
  fi
fi

# ---- 2. wake-lock — prevent Android from killing background processes ----
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock 2>/dev/null
  log "termux-wake-lock acquired (Android won't kill background)"
else
  log "termux-wake-lock not available — install termux-api for background keep-alive"
fi

# ---- 3. dsh web (loopback :3080; user-management gateway fronts :19843) ----
if pgrep -f 'node --expose-internals' >/dev/null 2>&1; then
  log "dsh web already running"
else
  if command -v dsh >/dev/null 2>&1; then
    log "starting dsh web (port 3080, gateway 19843)..."
    mkdir -p ~/.dsh
    nohup dsh web --port 3080 --no-open > ~/.dsh/dsh-web.log 2>&1 &
    echo $! > ~/.dsh/dsh-web.pid
    disown
    log "waiting for boot..."
    for _ in $(seq 1 15); do
      curl -fsk -o /dev/null "https://127.0.0.1:19843/login" 2>/dev/null && break
      sleep 2
    done
  else
    log "WARN: dsh not installed (run install-termux.sh from dsh-deploy/)"
  fi
fi

# ---- 4. print access info ----
GW_IP="$(grep -oE 'hosts: [^)]*192\.168\.[0-9.]+' ~/.dsh/dsh-web.log 2>/dev/null | grep -oE '192\.168\.[0-9.]+' | head -1)"
GW_IP="${GW_IP:-127.0.0.1}"
echo
echo "================ Termux started ================"
echo "sshd     : port 8022        ssh -p 8022 $(whoami)@${GW_IP}"
echo "dsh web  : http://127.0.0.1:3080   (loopback)"
echo "gateway  : https://${GW_IP}:19843  (self-signed, first visitor = admin)"
echo "open     : https://${GW_IP}:19843"
echo "logs     : tail -f ~/.dsh/dsh-web.log"
echo "stop     : pkill -f 'node --expose-internals'; termux-wake-unlock"
echo "================================================"
