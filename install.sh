#!/usr/bin/env bash
# dsh one-click deploy — installs dsh web + plugins + model config on a fresh Linux server.
# Upload the whole folder to the server, then run as root:  sudo bash install.sh
# Folder must contain alongside this script: settings.yaml, credentials.yaml
set -euo pipefail

# ===================== config =====================
DSH_VERSION=0.1.1-rc.2      # pin: 0.1.2-rc.1 has a base client locale collision (slash.menu); base resolves from global dsh, profile overrides don't help
NODE_VERSION=v22.23.2       # Node 22 LTS (npmmirror binary — NodeSource apt 404s on JD Cloud)
WEB_PORT=3080               # dsh web loopback; the user-management gateway fronts it on :19843
REGISTRY=https://registry.npmmirror.com
# our plugins (published @weibaohui/*) + dsh-taskboard. NOT dsh-login/dsh-process (unfinished), NOT dsh-gateway (merged into user-management)
PLUGINS="@weibaohui/context-razor@latest @weibaohui/dsh-continue@latest @weibaohui/dsh-file-share@latest @weibaohui/dsh-settings-ui@latest @weibaohui/dsh-smart-title@latest @weibaohui/dsh-sync@latest @weibaohui/dsh-tasks@latest @weibaohui/experts-management@latest @weibaohui/hermes-loop@latest @weibaohui/skills-management@latest @weibaohui/user-management@latest dsh-taskboard@latest"
# ==================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log(){ echo "[dsh-deploy] $*"; }
err(){ echo "[dsh-deploy][ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "run as root: sudo bash install.sh"

# ---- 1. Node 22 (npmmirror binary; NodeSource apt 404s on JD Cloud) ----
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null)" != v22.* ]]; then
  log "installing Node ${NODE_VERSION} from npmmirror binary..."
  curl -fL -o /tmp/node.tar.xz "${REGISTRY}/-/binary/node/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1
  rm -f /tmp/node.tar.xz
fi
log "node $(node -v), npm $(npm -v)"

# ---- 2. npm registry -> npmmirror (domestic; full npmjs mirror) ----
npm config set registry "$REGISTRY"

# ---- 3. pnpm + dsh (pinned) ----
log "installing pnpm@8 + @deepseek-ai/dsh@${DSH_VERSION}..."
npm install -g pnpm@8 "@deepseek-ai/dsh@${DSH_VERSION}"
log "dsh $(dsh --version)"

# ---- 4. model config + keys ----
[[ -f "$HERE/credentials.yaml" ]] || err "credentials.yaml not found — copy the template first:  cp credentials.yaml.example credentials.yaml  then fill in your LLM provider API key"
grep -q '<your-api-key>' "$HERE/credentials.yaml" 2>/dev/null && err "credentials.yaml still has the placeholder — edit it and fill in your real LLM provider API key"
mkdir -p ~/.dsh
cp -f "$HERE/settings.yaml"    ~/.dsh/settings.yaml
cp -f "$HERE/credentials.yaml" ~/.dsh/.credentials.yaml
chmod 600 ~/.dsh/.credentials.yaml
# this box is a fresh node, not a dsh-sync writer — disable all sync to avoid 2-writer conflicts
sed -i 's/autoSync: true/autoSync: false/; s/syncOnStartup: true/syncOnStartup: false/' ~/.dsh/settings.yaml
log "model config + keys in ~/.dsh/ (sync flags disabled)"

