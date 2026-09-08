#!/data/data/com.termux/files/usr/bin/bash
# dsh-deploy — Termux (Android) installer.
#
# Deploys dsh web harness on Android/Termux. Unlike install.sh (Linux server:
# root + systemd + linux-x64 node), Termux needs native-runtime patches plus
# Termux-specific bootstrap (pkg mirror, nohup instead of systemd, termux-wake-lock).
#
# The 5 native-runtime patches (steps marked [dsh-termux] below) are inlined
# verbatim from lilyco-42/dsh-termux's install.sh so this script is fully
# self-contained and works offline / on a weak network (a runtime `git clone`
# would stall the whole install). Source (no license file shipped there):
#   https://github.com/lilyco-42/dsh-termux  (install.sh)
# dsh-deploy adds the Termux-mirror swap, pnpm, provider config/credentials,
# the 11 plugins, nohup startup, wake-lock and verification around it.
#
# Prereqs: Android 11+ (API 30, koffi statx). Run inside Termux.
# Folder must contain alongside this script: settings.yaml, credentials.yaml.
# Usage:   bash install-termux.sh
#          Optional env: PUBLIC_IP=<NAT public ip>  DOMAIN=<domain>  (-> gateway sites)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_PORT=3080               # dsh web loopback; user-management gateway fronts it on :19843
GW_PORT=19843
NDK_TARGET="aarch64-unknown-linux-android30"
log(){ printf '\033[1;36m[dsh-deploy-termux]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[dsh-deploy-termux][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# wait for any in-flight apt/dpkg to release the dpkg lock (a leftover from a
# previously killed run holds the lock and breaks pkg install)
wait_no_apt(){
  for _ in $(seq 1 20); do
    pgrep -x apt >/dev/null 2>&1 || pgrep -f 'lib/apt/methods' >/dev/null 2>&1 || return 0
    log "another apt/dpkg is running, waiting..."; sleep 3
  done
  err "apt/dpkg lock held >60s — run: pkill -9 apt; pkill -9 -f 'lib/apt/methods'; then retry."
}

# ---- 0. env checks ----
[ -n "${PREFIX:-}" ] || err "not running inside Termux (\$PREFIX unset). Linux servers use install.sh; this is Android/Termux only."
log "Termux detected: PREFIX=$PREFIX"
API="$(getprop ro.build.version.sdk 2>/dev/null || echo 0)"
[ "$API" -ge 30 ] || err "Android API ${API} < 30 (need 11+). koffi's statx needs API 30."
[ -f "$HERE/settings.yaml" ]    || err "settings.yaml not found in $HERE — run from the dsh-deploy/ folder."
[ -f "$HERE/credentials.yaml" ] || err "credentials.yaml not found — copy the template first:  cp credentials.yaml.example credentials.yaml  then fill your provider API key"
grep -q '<your-api-key>' "$HERE/credentials.yaml" 2>/dev/null && err "credentials.yaml still has the placeholder — fill your real LLM provider API key."

# ---- 1. npm registry -> npmmirror (domestic) ----
npm config set registry https://registry.npmmirror.com
log "npm registry -> npmmirror"

# ---- 2. Termux pkg mirror -> Tsinghua (default packages-cf.termux.dev is often unreachable from CN) ----
SRC="$PREFIX/etc/apt/sources.list"
if grep -q 'packages-cf.termux.dev\|packages.termux.dev' "$SRC" 2>/dev/null; then
  sed -i 's@packages-cf.termux.dev/apt/termux-main@mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main@g; s@packages.termux.dev/apt/termux-main@mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main@g' "$SRC"
  log "pkg mirror -> Tsinghua (was default/unreachable)"
fi
wait_no_apt
pkg update -y >/dev/null
log "pkg updated"

# ---- 3. [dsh-termux] install prerequisites ----
wait_no_apt
log "installing prerequisites (nodejs build-essential clang cmake ninja python libvips)..."
pkg install -y nodejs build-essential clang cmake ninja python libvips >/dev/null
# resolve Node/npm paths only now that nodejs is installed
if ! NODE_BIN="$(command -v node)"; then
  err "'node' not found after 'pkg install -y nodejs' — NODE_BIN is empty"
fi
NODE_GYP_BIN="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"
[ -f "$NODE_GYP_BIN" ] || err "node-gyp not found at $NODE_GYP_BIN (did 'pkg install -y nodejs' succeed?)"
log "node $(node -v), npm $(npm -v)"

# ---- 4. [dsh-termux] patch node-gyp (drop bogus OS=android) ----
CREATE_GYPI="$(npm root -g)/npm/node_modules/node-gyp/lib/create-config-gypi.js"
[ -f "$CREATE_GYPI" ] || err "node-gyp create-config-gypi.js not found at $CREATE_GYPI"
if grep -q "delete variables.OS" "$CREATE_GYPI"; then
  log "node-gyp already patched (drop OS=android), skipping."
else
  python3 - "$CREATE_GYPI" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = "const variables = config.variables\n"
assert anchor in src, "patch anchor not found; node-gyp may have changed"
block = (
    anchor + "\n"
    + "  // Termux's Node.js reports process.config.variables.OS as \"android\" even\n"
    + "  // though native addons build against the Termux (linux-like) sysroot, not\n"
    + "  // the Android NDK. gyp's \"OS == android\" branches then reference the\n"
    + "  // undefined android_ndk_path variable and fail. Drop OS so gyp infers it\n"
    + "  // as \"linux\" from the host platform.\n"
    + "  delete variables.OS\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, block, 1))
print("    patched", path)
PY
  log "node-gyp patched (drop OS=android -> infers linux)"
fi

# ---- 5. [dsh-termux] install @deepseek-ai/dsh (native modules compiled, CFLAGS target android30) ----
log "installing @deepseek-ai/dsh (native modules will be compiled)..."
export CFLAGS="--target=$NDK_TARGET"
export CXXFLAGS="--target=$NDK_TARGET"
npm install -g @deepseek-ai/dsh
log "dsh installed"

# ---- 6. [dsh-termux] build sharp against system libvips ----
SHARP_DIR="$DSH_LIB/node_modules/sharp"
if [ -f "$SHARP_DIR/src/build/Release/sharp-android-arm64-"*.node ]; then
  log "sharp already built, skipping."
else
  log "building sharp against system libvips..."
  (cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=1 \
      CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
      "$NODE_BIN" "$NODE_GYP_BIN" rebuild --directory=src >/dev/null)
  log "sharp built"
fi

# ---- 7. [dsh-termux] patch session persistence (hard link -> rename; Android forbids link) ----
SESSION_JS="$DSH_LIB/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
if [ -f "$SESSION_JS" ]; then
  if grep -q "await rename(tmp, finalPath)" "$SESSION_JS"; then
    log "session persistence already patched (link->rename), skipping."
  else
    python3 - "$SESSION_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
)
src = src.replace(
    "\t\t\tawait link(tmp, finalPath);",
    "\t\t\tawait rename(tmp, finalPath);",
)
open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
    log "session persistence patched (link->rename)"
  fi
else
  log "warning: session persistence module not found, skipping."
fi

# ---- 8. [dsh-termux] fix shebang (node --expose-internals; HMR needs it, no android prebuild) ----
DSH_BIN="$DSH_LIB/lib/bin.js"
if [ -f "$DSH_BIN" ]; then
  python3 - "$DSH_BIN" "$NODE_BIN" <<'PY'
import sys
path, node = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
first, _, rest = src.partition("\n")
if not first.startswith("#!"):
    sys.exit("no shebang on first line")
src = "#!" + node + " --expose-internals\n" + rest
open(path, "w", encoding="utf-8").write(src)
print("    shebang set:", node, "--expose-internals")
PY
  log "dsh shebang set (node --expose-internals)"
fi

# ---- 9. verify dsh ----
command -v dsh >/dev/null || err "dsh not on PATH after install — check errors above."
log "dsh $(dsh --version) ready"

# ---- 10. pnpm (dsh plugin add uses it) ----
npm install -g pnpm@8 >/dev/null
log "pnpm $(pnpm -v)"

# ---- 11. provider config + keys ----
mkdir -p ~/.dsh
cp -f "$HERE/settings.yaml"    ~/.dsh/settings.yaml
cp -f "$HERE/credentials.yaml" ~/.dsh/.credentials.yaml
chmod 600 ~/.dsh/.credentials.yaml ~/.dsh/settings.yaml
# fresh node: disable all sync to avoid 2-writer conflicts
sed -i 's/autoSync: true/autoSync: false/; s/syncOnStartup: true/syncOnStartup: false/' ~/.dsh/settings.yaml
# optional public IP / domain -> gateway sites (NAT public IP not on a local iface)
if [ -n "${PUBLIC_IP:-}" ] || [ -n "${DOMAIN:-}" ]; then
  {
    echo "  sites:"
    [ -n "${PUBLIC_IP:-}" ] && echo "    - hosts: ['${PUBLIC_IP}']"
    [ -n "${DOMAIN:-}" ]    && echo "    - hosts: ['${DOMAIN}']"
  } >> ~/.dsh/settings.yaml
  log "added gateway sites (PUBLIC_IP/DOMAIN)"
fi
log "provider config + keys in ~/.dsh/ (sync disabled)"

# ---- 12. web profile scaffold + composition check ----
dsh --profile web --dump-config >/dev/null
log "web profile scaffold ready"

# ---- 13. plugins (published @weibaohui/*) + dsh-taskboard ----
PLUGINS="@weibaohui/context-razor@latest @weibaohui/dsh-continue@latest @weibaohui/dsh-file-share@latest @weibaohui/dsh-settings-ui@latest @weibaohui/dsh-smart-title@latest @weibaohui/dsh-sync@latest @weibaohui/dsh-tasks@latest @weibaohui/experts-management@latest @weibaohui/hermes-loop@latest @weibaohui/skills-management@latest @weibaohui/user-management@latest dsh-taskboard@latest"
log "installing plugins..."
# shellcheck disable=SC2086  # intentional word-split of the plugin list
dsh plugin --profile web add $PLUGINS -w
dsh --profile web --dump-config >/dev/null
log "plugins installed, composition OK"

# ---- 14. start dsh web (nohup; Termux has no systemd) + wake-lock (Android kills background) ----
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock && log "termux-wake-lock acquired"
nohup dsh web --port "$WEB_PORT" --no-open > ~/.dsh/dsh-web.log 2>&1 &
echo $! > ~/.dsh/dsh-web.pid
disown
log "dsh web started (pid $(cat ~/.dsh/dsh-web.pid))"

# ---- 14b. install start.sh to ~/start.sh (one-command startup after each Termux reboot) ----
[ -f "$HERE/start.sh" ] && { cp -f "$HERE/start.sh" ~/start.sh && chmod +x ~/start.sh && log "start.sh -> ~/start.sh (run it after each Termux reboot)"; } || log "start.sh not in $HERE (skip)"

# ---- 15. verify + print access URL ----
log "waiting for boot..."
for _ in $(seq 1 15); do
  curl -fsk -o /dev/null "https://127.0.0.1:${GW_PORT}/login" 2>/dev/null && break
  sleep 2
done
# pick a LAN ip from the gateway's own hosts list in the log (auto-enumerates local IPs)
GW_IP="$(grep -oE 'hosts: [^)]*192\.168\.[0-9.]+' ~/.dsh/dsh-web.log 2>/dev/null | grep -oE '192\.168\.[0-9.]+' | head -1)"
GW_IP="${GW_IP:-127.0.0.1}"
curl -fsk -o /dev/null "https://${GW_IP}:${GW_PORT}/login" || err "gateway :${GW_PORT} not responding — check ~/.dsh/dsh-web.log"

echo
echo "================ dsh deployed (Termux) ================"
echo "dsh web   : http://127.0.0.1:${WEB_PORT}   (loopback, ungated upstream)"
echo "gateway   : https://${GW_IP}:${GW_PORT}       (HTTPS self-signed, first visitor = admin)"
echo "open in browser : https://${GW_IP}:${GW_PORT}  -> trust the self-signed cert -> register the first admin"
echo "logs           : tail -f ~/.dsh/dsh-web.log"
echo "restart after reboot : bash ~/start.sh   (starts sshd + dsh web + wake-lock)"
echo "====================================================="