# ---- 4b. (optional) public IP / domain → user-management sites ----
# gateway 0.5.4+ MERGES configured hosts with the auto-enumerated local IPs + sslip/nip aliases.
# Without this, a NAT'd public IP (not on a local iface) → 421 on public access.
# Env vars: PUBLIC_IP (NAT public IP), DOMAIN (+ CERT/KEY for a real cert, else self-signed covers it via merge).
if [[ -n "${PUBLIC_IP:-}" || -n "${DOMAIN:-}" ]]; then
  {
    echo "  sites:"
    [[ -n "${PUBLIC_IP:-}" ]] && echo "    - hosts: ['${PUBLIC_IP}']"
    if [[ -n "${DOMAIN:-}" && -n "${CERT:-}" && -n "${KEY:-}" ]]; then
      echo "    - hosts: ['${DOMAIN}']"
      echo "      cert: '${CERT}'"
      echo "      key:  '${KEY}'"
    elif [[ -n "${DOMAIN:-}" ]]; then
      echo "    - hosts: ['${DOMAIN}']"
    fi
  } >> ~/.dsh/settings.yaml
  [[ -n "${PUBLIC_IP:-}" ]] && log "added public IP ${PUBLIC_IP} to sites (gateway 0.5.4+ merges with auto local IPs — public access won't 421)"
  [[ -n "${DOMAIN:-}" && -n "${CERT:-}" && -n "${KEY:-}" ]] && log "added domain ${DOMAIN} (cert/key) as an SNI site"
  [[ -n "${DOMAIN:-}" && ( -z "${CERT:-}" || -z "${KEY:-}" ) ]] && log "added domain ${DOMAIN} to sites (self-signed cert covers it via merge)"
fi

# ---- 5. bootstrap the web profile scaffold (dump-config creates it) ----
dsh --profile web --dump-config >/dev/null
log "web profile scaffold ready"

# ---- 6. install plugins ----
log "installing plugins: ${PLUGINS}"
# shellcheck disable=SC2086  # intentional word-split of the plugin list
dsh plugin --profile web add $PLUGINS -w

# ---- 7. composition check ----
dsh --profile web --dump-config >/dev/null
log "composition OK (dump-config exit 0, no id conflicts)"

# ---- 8. systemd unit ----
cat > /etc/systemd/system/dsh-web.service <<UNIT
[Unit]
Description=DeepSeek Harness web (loopback :${WEB_PORT}; user-management HTTPS gateway :19843)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PATH=/usr/local/bin:/usr/bin:/bin HOME=/root
WorkingDirectory=/root
ExecStart=/usr/local/bin/dsh web --port ${WEB_PORT} --no-open
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable dsh-web
systemctl restart dsh-web
log "dsh-web.service enabled + started (dsh web loopback :${WEB_PORT}; user-management gateway auto-starts on :19843)"

# ---- 9. verify + print access URL ----
log "waiting for boot..."
sleep 15
systemctl is-active --quiet dsh-web || err "dsh-web not active — check: journalctl -u dsh-web -n 40"
curl -fs -o /dev/null "http://127.0.0.1:${WEB_PORT}/" || err "dsh web :${WEB_PORT} not responding (loopback)"
# user-management gateway = the external HTTPS front-door (zero-config: auto-enumerates all local IPs, 100y self-signed cert, first visitor registers as admin)
GW_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"   # primary IPv4 (gateway listens on 0.0.0.0, any reachable IP works)
GW_IP="${GW_IP:-127.0.0.1}"
ACCESS_URL="${PUBLIC_IP:-$GW_IP}"   # print the user's public IP as the access URL if provided (verify still probes the local GW_IP — public IP may be firewall-blocked)
curl -fsk -o /dev/null "https://${GW_IP}:19843/login" || err "gateway :19843 not responding — check: journalctl -u dsh-web | grep user-management"

echo
echo "================ dsh deployed ================"
echo "dsh web   : http://127.0.0.1:${WEB_PORT}   (loopback, ungated upstream)"
echo "gateway   : https://${ACCESS_URL}:19843       (HTTPS, self-signed, first visitor = admin)"
echo "open in browser : https://${ACCESS_URL}:19843  → trust the self-signed cert → register the first admin"
echo "cert download  : https://${ACCESS_URL}:19843/user-management/api/cert  (PEM, public, pre-auth)"
echo "logs           : journalctl -u dsh-web -f"
echo "============================================="
