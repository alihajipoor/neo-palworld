#!/usr/bin/env bash
# All-in-one Ubuntu manager for a Palworld 1.0 dedicated server.
#
# Typical use:
#   sudo bash palworld-manager.sh
#
# The script opens an interactive menu by default. Command-style actions still
# exist underneath for cron, systemd timers, or automation, but normal use is
# through the menu.
#
# Security:
#   Forward UDP 8211 to this server for public play.
#   Do not expose REST API or RCON to the public Internet.

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
APP_ID="2394010"
SERVICE_NAME="palworld"
TIMER_NAME="palworld-backup"
ANNOUNCE_TIMER_NAME="palworld-announce"
WEB_PANEL_SERVICE_NAME="palworld-web"
INSTALL_DIR="/opt/palworld"
BACKUP_DIR="/var/backups/palworld"
SERVER_USER="steam"
SERVER_GROUP="steam"
WEB_PANEL_USER="palweb"
GAME_PORT="8211"
MAX_PLAYERS="32"
REST_PORT="8212"
RCON_PORT="25575"
WEB_PANEL_HOST="0.0.0.0"
WEB_PANEL_PORT="8080"
WEB_PANEL_PUBLIC_URL=""
WEB_PANEL_DOMAIN=""
WEB_PANEL_TLS_EMAIL=""
GAME_CONNECT_HOST=""
WEB_ADMIN_USER="admin"
WEB_ADMIN_PASSWORD=""
DISCORD_GUILD_ID=""
DISCORD_INVITE_URL=""
MICROSOFT_CLIENT_ID=""
MICROSOFT_CLIENT_SECRET=""
MICROSOFT_TENANT="consumers"
PUBLIC_LOBBY="false"
PUBLIC_IP=""
PUBLIC_PORT=""
SERVER_NAME=""
SERVER_DESCRIPTION=""
SERVER_PASSWORD=""
ADMIN_PASSWORD=""
ENABLE_RCON="false"
LOG_FORMAT="Json"
USE_PERF_ARGS="false"
WORKER_THREADS=""
BACKUP_KEEP="30"
BACKUP_EVERY_MINUTES="60"
SHUTDOWN_WAIT="30"
MESSAGE="Server maintenance"
ANNOUNCE_EVERY_MINUTES="30"
ANNOUNCE_MESSAGE="Welcome to Neo Palworld. Be respectful, raid fair, and have fun."
ROOTLESS="false"
FORCE="false"
NO_BACKUP="false"
API_HOST="127.0.0.1"
API_USER="admin"
STEAM_FORCE_IPV4="auto"
ACTION="menu"

if [[ $# -gt 0 && "$1" != -* ]]; then
  ACTION="$1"
  shift
fi

log() { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
palworld-manager.sh - Ubuntu Palworld dedicated server manager

Interactive menu:
  sudo bash palworld-manager.sh

First-time setup:
  sudo bash palworld-manager.sh install --server-name "Neo Palworld" --public-lobby
  sudo bash palworld-manager.sh firewall
  sudo bash palworld-manager.sh start

Daily use:
  sudo bash palworld-manager.sh status
  sudo bash palworld-manager.sh backup
  sudo bash palworld-manager.sh update
  sudo bash palworld-manager.sh restart
  sudo bash palworld-manager.sh logs

Settings:
  sudo bash palworld-manager.sh settings
  sudo bash palworld-manager.sh set ServerName="Neo Palworld" ExpRate=1.5 PalCaptureRate=1.2
  sudo bash palworld-manager.sh preset casual

Backups:
  sudo bash palworld-manager.sh backup
  sudo bash palworld-manager.sh list-backups
  sudo bash palworld-manager.sh restore /var/backups/palworld/palworld-save-YYYYmmdd-HHMMSS.tar.gz
  sudo bash palworld-manager.sh schedule-backup --backup-every-minutes 60

REST API helpers:
  sudo bash palworld-manager.sh info
  sudo bash palworld-manager.sh players
  sudo bash palworld-manager.sh metrics
  sudo bash palworld-manager.sh announce --message "Restart in 5 minutes"
  sudo bash palworld-manager.sh shutdown --shutdown-wait 60 --message "Restarting"

Mods:
  sudo bash palworld-manager.sh mods PackageOne PackageTwo
  sudo bash palworld-manager.sh mods --workshop-root-dir /home/steam/.steam/steam/steamapps/workshop/content/1623730 PackageOne
  sudo bash palworld-manager.sh mods --disable-mods

Important options:
  --install-dir PATH          Default: /opt/palworld
  --backup-dir PATH           Default: /var/backups/palworld
  --user NAME                 Default: steam
  --port N                    Default: 8211 UDP
  --players N                 Default: 32
  --rest-port N               Default: 8212 TCP local/LAN only
  --public-lobby              Add -publiclobby launch option
  --public-ip IP              Explicit public IP for community listing
  --public-port N             Explicit public port for community listing
  --admin-password VALUE      Required for REST API; generated if omitted during install
  --server-password VALUE     Optional join password
  --use-perf-args             Adds older multithread launch args; for v1.0 default is off
  --worker-threads N          Adds -NumberOfWorkerThreadsServer=N with perf args
  --force                     Force stop/restore when needed
  --rootless                  Do not create system user/systemd service; run from current user

Router:
  Forward UDP 8211 to this server. Do not forward REST/RCON ports publicly.
EOF
}

pause_menu() {
  printf '\nPress Enter to continue... '
  read -r _ || true
}

prompt_text() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  read -r value || true
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

prompt_yes_no() {
  local label="$1"
  local default="${2:-y}"
  local answer suffix
  if [[ "$default" == "y" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi
  printf '%s [%s]: ' "$label" "$suffix" >&2
  read -r answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy] ]]
}

clear_screen() {
  if command -v clear >/dev/null 2>&1; then
    clear
  fi
}

require_root() {
  if [[ "$ROOTLESS" == "true" ]]; then
    return
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Run this action with sudo, or pass --rootless for a current-user/manual setup."
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) INSTALL_DIR="$2"; shift 2 ;;
      --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
      --user) SERVER_USER="$2"; SERVER_GROUP="$2"; shift 2 ;;
      --group) SERVER_GROUP="$2"; shift 2 ;;
      --port) GAME_PORT="$2"; shift 2 ;;
      --players) MAX_PLAYERS="$2"; shift 2 ;;
      --rest-port) REST_PORT="$2"; shift 2 ;;
      --rcon-port) RCON_PORT="$2"; shift 2 ;;
      --public-lobby) PUBLIC_LOBBY="true"; shift ;;
      --public-ip) PUBLIC_IP="$2"; shift 2 ;;
      --public-port) PUBLIC_PORT="$2"; shift 2 ;;
      --server-name) SERVER_NAME="$2"; shift 2 ;;
      --server-description) SERVER_DESCRIPTION="$2"; shift 2 ;;
      --server-password) SERVER_PASSWORD="$2"; shift 2 ;;
      --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
      --enable-rcon) ENABLE_RCON="true"; shift ;;
      --log-format) LOG_FORMAT="$2"; shift 2 ;;
      --use-perf-args) USE_PERF_ARGS="true"; shift ;;
      --worker-threads) WORKER_THREADS="$2"; shift 2 ;;
      --keep) BACKUP_KEEP="$2"; shift 2 ;;
      --backup-every-minutes) BACKUP_EVERY_MINUTES="$2"; shift 2 ;;
      --shutdown-wait) SHUTDOWN_WAIT="$2"; shift 2 ;;
      --message) MESSAGE="$2"; shift 2 ;;
      --announce-message) ANNOUNCE_MESSAGE="$2"; shift 2 ;;
      --announce-every-minutes) ANNOUNCE_EVERY_MINUTES="$2"; shift 2 ;;
      --web-panel-host) WEB_PANEL_HOST="$2"; shift 2 ;;
      --web-panel-port) WEB_PANEL_PORT="$2"; shift 2 ;;
      --web-panel-public-url) WEB_PANEL_PUBLIC_URL="$2"; shift 2 ;;
      --web-panel-domain) WEB_PANEL_DOMAIN="$2"; shift 2 ;;
      --web-panel-tls-email) WEB_PANEL_TLS_EMAIL="$2"; shift 2 ;;
      --game-connect-host) GAME_CONNECT_HOST="$2"; shift 2 ;;
      --web-admin-user) WEB_ADMIN_USER="$2"; shift 2 ;;
      --web-admin-password) WEB_ADMIN_PASSWORD="$2"; shift 2 ;;
      --discord-guild-id) DISCORD_GUILD_ID="$2"; shift 2 ;;
      --discord-invite-url) DISCORD_INVITE_URL="$2"; shift 2 ;;
      --microsoft-client-id) MICROSOFT_CLIENT_ID="$2"; shift 2 ;;
      --microsoft-client-secret) MICROSOFT_CLIENT_SECRET="$2"; shift 2 ;;
      --microsoft-tenant) MICROSOFT_TENANT="$2"; shift 2 ;;
      --api-host) API_HOST="$2"; shift 2 ;;
      --api-user) API_USER="$2"; shift 2 ;;
      --steam-force-ipv4) STEAM_FORCE_IPV4="true"; shift ;;
      --no-steam-force-ipv4) STEAM_FORCE_IPV4="false"; shift ;;
      --workshop-root-dir) POSITIONAL+=("--workshop-root-dir" "$2"); shift 2 ;;
      --disable-mods) POSITIONAL+=("--disable-mods"); shift ;;
      --force) FORCE="true"; shift ;;
      --no-backup) NO_BACKUP="true"; shift ;;
      --rootless) ROOTLESS="true"; shift ;;
      --help|-h) usage; exit 0 ;;
      --) shift; POSITIONAL+=("$@"); break ;;
      -*) fail "Unknown option: $1" ;;
      *) POSITIONAL+=("$1"); shift ;;
    esac
  done
}

POSITIONAL=()
parse_args "$@"

server_dir() { printf '%s/server' "$INSTALL_DIR"; }
steamcmd_dir() { printf '%s/steamcmd' "$INSTALL_DIR"; }
state_file() { printf '%s/manager.env' "$INSTALL_DIR"; }
settings_file() { printf '%s/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini' "$(server_dir)"; }
default_settings_file() { printf '%s/DefaultPalWorldSettings.ini' "$(server_dir)"; }
saved_dir() { printf '%s/Pal/Saved' "$(server_dir)"; }
mods_file() { printf '%s/Mods/PalModSettings.ini' "$(server_dir)"; }
web_panel_src_dir() { printf '%s/web-panel' "$SCRIPT_DIR"; }
web_panel_dir() { printf '%s/web-panel' "$INSTALL_DIR"; }
service_file() { printf '/etc/systemd/system/%s.service' "$SERVICE_NAME"; }
web_panel_service_file() { printf '/etc/systemd/system/%s.service' "$WEB_PANEL_SERVICE_NAME"; }
caddyfile() { printf '/etc/caddy/Caddyfile'; }
backup_service_file() { printf '/etc/systemd/system/%s.service' "$TIMER_NAME"; }
backup_timer_file() { printf '/etc/systemd/system/%s.timer' "$TIMER_NAME"; }
announce_service_file() { printf '/etc/systemd/system/%s.service' "$ANNOUNCE_TIMER_NAME"; }
announce_timer_file() { printf '/etc/systemd/system/%s.timer' "$ANNOUNCE_TIMER_NAME"; }

load_state() {
  local f
  f="$(state_file)"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  fi
}

save_state() {
  mkdir -p "$INSTALL_DIR"
  cat >"$(state_file)" <<EOF
INSTALL_DIR=$(printf '%q' "$INSTALL_DIR")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
SERVER_USER=$(printf '%q' "$SERVER_USER")
SERVER_GROUP=$(printf '%q' "$SERVER_GROUP")
GAME_PORT=$(printf '%q' "$GAME_PORT")
MAX_PLAYERS=$(printf '%q' "$MAX_PLAYERS")
REST_PORT=$(printf '%q' "$REST_PORT")
RCON_PORT=$(printf '%q' "$RCON_PORT")
PUBLIC_LOBBY=$(printf '%q' "$PUBLIC_LOBBY")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
PUBLIC_PORT=$(printf '%q' "$PUBLIC_PORT")
LOG_FORMAT=$(printf '%q' "$LOG_FORMAT")
USE_PERF_ARGS=$(printf '%q' "$USE_PERF_ARGS")
WORKER_THREADS=$(printf '%q' "$WORKER_THREADS")
STEAM_FORCE_IPV4=$(printf '%q' "$STEAM_FORCE_IPV4")
ANNOUNCE_EVERY_MINUTES=$(printf '%q' "$ANNOUNCE_EVERY_MINUTES")
ANNOUNCE_MESSAGE=$(printf '%q' "$ANNOUNCE_MESSAGE")
WEB_PANEL_HOST=$(printf '%q' "$WEB_PANEL_HOST")
WEB_PANEL_PORT=$(printf '%q' "$WEB_PANEL_PORT")
WEB_PANEL_PUBLIC_URL=$(printf '%q' "$WEB_PANEL_PUBLIC_URL")
WEB_PANEL_DOMAIN=$(printf '%q' "$WEB_PANEL_DOMAIN")
WEB_PANEL_TLS_EMAIL=$(printf '%q' "$WEB_PANEL_TLS_EMAIL")
GAME_CONNECT_HOST=$(printf '%q' "$GAME_CONNECT_HOST")
WEB_ADMIN_USER=$(printf '%q' "$WEB_ADMIN_USER")
DISCORD_GUILD_ID=$(printf '%q' "$DISCORD_GUILD_ID")
DISCORD_INVITE_URL=$(printf '%q' "$DISCORD_INVITE_URL")
MICROSOFT_CLIENT_ID=$(printf '%q' "$MICROSOFT_CLIENT_ID")
MICROSOFT_TENANT=$(printf '%q' "$MICROSOFT_TENANT")
EOF
}

random_password() {
  if have openssl; then
    openssl rand -base64 32 | tr -d '=+/' | cut -c1-28
  else
    tr -dc 'A-Za-z0-9_@#%+=' </dev/urandom | head -c 28
  fi
}

wait_for_apt_locks() {
  require_root
  local timeout="${1:-600}"
  local end=$((SECONDS + timeout))
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  local lock pids printed="false"

  while [[ "$SECONDS" -lt "$end" ]]; do
    local busy="false"
    for lock in "${locks[@]}"; do
      [[ -e "$lock" ]] || continue
      pids="$(fuser "$lock" 2>/dev/null || true)"
      if [[ -n "$pids" ]]; then
        busy="true"
        if [[ "$printed" == "false" ]]; then
          warn "Ubuntu package manager is busy; waiting for apt/dpkg lock to clear."
          warn "This is usually unattended-upgrades finishing security updates. Do not delete lock files."
          printed="true"
        fi
        echo "Waiting on $lock held by PID(s): $pids"
        ps -fp $pids 2>/dev/null || true
        break
      fi
    done
    [[ "$busy" == "false" ]] && return 0
    sleep 10
  done

  fail "Timed out waiting for apt/dpkg locks. Check: ps -fp \$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)"
}

apt_get_update() {
  wait_for_apt_locks 900
  apt-get update
}

apt_get_install() {
  wait_for_apt_locks 900
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

ensure_user() {
  if [[ "$ROOTLESS" == "true" ]]; then
    SERVER_USER="$(id -un)"
    SERVER_GROUP="$(id -gn)"
    return
  fi
  if ! id "$SERVER_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$SERVER_USER"
    ok "Created user: $SERVER_USER"
  fi
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$(server_dir)" "$(steamcmd_dir)"
  if [[ "$ROOTLESS" != "true" ]]; then
    chown -R "$SERVER_USER:$SERVER_GROUP" "$INSTALL_DIR" "$BACKUP_DIR"
  fi
}

repair_install_permissions() {
  mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$(server_dir)" "$(steamcmd_dir)"
  chmod 755 "$INSTALL_DIR" "$(server_dir)" "$(steamcmd_dir)" 2>/dev/null || true
  if [[ "$ROOTLESS" != "true" ]]; then
    chown -R "$SERVER_USER:$SERVER_GROUP" "$INSTALL_DIR" "$BACKUP_DIR"
  fi
}

apt_install_basics() {
  require_root
  export DEBIAN_FRONTEND=noninteractive
  dpkg --add-architecture i386 || true
  apt_get_update
  cleanup_broken_steamcmd_package
  if have debconf-set-selections; then
    printf 'steam steam/question select I AGREE\n' | debconf-set-selections || true
    printf 'steam steam/license note \n' | debconf-set-selections || true
  fi
  apt_get_install software-properties-common ca-certificates curl tar gzip jq lib32gcc-s1 lib32stdc++6
  if apt-cache show steamcmd >/dev/null 2>&1; then
    if ! apt_get_install steamcmd; then
      warn "Ubuntu steamcmd package install failed; using manual SteamCMD."
      dpkg --remove --force-remove-reinstreq steamcmd:i386 steamcmd >/dev/null 2>&1 || true
    fi
  fi
}

cleanup_broken_steamcmd_package() {
  local pkg status
  for pkg in steamcmd:i386 steamcmd; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
    if [[ -n "$status" && "$status" != "ii " ]]; then
      warn "Removing broken partial package state for $pkg."
      dpkg --remove --force-remove-reinstreq "$pkg" >/dev/null 2>&1 || true
    fi
  done
}

steamcmd_bin() {
  if [[ -x "$(steamcmd_dir)/steamcmd.sh" ]]; then
    printf '%s/steamcmd.sh' "$(steamcmd_dir)"
    return
  fi
  if have steamcmd; then
    command -v steamcmd
    return
  fi
  printf '%s/steamcmd.sh' "$(steamcmd_dir)"
}

install_manual_steamcmd() {
  local bin tarball
  bin="$(steamcmd_bin)"
  mkdir -p "$(steamcmd_dir)"
  if [[ ! -x "$bin" || ! -f "$(steamcmd_dir)/linux32/steamcmd" ]]; then
    tarball="/tmp/steamcmd_linux.tar.gz"
    log "Downloading SteamCMD manually..."
    curl -fsSL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' -o "$tarball"
    tar -xzf "$tarball" -C "$(steamcmd_dir)"
    rm -f "$tarball"
  fi
  repair_steamcmd_permissions
}

repair_steamcmd_permissions() {
  local dir
  dir="$(steamcmd_dir)"
  [[ -d "$dir" ]] || return
  chmod 755 "$dir" || true
  find "$dir" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$dir" -type f \( -name 'steamcmd.sh' -o -name 'steamcmd' -o -name '*.so' \) -exec chmod 755 {} \; 2>/dev/null || true
  if [[ "$ROOTLESS" != "true" ]]; then
    chown -R "$SERVER_USER:$SERVER_GROUP" "$dir"
  fi
}

run_as_server_user() {
  if [[ "$ROOTLESS" == "true" || "$(id -un)" == "$SERVER_USER" ]]; then
    "$@"
  else
    sudo -u "$SERVER_USER" -- "$@"
  fi
}

server_home() {
  if [[ "$ROOTLESS" == "true" ]]; then
    printf '%s' "$HOME"
  else
    getent passwd "$SERVER_USER" | cut -d: -f6
  fi
}

ensure_steam_runtime_links() {
  local home sdk_dir source_so
  home="$(server_home)"
  sdk_dir="$home/.steam/sdk64"
  source_so=""
  for candidate in \
    "$(steamcmd_dir)/linux64/steamclient.so" \
    "$home/.steam/steamcmd/linux64/steamclient.so" \
    "$home/Steam/linux64/steamclient.so"; do
    if [[ -f "$candidate" ]]; then
      source_so="$candidate"
      break
    fi
  done
  if [[ -z "$source_so" ]]; then
    warn "steamclient.so was not found yet; SteamCMD may create it on first run."
    return
  fi
  mkdir -p "$sdk_dir"
  cp -f "$source_so" "$sdk_dir/steamclient.so"
  if [[ "$ROOTLESS" != "true" ]]; then
    chown -R "$SERVER_USER:$SERVER_GROUP" "$home/.steam"
  fi
  ok "Prepared Steam runtime file: $sdk_dir/steamclient.so"
}

test_url_family() {
  local family="$1"
  local url="$2"
  have curl || return 1
  curl "$family" -sS --connect-timeout 8 --max-time 15 -o /dev/null "$url" >/dev/null 2>&1
}

should_force_steam_ipv4() {
  local test_url current
  case "$STEAM_FORCE_IPV4" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  have sysctl || return 1
  current="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf '1')"
  [[ "$current" == "0" ]] || return 1
  test_url="https://cache2-den-iwst.steamcontent.com"
  if test_url_family -4 "$test_url" && ! test_url_family -6 "$test_url"; then
    warn "Steam CDN IPv4 works but IPv6 does not. SteamCMD will be run with IPv6 temporarily disabled."
    return 0
  fi
  return 1
}

ssh_session_appears_ipv6() {
  [[ "${SSH_CONNECTION:-}" == *:* ]]
}

disable_ipv6_for_steamcmd() {
  [[ "$ROOTLESS" == "true" ]] && return 1
  require_root
  have sysctl || return 1
  if [[ "$STEAM_FORCE_IPV4" != "true" ]] && ssh_session_appears_ipv6; then
    warn "Current SSH session appears to use IPv6, so auto mode will not disable IPv6."
    warn "Use SteamCMD mode 'true' only if you have another way back into the server."
    return 1
  fi
  STEAM_IPV6_ALL_WAS="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf '0')"
  STEAM_IPV6_DEFAULT_WAS="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || printf '0')"
  if [[ "$STEAM_IPV6_ALL_WAS" == "0" || "$STEAM_IPV6_DEFAULT_WAS" == "0" ]]; then
    warn "Temporarily disabling IPv6 for SteamCMD download."
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null || return 1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null || true
    STEAM_IPV6_TEMP_DISABLED="true"
  fi
}

restore_ipv6_after_steamcmd() {
  [[ "${STEAM_IPV6_TEMP_DISABLED:-false}" == "true" ]] || return 0
  warn "Restoring IPv6 setting after SteamCMD download."
  sysctl -w "net.ipv6.conf.all.disable_ipv6=${STEAM_IPV6_ALL_WAS:-0}" >/dev/null || true
  sysctl -w "net.ipv6.conf.default.disable_ipv6=${STEAM_IPV6_DEFAULT_WAS:-0}" >/dev/null || true
  STEAM_IPV6_TEMP_DISABLED="false"
}

steam_update() {
  local attempt scmd status
  install_manual_steamcmd
  repair_install_permissions
  repair_steamcmd_permissions
  scmd="$(steamcmd_bin)"
  if should_force_steam_ipv4; then
    disable_ipv6_for_steamcmd || warn "Could not temporarily disable IPv6; trying SteamCMD normally."
  fi
  for attempt in 1 2 3; do
    log "Installing/updating Palworld Dedicated Server app $APP_ID, attempt $attempt/3..."
    set +e
    run_as_server_user "$scmd" \
      +@ShutdownOnFailedCommand 1 \
      +@NoPromptForPassword 1 \
      +@sSteamCmdForcePlatformType linux \
      +force_install_dir "$(server_dir)" \
      +login anonymous \
      +app_update "$APP_ID" validate \
      +quit
    status=$?
    set -e
    if [[ "$status" -eq 0 && -x "$(server_dir)/PalServer.sh" ]]; then
      ensure_steam_runtime_links
      ok "Palworld server files installed."
      restore_ipv6_after_steamcmd
      return 0
    fi
    warn "SteamCMD app_update failed with exit code $status."
    show_steamcmd_log_tail
    if [[ "${STEAM_IPV6_TEMP_DISABLED:-false}" != "true" && "$STEAM_FORCE_IPV4" != "false" ]] && steam_log_suggests_ipv6_failure; then
      warn "Steam content log matches the IPv6/no-connection failure pattern."
      disable_ipv6_for_steamcmd || warn "Could not temporarily disable IPv6; continuing normal retries."
    fi
    cleanup_partial_palworld_download
    repair_install_permissions
    repair_steamcmd_permissions
    sleep 5
  done
  restore_ipv6_after_steamcmd
  fail "SteamCMD could not install app $APP_ID after 3 attempts. Check network, disk space, and Steam content logs."
}

cleanup_partial_palworld_download() {
  local steamapps
  steamapps="$(server_dir)/steamapps"
  [[ -d "$steamapps" ]] || return
  warn "Cleaning partial Steam download state for app $APP_ID before retry."
  rm -f "$steamapps/appmanifest_${APP_ID}.acf" 2>/dev/null || true
  rm -rf "$steamapps/downloading/$APP_ID" "$steamapps/temp/$APP_ID" 2>/dev/null || true
}

show_steamcmd_log_tail() {
  local log_file
  log_file="$(find_steamcmd_log)"
  if [[ -n "$log_file" ]]; then
    warn "SteamCMD log tail: $log_file"
    tail -n 40 "$log_file" >&2 || true
    return
  fi
  warn "No SteamCMD content log found yet."
}

find_steamcmd_log() {
  local home log_file
  home="$(server_home)"
  for log_file in \
    "$home/Steam/logs/content_log.txt" \
    "$home/Steam/logs/stderr.txt" \
    "$(steamcmd_dir)/logs/content_log.txt" \
    "$(steamcmd_dir)/logs/stderr.txt"; do
    if [[ -f "$log_file" ]]; then
      printf '%s' "$log_file"
      return
    fi
  done
}

steam_log_suggests_ipv6_failure() {
  local log_file
  log_file="$(find_steamcmd_log)"
  [[ -n "$log_file" ]] || return 1
  grep -Eq 'No connection|failed to send manifest request|Failed downloading .*manifest' "$log_file" &&
    grep -Eq '\[[0-9A-Fa-f:]+\]:443|IPv6|steamcontent\.com' "$log_file"
}

ensure_settings() {
  local cfg default_cfg cfg_dir
  cfg="$(settings_file)"
  default_cfg="$(default_settings_file)"
  cfg_dir="$(dirname "$cfg")"
  if [[ -f "$cfg" ]]; then
    return
  fi
  [[ -f "$default_cfg" ]] || fail "DefaultPalWorldSettings.ini not found. Run install/update first."
  mkdir -p "$cfg_dir"
  cp "$default_cfg" "$cfg"
  if [[ "$ROOTLESS" != "true" ]]; then
    chown -R "$SERVER_USER:$SERVER_GROUP" "$(server_dir)/Pal/Saved"
  fi
  ok "Created LinuxServer PalWorldSettings.ini from defaults."
}

python_edit_settings() {
  local cfg pairs_json
  cfg="$(settings_file)"
  pairs_json="$1"
  python3 - "$cfg" "$pairs_json" <<'PY'
import json
import re
import sys
from collections import OrderedDict

path = sys.argv[1]
updates = json.loads(sys.argv[2], object_pairs_hook=OrderedDict)
text = open(path, encoding="utf-8-sig").read()
m = re.search(r"OptionSettings=\((.*)\)", text, re.S)
if not m:
    raise SystemExit("OptionSettings=(...) not found")

def split_top_level(s, sep=","):
    out, cur, depth, quote, esc = [], [], 0, False, False
    for ch in s:
        if esc:
            cur.append(ch); esc = False; continue
        if ch == "\\":
            cur.append(ch); esc = True; continue
        if ch == '"':
            quote = not quote; cur.append(ch); continue
        if not quote:
            if ch == "(":
                depth += 1
            elif ch == ")" and depth:
                depth -= 1
            elif ch == sep and depth == 0:
                out.append("".join(cur).strip()); cur = []; continue
        cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out

def split_eq(s):
    cur, depth, quote, esc = [], 0, False, False
    for i, ch in enumerate(s):
        if esc:
            esc = False; continue
        if ch == "\\":
            esc = True; continue
        if ch == '"':
            quote = not quote; continue
        if not quote:
            if ch == "(":
                depth += 1
            elif ch == ")" and depth:
                depth -= 1
            elif ch == "=" and depth == 0:
                return s[:i].strip(), s[i+1:].strip()
    return s.strip(), ""

settings = OrderedDict()
for item in split_top_level(m.group(1)):
    if not item:
        continue
    k, v = split_eq(item)
    settings[k] = v

string_keys = {
    "AdminPassword", "BanListURL", "PublicIP", "Region",
    "ServerDescription", "ServerName", "ServerPassword"
}

def raw_value(key, value):
    value = "" if value is None else str(value).strip()
    if value.lower().startswith("raw:"):
        return value[4:]
    if value.lower() in ("true", "false"):
        return "True" if value.lower() == "true" else "False"
    if re.fullmatch(r"-?\d+(\.\d+)?", value):
        return value
    if value.startswith("(") and value.endswith(")"):
        return value
    if value.startswith('"') and value.endswith('"'):
        return value
    if key in string_keys or (key in settings and settings[key].startswith('"') and settings[key].endswith('"')):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return value

for k, v in updates.items():
    settings[k] = raw_value(k, v)

body = ",".join(f"{k}={v}" for k, v in settings.items())
new = text[:m.start()] + "OptionSettings=(" + body + ")" + text[m.end():]
open(path, "w", encoding="utf-8").write(new)
PY
}

set_settings_assoc() {
  local was_active="false"
  if [[ "$ROOTLESS" != "true" ]] && server_service_active; then
    require_root
    was_active="true"
    warn "Palworld is running. Stopping before writing settings so shutdown cannot overwrite your changes."
    local old_message="$MESSAGE"
    MESSAGE="Applying server settings"
    if ! stop_server; then
      MESSAGE="$old_message"
      fail "Palworld did not stop cleanly; settings were not changed."
    fi
    MESSAGE="$old_message"
    if server_service_active; then
      fail "Palworld is still running; refusing to edit settings while the server can overwrite them."
    fi
  fi
  ensure_settings
  local json
  json="{"
  local first="true"
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || fail "Invalid setting '$kv'. Use Key=Value."
    local k="${kv%%=*}"
    local v="${kv#*=}"
    if [[ "$first" == "false" ]]; then json+=","; fi
    first="false"
    json+="$(printf '%s' "$k" | jq -Rsa .):$(printf '%s' "$v" | jq -Rsa .)"
  done
  json+="}"
  python_edit_settings "$json"
  verify_settings_assoc "$@"
  ok "Updated PalWorldSettings.ini."
  if [[ "$was_active" == "true" ]]; then
    start_server
    verify_settings_assoc "$@"
    warn "Settings were applied with a full stop/start. Reconnect before testing."
  fi
}

verify_settings_assoc() {
  local kv key expected actual expected_norm actual_norm
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || continue
    key="${kv%%=*}"
    expected="${kv#*=}"
    actual="$(get_setting "$key" || true)"
    expected_norm="$(normalize_setting_value "$expected")"
    actual_norm="$(normalize_setting_value "$actual")"
    if [[ "$expected_norm" != "$actual_norm" ]]; then
      fail "Setting verification failed for $key: expected '$expected', but $(settings_file) contains '$actual'."
    fi
  done
}

normalize_setting_value() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value%\"}"
  value="${value#\"}"
  case "${value,,}" in
    true) printf 'True' ;;
    false) printf 'False' ;;
    *) printf '%s' "$value" ;;
  esac
}

get_setting() {
  local key="$1"
  [[ -f "$(settings_file)" ]] || return 0
  python3 - "$key" "$(settings_file)" <<'PY'
import re, sys
key, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8-sig").read()
m = re.search(r"OptionSettings=\((.*)\)", text, re.S)
if not m:
    sys.exit(0)
s = m.group(1)
depth = 0; quote = False; esc = False; cur = []
parts = []
for ch in s:
    if esc:
        cur.append(ch); esc = False; continue
    if ch == "\\":
        cur.append(ch); esc = True; continue
    if ch == '"':
        quote = not quote; cur.append(ch); continue
    if not quote:
        if ch == "(":
            depth += 1
        elif ch == ")" and depth:
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(cur).strip()); cur = []; continue
    cur.append(ch)
if cur:
    parts.append("".join(cur).strip())
for part in parts:
    if part.startswith(key + "="):
        value = part.split("=", 1)[1]
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1].replace('\\"', '"').replace('\\\\', '\\')
        print(value)
        break
PY
}

show_settings() {
  ensure_settings
  python3 - "$(settings_file)" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8-sig").read()
m = re.search(r"OptionSettings=\((.*)\)", text, re.S)
if not m:
    raise SystemExit("OptionSettings=(...) not found")
s = m.group(1)
parts=[]; cur=[]; depth=0; quote=False; esc=False
for ch in s:
    if esc:
        cur.append(ch); esc=False; continue
    if ch == "\\":
        cur.append(ch); esc=True; continue
    if ch == '"':
        quote=not quote; cur.append(ch); continue
    if not quote:
        if ch == "(": depth += 1
        elif ch == ")" and depth: depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(cur).strip()); cur=[]; continue
    cur.append(ch)
if cur: parts.append("".join(cur).strip())
print("\n".join(parts))
PY
}

settings_format_diagnostics() {
  local cfg
  cfg="$(settings_file)"
  [[ -f "$cfg" ]] || { warn "Settings file is missing."; return 0; }
  python3 - "$cfg" <<'PY'
import re
import sys
from collections import Counter, defaultdict

path = sys.argv[1]
text = open(path, encoding="utf-8-sig").read()
lines = text.splitlines()
print(f"  line_count={len(lines)}")
if not lines or lines[0].strip() != "[/Script/Pal.PalGameWorldSettings]":
    print("  WARN: expected first line [/Script/Pal.PalGameWorldSettings]")
else:
    print("  header=ok")

m = re.search(r"OptionSettings=\((.*)\)", text, re.S)
if not m:
    print("  WARN: OptionSettings=(...) not found")
    raise SystemExit(0)

body = m.group(1)
if "\n" in body or "\r" in body:
    print("  WARN: OptionSettings contains real line breaks; Palworld expects the settings tuple on one line")
else:
    print("  option_settings_line=ok")

if len(lines) != 2:
    print("  WARN: PalWorldSettings.ini is normally exactly 2 lines; extra lines can make troubleshooting confusing")

def split_top_level(s, sep=","):
    out, cur, depth, quote, esc = [], [], 0, False, False
    for ch in s:
        if esc:
            cur.append(ch); esc = False; continue
        if ch == "\\":
            cur.append(ch); esc = True; continue
        if ch == '"':
            quote = not quote; cur.append(ch); continue
        if not quote:
            if ch == "(":
                depth += 1
            elif ch == ")" and depth:
                depth -= 1
            elif ch == sep and depth == 0:
                out.append("".join(cur).strip()); cur = []; continue
        cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out

def split_eq(s):
    depth, quote, esc = 0, False, False
    for i, ch in enumerate(s):
        if esc:
            esc = False; continue
        if ch == "\\":
            esc = True; continue
        if ch == '"':
            quote = not quote; continue
        if not quote:
            if ch == "(":
                depth += 1
            elif ch == ")" and depth:
                depth -= 1
            elif ch == "=" and depth == 0:
                return s[:i].strip(), s[i + 1:].strip()
    return s.strip(), ""

keys = []
values = defaultdict(list)
bad_parts = []
for item in split_top_level(body):
    if not item:
        continue
    key, value = split_eq(item)
    if not key or not value:
        bad_parts.append(item[:80])
        continue
    keys.append(key)
    values[key].append(value)

if bad_parts:
    print("  WARN: could not parse these setting entries:")
    for item in bad_parts[:10]:
        print(f"    {item}")
else:
    print("  parse=ok")

dupes = [key for key, count in Counter(keys).items() if count > 1]
if dupes:
    print("  WARN: duplicate keys found; Palworld may use a different copy than the web/script shows:")
    for key in sorted(dupes):
        print(f"    {key}: {' -> '.join(values[key])}")
else:
    print("  duplicate_keys=none")

important = [
    "bEnableFastTravel",
    "bIsFastTravelDisabled",
    "bEnableFastTravelOnlyBaseCamp",
    "bAllowGlobalPalboxImport",
    "bAllowGlobalPalboxExport",
    "Difficulty",
]
for key in important:
    if values.get(key):
        print(f"  raw_last_{key}={values[key][-1]}")
    else:
        print(f"  raw_last_{key}=missing")
PY
}

worldoption_root() { printf '%s/Pal/Saved/SaveGames' "$(server_dir)"; }

find_worldoption_saves() {
  local root
  root="$(worldoption_root)"
  [[ -d "$root" ]] || return 0
  find "$root" -type f \( -iname 'WorldOption.sav' -o -iname 'WorldOptions.sav' -o -iname '*WorldOption*.sav' \) -print 2>/dev/null | sort -u
}

worldoption_status() {
  load_state
  echo "PalWorldSettings.ini:"
  echo "  $(settings_file)"
  echo
  echo "Global Palbox settings currently written to ini:"
  echo "  bAllowGlobalPalboxImport=$(get_setting bAllowGlobalPalboxImport || printf 'missing')"
  echo "  bAllowGlobalPalboxExport=$(get_setting bAllowGlobalPalboxExport || printf 'missing')"
  echo
  echo "WorldOption/WorldOptions.sav override check:"
  local found="false"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    found="true"
    warn "Found override file: $file"
  done < <(find_worldoption_saves)
  if [[ "$found" == "true" ]]; then
    warn "WorldOption/WorldOptions.sav can override gameplay/world settings from PalWorldSettings.ini."
    warn "This commonly blocks Global Palbox import/export changes on existing or migrated worlds."
    warn "Use Settings -> Disable WorldOption/WorldOptions.sav overrides to make PalWorldSettings.ini win."
  else
    ok "No WorldOption/WorldOptions.sav override files found."
  fi
}

settings_diagnostics() {
  load_state
  echo "Settings diagnostics"
  echo
  echo "Manager script:"
  echo "  $SCRIPT_PATH"
  echo "Install dir:"
  echo "  $INSTALL_DIR"
  echo "Expected server dir:"
  echo "  $(server_dir)"
  echo "Expected active config:"
  echo "  $(settings_file)"
  echo
  echo "systemd service:"
  if have systemctl && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    systemctl show "$SERVICE_NAME" -p FragmentPath -p ExecStart -p User -p WorkingDirectory --no-pager || true
    local exec_text
    exec_text="$(systemctl show "$SERVICE_NAME" -p ExecStart --value 2>/dev/null || true)"
    if [[ "$exec_text" != *"$(server_dir)"* ]]; then
      warn "The palworld.service ExecStart does not appear to use $(server_dir)."
      warn "If the service starts another PalServer.sh, this manager is editing the wrong config."
    fi
  else
    warn "palworld.service is not installed."
  fi
  echo
  echo "Running PalServer processes:"
  pgrep -af 'PalServer|PalServer-Linux' || warn "No PalServer process found."
  echo
  echo "Config file status:"
  if [[ -f "$(settings_file)" ]]; then
    ls -l "$(settings_file)"
    stat -c '  modified=%y owner=%U group=%G mode=%a size=%s' "$(settings_file)" 2>/dev/null || true
    echo "  bEnableFastTravel=$(get_setting bEnableFastTravel || printf 'missing')"
    echo "  bIsFastTravelDisabled=$(get_setting bIsFastTravelDisabled || printf 'missing')"
    echo "  bEnableFastTravelOnlyBaseCamp=$(get_setting bEnableFastTravelOnlyBaseCamp || printf 'missing')"
    echo "  bAllowGlobalPalboxImport=$(get_setting bAllowGlobalPalboxImport || printf 'missing')"
    echo "  bAllowGlobalPalboxExport=$(get_setting bAllowGlobalPalboxExport || printf 'missing')"
    echo "  Difficulty=$(get_setting Difficulty || printf 'missing')"
  else
    warn "Expected config file is missing."
  fi
  echo
  echo "Settings file format diagnostics:"
  settings_format_diagnostics
  echo
  echo "Other PalWorldSettings.ini files found under /opt, /home, and /root:"
  find /opt /home /root -type f -name 'PalWorldSettings.ini' -print 2>/dev/null | sort | sed 's/^/  /' || true
  echo
  worldoption_status
}

disable_worldoption_overrides() {
  require_root
  load_state
  local -a files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(find_worldoption_saves)
  if [[ ${#files[@]} -eq 0 ]]; then
    ok "No WorldOption/WorldOptions.sav override files found."
    return 0
  fi
  warn "This will rename WorldOption/WorldOptions.sav files so PalWorldSettings.ini controls world settings."
  warn "Existing world/build/player saves are kept. The renamed override files can be restored manually if needed."
  if [[ "$FORCE" != "true" && -t 0 ]]; then
    prompt_yes_no "Back up saves, stop Palworld, disable WorldOption/WorldOptions.sav overrides, and start again" "y" || return 0
  fi
  backup "pre-worldoption-disable-$(date +%Y%m%d-%H%M%S)" || warn "Backup failed; continuing with override rename."
  stop_server || warn "Stop did not finish cleanly; continuing with override rename."
  local stamp target
  stamp="$(date +%Y%m%d-%H%M%S)"
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    target="${file}.disabled-${stamp}"
    mv "$file" "$target"
    ok "Renamed $(basename "$file") -> $(basename "$target")"
  done
  start_server || warn "Start failed; check service logs."
  warn "Restart complete. Recheck Global Palbox from a freshly reconnected client."
}

enable_global_palbox_safely() {
  require_root
  load_state
  local was_active="false"
  server_service_active && was_active="true"
  warn "This will enable Global Palbox import/export in PalWorldSettings.ini."
  warn "If WorldOption.sav overrides exist, they will be renamed so the ini settings can apply."
  if [[ "$FORCE" != "true" && -t 0 ]]; then
    prompt_yes_no "Back up saves, stop Palworld if needed, enable Global Palbox, and start again" "y" || return 0
  fi
  backup "pre-global-palbox-enable-$(date +%Y%m%d-%H%M%S)" || warn "Backup failed; continuing with Global Palbox update."
  if [[ "$was_active" == "true" ]]; then
    local old_message="$MESSAGE"
    MESSAGE="Applying Global Palbox settings"
    stop_server || warn "Stop did not finish cleanly; continuing with settings update."
    MESSAGE="$old_message"
  fi
  set_settings_assoc "bAllowGlobalPalboxImport=True" "bAllowGlobalPalboxExport=True"
  local -a files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(find_worldoption_saves)
  if [[ ${#files[@]} -gt 0 ]]; then
    local stamp target
    stamp="$(date +%Y%m%d-%H%M%S)"
    for file in "${files[@]}"; do
      [[ -f "$file" ]] || continue
      target="${file}.disabled-${stamp}"
      mv "$file" "$target"
      ok "Renamed $(basename "$file") -> $(basename "$target")"
    done
  fi
  if [[ "$was_active" == "true" ]]; then
    start_server || warn "Start failed; check service logs."
  else
    warn "Palworld was not running. Start it when you are ready."
  fi
  worldoption_status
  warn "Reconnect to Palworld before testing Global Palbox."
}

enable_fast_travel_safely() {
  require_root
  load_state
  local was_active="false"
  server_service_active && was_active="true"
  warn "This will enable fast travel statues in PalWorldSettings.ini."
  warn "If WorldOption.sav overrides exist, they will be renamed so the ini settings can apply."
  if [[ "$FORCE" != "true" && -t 0 ]]; then
    prompt_yes_no "Back up saves, stop Palworld if needed, enable fast travel, and start again" "y" || return 0
  fi
  backup "pre-fast-travel-enable-$(date +%Y%m%d-%H%M%S)" || warn "Backup failed; continuing with fast travel update."
  if [[ "$was_active" == "true" ]]; then
    local old_message="$MESSAGE"
    MESSAGE="Applying fast travel settings"
    stop_server || warn "Stop did not finish cleanly; continuing with settings update."
    MESSAGE="$old_message"
  fi
  set_settings_assoc \
    "bEnableFastTravel=True" \
    "bIsFastTravelDisabled=False" \
    "bEnableFastTravelOnlyBaseCamp=False"
  local -a files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(find_worldoption_saves)
  if [[ ${#files[@]} -gt 0 ]]; then
    local stamp target
    stamp="$(date +%Y%m%d-%H%M%S)"
    for file in "${files[@]}"; do
      [[ -f "$file" ]] || continue
      target="${file}.disabled-${stamp}"
      mv "$file" "$target"
      ok "Renamed $(basename "$file") -> $(basename "$target")"
    done
  fi
  if [[ "$was_active" == "true" ]]; then
    start_server || warn "Start failed; check service logs."
  else
    warn "Palworld was not running. Start it when you are ready."
  fi
  echo "Fast travel settings currently written to ini:"
  echo "  bEnableFastTravel=$(get_setting bEnableFastTravel || printf 'missing')"
  echo "  bIsFastTravelDisabled=$(get_setting bIsFastTravelDisabled || printf 'missing')"
  echo "  bEnableFastTravelOnlyBaseCamp=$(get_setting bEnableFastTravelOnlyBaseCamp || printf 'missing')"
  warn "Reconnect to Palworld before testing fast travel."
}

apply_install_settings() {
  ensure_settings
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(get_setting AdminPassword || true)"
  fi
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(random_password)"
    warn "Generated AdminPassword: $ADMIN_PASSWORD"
    warn "Save it somewhere private. It is also written into PalWorldSettings.ini."
  fi

  local pairs=(
    "AdminPassword=$ADMIN_PASSWORD"
    "RESTAPIEnabled=True"
    "RESTAPIPort=$REST_PORT"
    "RCONEnabled=$ENABLE_RCON"
    "RCONPort=$RCON_PORT"
    "ServerPlayerMaxNum=$MAX_PLAYERS"
    "bIsUseBackupSaveData=True"
    "bShowPlayerList=True"
    "LogFormatType=$LOG_FORMAT"
    "PublicPort=${PUBLIC_PORT:-$GAME_PORT}"
  )
  [[ -n "$SERVER_NAME" ]] && pairs+=("ServerName=$SERVER_NAME")
  [[ -n "$SERVER_DESCRIPTION" ]] && pairs+=("ServerDescription=$SERVER_DESCRIPTION")
  [[ -n "$SERVER_PASSWORD" ]] && pairs+=("ServerPassword=$SERVER_PASSWORD")
  [[ -n "$PUBLIC_IP" ]] && pairs+=("PublicIP=$PUBLIC_IP")
  set_settings_assoc "${pairs[@]}"
}

launch_args() {
  load_state
  local args=("-port=$GAME_PORT" "-players=$MAX_PLAYERS" "-logformat=$LOG_FORMAT")
  [[ "$PUBLIC_LOBBY" == "true" ]] && args+=("-publiclobby")
  [[ -n "$PUBLIC_IP" ]] && args+=("-publicip=$PUBLIC_IP")
  [[ -n "$PUBLIC_PORT" ]] && args+=("-publicport=$PUBLIC_PORT")
  if [[ "$USE_PERF_ARGS" == "true" ]]; then
    args+=("-useperfthreads" "-NoAsyncLoadingThread" "-UseMultithreadForDS")
    [[ -n "$WORKER_THREADS" ]] && args+=("-NumberOfWorkerThreadsServer=$WORKER_THREADS")
  fi
  printf '%q ' "${args[@]}"
}

write_systemd_service() {
  require_root
  local args
  args="$(launch_args)"
  cat >"$(service_file)" <<EOF
[Unit]
Description=Palworld Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$SERVER_USER
Group=$SERVER_GROUP
WorkingDirectory=$(server_dir)
ExecStart=$(server_dir)/PalServer.sh $args
Restart=on-failure
RestartSec=15
LimitNOFILE=100000
KillSignal=SIGINT
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  ok "Installed systemd service: $(service_file)"
}

install_server() {
  if [[ "$ROOTLESS" == "true" ]]; then
    warn "Rootless install skips apt packages, system user creation, UFW, and systemd."
    warn "Install curl, jq, python3, tar, gzip, and 32-bit Steam runtime libraries yourself if missing."
  else
    require_root
    apt_install_basics
  fi
  ensure_user
  ensure_dirs
  steam_update
  apply_install_settings
  save_state
  if [[ "$ROOTLESS" != "true" ]]; then
    write_systemd_service
  fi
  ok "Install complete."
  warn "Forward UDP $GAME_PORT on your router/firewall to this server for public play."
}

start_server() {
  if [[ "$ROOTLESS" == "true" ]]; then
    ensure_settings
    cd "$(server_dir)"
    log "Starting PalServer.sh $(launch_args)"
    exec ./PalServer.sh $(launch_args)
  fi
  require_root
  systemctl start "$SERVICE_NAME"
  sleep 5
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Started $SERVICE_NAME."
    warn "Give Palworld a minute to finish loading before connecting from the game."
  else
    warn "$SERVICE_NAME did not stay running. Recent service logs:"
    journalctl -u "$SERVICE_NAME" -n 120 --no-pager || true
    return 1
  fi
}

stop_server() {
  if [[ "$ROOTLESS" == "true" ]]; then
    fail "Rootless stop is manual: stop the foreground PalServer.sh process."
  fi
  require_root
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    save_world || true
    shutdown_api || true
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      if [[ "$FORCE" == "true" ]]; then
        systemctl stop "$SERVICE_NAME"
      else
        log "Waiting up to $((SHUTDOWN_WAIT + 30)) seconds for graceful shutdown..."
        local end=$((SECONDS + SHUTDOWN_WAIT + 30))
        while systemctl is-active --quiet "$SERVICE_NAME" && [[ "$SECONDS" -lt "$end" ]]; do
          sleep 2
        done
        if systemctl is-active --quiet "$SERVICE_NAME"; then
          warn "Still running. Re-run stop with --force if needed."
          return 1
        fi
      fi
    fi
  fi
  ok "Stopped $SERVICE_NAME."
}

restart_server() {
  [[ "$NO_BACKUP" == "true" ]] || backup "pre-restart-$(date +%Y%m%d-%H%M%S)" || true
  stop_server || [[ "$FORCE" == "true" ]]
  start_server
}

server_service_active() {
  have systemctl && systemctl is-active --quiet "$SERVICE_NAME"
}

status_server() {
  load_state
  echo "Install dir:  $INSTALL_DIR"
  echo "Server dir:   $(server_dir)"
  echo "Config:       $(settings_file)"
  echo "Backups:      $BACKUP_DIR"
  echo "Launch args:  $(launch_args)"
  if have systemctl && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      api_call GET info || warn "Service is running, but REST API is not reachable yet. It may still be starting."
    else
      warn "Palworld is not running. The game will time out until you start the service."
      warn "Menu path: Start / stop / status / logs -> Start server"
      warn "After it is active, check UDP $GAME_PORT in UFW and your provider/router firewall."
    fi
  else
    pgrep -af PalServer || true
    warn "systemd service is not installed yet. Run Install / initial setup first."
  fi
}

api_password() {
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    printf '%s' "$ADMIN_PASSWORD"
    return
  fi
  local from_cfg
  from_cfg="$(get_setting AdminPassword || true)"
  [[ -n "$from_cfg" ]] || fail "AdminPassword is needed for REST API calls."
  printf '%s' "$from_cfg"
}

api_call() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local pass base url
  load_state
  pass="$(api_password)"
  for base in "http://${API_HOST}:${REST_PORT}/v1/api" "http://${API_HOST}:${REST_PORT}"; do
    url="${base}/${endpoint#/}"
    if [[ -n "$body" ]]; then
      if curl -fsS -u "${API_USER}:${pass}" -H 'Content-Type: application/json' -X "$method" -d "$body" "$url"; then
        echo
        return 0
      fi
    else
      if curl -fsS -u "${API_USER}:${pass}" -X "$method" "$url"; then
        echo
        return 0
      fi
    fi
  done
  return 1
}

save_world() {
  api_call POST save >/dev/null && ok "World save requested." || return 1
}

shutdown_api() {
  local body
  body="$(jq -nc --arg msg "$MESSAGE" --argjson wait "$SHUTDOWN_WAIT" '{waittime:$wait,message:$msg}')"
  api_call POST shutdown "$body"
}

backup() {
  local name="${1:-palworld-save-$(date +%Y%m%d-%H%M%S)}"
  [[ -d "$(saved_dir)" ]] || fail "Saved directory does not exist yet. Start the server once first."
  mkdir -p "$BACKUP_DIR"
  save_world || warn "REST save failed; backing up current files anyway."
  sleep 2
  local out tmp
  out="${BACKUP_DIR}/${name}.tar.gz"
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/palworld"
  cp -a "$(saved_dir)" "$tmp/palworld/Saved"
  [[ -f "$(settings_file)" ]] && cp -a "$(settings_file)" "$tmp/palworld/PalWorldSettings.ini"
  [[ -f "$(state_file)" ]] && cp -a "$(state_file)" "$tmp/palworld/manager.env"
  tar -czf "$out" -C "$tmp" palworld
  rm -rf "$tmp"
  [[ "$ROOTLESS" != "true" ]] && chown "$SERVER_USER:$SERVER_GROUP" "$out" || true
  ok "Backup created: $out"
  prune_backups
}

prune_backups() {
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || return
  [[ "$BACKUP_KEEP" -gt 0 ]] || return
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null |
    sort -rn |
    awk -v keep="$BACKUP_KEEP" 'NR > keep {print substr($0, index($0,$2))}' |
    while IFS= read -r old; do
      rm -f "$old"
      log "Pruned old backup: $old"
    done
}

list_backups() {
  mkdir -p "$BACKUP_DIR"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM %s %p\n' 2>/dev/null | sort -r
}

restore_backup() {
  local archive="${POSITIONAL[0]:-}"
  [[ -n "$archive" ]] || archive="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
  [[ -f "$archive" ]] || fail "Backup archive not found."
  if [[ "$FORCE" != "true" ]]; then
    fail "Restore stops/replaces saves. Re-run with --force after confirming: $archive"
  fi
  [[ "$NO_BACKUP" == "true" ]] || backup "pre-restore-$(date +%Y%m%d-%H%M%S)" || true
  stop_server || true
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp"
  [[ -d "$tmp/palworld/Saved" ]] || fail "Archive does not contain palworld/Saved."
  rm -rf "$(saved_dir)"
  mkdir -p "$(dirname "$(saved_dir)")"
  cp -a "$tmp/palworld/Saved" "$(saved_dir)"
  rm -rf "$tmp"
  [[ "$ROOTLESS" != "true" ]] && chown -R "$SERVER_USER:$SERVER_GROUP" "$(saved_dir)" || true
  ok "Restored backup: $archive"
}

apply_preset() {
  local preset="${POSITIONAL[0]:-}"
  [[ -n "$preset" ]] || fail "Preset required: launch-public, balanced, casual, pve, boosted, builder, breeding, event-weekend, performance, pvp, raid, no-raids, hardcore"
  case "$preset" in
    launch-public)
      set_settings_assoc \
        "bIsUseBackupSaveData=True" "bShowPlayerList=True" "RESTAPIEnabled=True" \
        "RESTAPIPort=$REST_PORT" "RCONEnabled=False" "ChatPostLimitPerMinute=10" "LogFormatType=$LOG_FORMAT"
      ;;
    balanced)
      set_settings_assoc \
        "ExpRate=1.0" "PalCaptureRate=1.0" "PalSpawnNumRate=1.0" \
        "CollectionDropRate=1.0" "EnemyDropItemRate=1.0" "DeathPenalty=All" \
        "BaseCampMaxNum=4" "BaseCampWorkerMaxNum=20" "BuildObjectDeteriorationDamageRate=1.0"
      ;;
    casual)
      set_settings_assoc \
        "ExpRate=1.5" "PalCaptureRate=1.5" "CollectionDropRate=1.5" \
        "EnemyDropItemRate=1.25" "PalEggDefaultHatchingTime=0.5" "DeathPenalty=Item" \
        "BuildObjectDeteriorationDamageRate=0.5"
      ;;
    pve)
      set_settings_assoc \
        "bIsPvP=False" "bEnablePlayerToPlayerDamage=False" "bEnableFriendlyFire=False" \
        "bEnableDefenseOtherGuildPlayer=False" "DeathPenalty=Item" \
        "bCanPickupOtherGuildDeathPenaltyDrop=False" "bEnableFastTravel=True" \
        "bEnableFastTravelOnlyBaseCamp=False" "bExistPlayerAfterLogout=False" \
        "BuildObjectDeteriorationDamageRate=0.5"
      ;;
    boosted)
      set_settings_assoc \
        "ExpRate=2.0" "PalCaptureRate=2.0" "CollectionDropRate=2.0" \
        "CollectionObjectHpRate=0.75" "EnemyDropItemRate=1.5" \
        "PalEggDefaultHatchingTime=0.25" "PlayerStomachDecreaceRate=0.75" \
        "PlayerStaminaDecreaceRate=0.75" "PalStomachDecreaceRate=0.75" \
        "DeathPenalty=Item"
      ;;
    builder)
      set_settings_assoc \
        "BuildObjectDeteriorationDamageRate=0.0" "BuildObjectDamageRate=0.5" \
        "CollectionDropRate=2.0" "CollectionObjectHpRate=0.5" \
        "BaseCampMaxNum=6" "BaseCampWorkerMaxNum=30" "MaxBuildingLimitNum=5000" \
        "bEnableFastTravel=True"
      ;;
    breeding)
      set_settings_assoc \
        "PalEggDefaultHatchingTime=0.1" "PalCaptureRate=1.5" \
        "PalStomachDecreaceRate=0.5" "PalAutoHPRegeneRate=1.5" \
        "PalAutoHpRegeneRateInSleep=2.0" "CollectionDropRate=1.5"
      ;;
    event-weekend)
      set_settings_assoc \
        "ExpRate=3.0" "PalCaptureRate=2.0" "CollectionDropRate=2.5" \
        "EnemyDropItemRate=2.0" "PalSpawnNumRate=1.2" \
        "PalEggDefaultHatchingTime=0.1" "DeathPenalty=None"
      ;;
    performance)
      set_settings_assoc \
        "PalSpawnNumRate=0.8" "BaseCampMaxNum=4" "BaseCampWorkerMaxNum=20" \
        "DropItemMaxNum=2000" "DropItemAliveMaxHours=1.0" \
        "ServerReplicatePawnCullDistance=10000" "ItemContainerForceMarkDirtyInterval=1.0"
      ;;
    pvp)
      set_settings_assoc \
        "bIsPvP=True" "bEnablePlayerToPlayerDamage=True" "bEnableFriendlyFire=False" \
        "bEnableDefenseOtherGuildPlayer=True" \
        "DeathPenalty=All" "bCanPickupOtherGuildDeathPenaltyDrop=True" \
        "bAllowEnhanceStat_Health=False" "bAllowEnhanceStat_Attack=False" \
        "bEnableFastTravel=True" "bEnableFastTravelOnlyBaseCamp=True" \
        "bExistPlayerAfterLogout=True" \
        "GuildPlayerMaxNum=4" "BaseCampMaxNumInGuild=2" \
        "MaxBuildingLimitNum=1000" \
        "BlockRespawnTime=5.0" "RespawnPenaltyDurationThreshold=1800.0" \
        "RespawnPenaltyTimeScale=2.0"
      ;;
    raid)
      set_settings_assoc \
        "bEnableInvaderEnemy=True" "bEnableNonLoginPenalty=True" \
        "bEnableDefenseOtherGuildPlayer=True" "BuildObjectDamageRate=1.0" \
        "BuildObjectDeteriorationDamageRate=1.0" "DropItemAliveMaxHours=1.0"
      ;;
    no-raids)
      set_settings_assoc \
        "bEnableInvaderEnemy=False" "bEnableNonLoginPenalty=False" \
        "BuildObjectDeteriorationDamageRate=0.0" "bEnableDefenseOtherGuildPlayer=False"
      ;;
    hardcore)
      set_settings_assoc "bHardcore=True" "bPalLost=True" "DeathPenalty=All" "ExpRate=1.0"
      ;;
    *) fail "Unknown preset: $preset" ;;
  esac
  ok "Applied preset: $preset"
}

menu_guided_gameplay_rates() {
  local pairs=()
  local value
  value="$(prompt_text "EXP rate" "1.5")"; pairs+=("ExpRate=$value")
  value="$(prompt_text "Capture rate" "1.25")"; pairs+=("PalCaptureRate=$value")
  value="$(prompt_text "Pal spawn rate" "1.0")"; pairs+=("PalSpawnNumRate=$value")
  value="$(prompt_text "Gather/drop rate" "1.5")"; pairs+=("CollectionDropRate=$value")
  value="$(prompt_text "Resource object HP rate, lower means faster gathering" "1.0")"; pairs+=("CollectionObjectHpRate=$value")
  value="$(prompt_text "Enemy item drop rate" "1.25")"; pairs+=("EnemyDropItemRate=$value")
  value="$(prompt_text "Egg hatch time, lower is faster" "0.5")"; pairs+=("PalEggDefaultHatchingTime=$value")
  set_settings_assoc "${pairs[@]}"
  warn "Restart the server for settings to take effect."
}

menu_guided_survival_rules() {
  local pairs=()
  local value
  value="$(prompt_text "Death penalty: None, Item, ItemAndEquipment, All" "Item")"; pairs+=("DeathPenalty=$value")
  value="$(prompt_text "Player hunger drain rate" "1.0")"; pairs+=("PlayerStomachDecreaceRate=$value")
  value="$(prompt_text "Player stamina drain rate" "1.0")"; pairs+=("PlayerStaminaDecreaceRate=$value")
  value="$(prompt_text "Pal hunger drain rate" "1.0")"; pairs+=("PalStomachDecreaceRate=$value")
  value="$(prompt_text "Player damage dealt rate" "1.0")"; pairs+=("PlayerDamageRateAttack=$value")
  value="$(prompt_text "Player damage taken rate" "1.0")"; pairs+=("PlayerDamageRateDefense=$value")
  value="$(prompt_text "Pal damage dealt rate" "1.0")"; pairs+=("PalDamageRateAttack=$value")
  value="$(prompt_text "Pal damage taken rate" "1.0")"; pairs+=("PalDamageRateDefense=$value")
  set_settings_assoc "${pairs[@]}"
  warn "Restart the server for settings to take effect."
}

menu_guided_world_base_rules() {
  local pairs=()
  local value
  value="$(prompt_text "Max bases per player/guild baseline" "4")"; pairs+=("BaseCampMaxNum=$value")
  value="$(prompt_text "Max workers per base" "20")"; pairs+=("BaseCampWorkerMaxNum=$value")
  value="$(prompt_text "Max players per guild" "8")"; pairs+=("GuildPlayerMaxNum=$value")
  value="$(prompt_text "Max bases per guild" "4")"; pairs+=("BaseCampMaxNumInGuild=$value")
  value="$(prompt_text "Max building limit" "3000")"; pairs+=("MaxBuildingLimitNum=$value")
  value="$(prompt_text "Building deterioration damage rate" "0.5")"; pairs+=("BuildObjectDeteriorationDamageRate=$value")
  value="$(prompt_text "Dropped item max count" "3000")"; pairs+=("DropItemMaxNum=$value")
  value="$(prompt_text "Dropped item lifetime hours" "2.0")"; pairs+=("DropItemAliveMaxHours=$value")
  if prompt_yes_no "Enable fast travel statues" "y"; then
    pairs+=("bEnableFastTravel=True" "bIsFastTravelDisabled=False")
  else
    pairs+=("bEnableFastTravel=False" "bIsFastTravelDisabled=True")
  fi
  if prompt_yes_no "Allow fast travel only from base camps" "n"; then
    pairs+=("bEnableFastTravelOnlyBaseCamp=True")
  else
    pairs+=("bEnableFastTravelOnlyBaseCamp=False")
  fi
  if prompt_yes_no "Allow choosing start location from map" "y"; then
    pairs+=("bIsStartLocationSelectByMap=True")
  else
    pairs+=("bIsStartLocationSelectByMap=False")
  fi
  if prompt_yes_no "Allow Global Palbox import, so players can bring saved Pals into this server" "y"; then
    pairs+=("bAllowGlobalPalboxImport=True")
  else
    pairs+=("bAllowGlobalPalboxImport=False")
  fi
  if prompt_yes_no "Allow Global Palbox export, so players can save Pals out of this server" "y"; then
    pairs+=("bAllowGlobalPalboxExport=True")
  else
    pairs+=("bAllowGlobalPalboxExport=False")
  fi
  if prompt_yes_no "Enable base raids / invader enemies" "y"; then
    pairs+=("bEnableInvaderEnemy=True")
  else
    pairs+=("bEnableInvaderEnemy=False")
  fi
  if prompt_yes_no "Enable non-login penalty" "y"; then
    pairs+=("bEnableNonLoginPenalty=True")
  else
    pairs+=("bEnableNonLoginPenalty=False")
  fi
  set_settings_assoc "${pairs[@]}"
  warn "Restart the server for settings to take effect."
}

menu_guided_pvp_rules() {
  local pairs=()
  if prompt_yes_no "Enable PvP" "y"; then pairs+=("bIsPvP=True"); else pairs+=("bIsPvP=False"); fi
  if prompt_yes_no "Enable player-to-player damage" "y"; then pairs+=("bEnablePlayerToPlayerDamage=True"); else pairs+=("bEnablePlayerToPlayerDamage=False"); fi
  if prompt_yes_no "Enable friendly fire" "n"; then pairs+=("bEnableFriendlyFire=True"); else pairs+=("bEnableFriendlyFire=False"); fi
  if prompt_yes_no "Allow defense/damage against other guild bases/players" "y"; then pairs+=("bEnableDefenseOtherGuildPlayer=True"); else pairs+=("bEnableDefenseOtherGuildPlayer=False"); fi
  if prompt_yes_no "Allow other guilds to pick up death drops" "y"; then pairs+=("bCanPickupOtherGuildDeathPenaltyDrop=True"); else pairs+=("bCanPickupOtherGuildDeathPenaltyDrop=False"); fi
  if prompt_yes_no "Keep players present after logout" "y"; then pairs+=("bExistPlayerAfterLogout=True"); else pairs+=("bExistPlayerAfterLogout=False"); fi
  if prompt_yes_no "Disable health stat enhancement for PvP fairness" "y"; then pairs+=("bAllowEnhanceStat_Health=False"); else pairs+=("bAllowEnhanceStat_Health=True"); fi
  if prompt_yes_no "Disable attack stat enhancement for PvP fairness" "y"; then pairs+=("bAllowEnhanceStat_Attack=False"); else pairs+=("bAllowEnhanceStat_Attack=True"); fi
  set_settings_assoc "${pairs[@]}"
  warn "Restart the server for settings to take effect."
}

menu_guided_server_identity() {
  local pairs=()
  local value
  value="$(prompt_text "Server name" "$(get_setting ServerName || true)")"; [[ -n "$value" ]] && pairs+=("ServerName=$value")
  value="$(prompt_text "Server description" "$(get_setting ServerDescription || true)")"; [[ -n "$value" ]] && pairs+=("ServerDescription=$value")
  value="$(prompt_text "Join password, blank keeps current/none" "")"; [[ -n "$value" ]] && pairs+=("ServerPassword=$value")
  value="$(prompt_text "Admin password, blank keeps current" "")"; [[ -n "$value" ]] && pairs+=("AdminPassword=$value")
  value="$(prompt_text "Max players" "$(get_setting ServerPlayerMaxNum || printf '32')")"; [[ -n "$value" ]] && pairs+=("ServerPlayerMaxNum=$value")
  if prompt_yes_no "Show player list" "y"; then pairs+=("bShowPlayerList=True"); else pairs+=("bShowPlayerList=False"); fi
  if [[ ${#pairs[@]} -gt 0 ]]; then
    set_settings_assoc "${pairs[@]}"
    warn "Restart the server for settings to take effect."
  fi
}

menu_guided_settings() {
  while true; do
    menu_header
    cat <<'EOF'
Guided Settings

1) Gameplay rates: XP, capture, drops, eggs
2) Survival/combat rules: death, hunger, damage
3) Bases/guilds/world cleanup
4) PvP rule switches
5) Server identity and access
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) menu_guided_gameplay_rates; pause_menu ;;
      2) menu_guided_survival_rules; pause_menu ;;
      3) menu_guided_world_base_rules; pause_menu ;;
      4) menu_guided_pvp_rules; pause_menu ;;
      5) menu_guided_server_identity; pause_menu ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

configure_firewall() {
  require_root
  if have ufw; then
    ufw allow "${GAME_PORT}/udp" comment 'Palworld dedicated server'
    ok "Allowed UDP $GAME_PORT through UFW."
  else
    warn "ufw is not installed. Install ufw or open UDP $GAME_PORT in your cloud firewall."
  fi
  warn "Also open UDP $GAME_PORT in your cloud provider/security group/router."
  warn "Keep TCP $REST_PORT REST API and TCP $RCON_PORT RCON private."
}

show_ports() {
  local public_ip="unknown"
  if have curl; then
    public_ip="$(curl -fsS --max-time 5 https://api.ipify.org || true)"
    [[ -n "$public_ip" ]] || public_ip="unknown"
  fi
  cat <<EOF
Required for public Palworld:
  UDP $GAME_PORT -> this Ubuntu server

Direct connect:
  ${public_ip}:$GAME_PORT

System firewall:
  sudo bash palworld-manager.sh firewall

Cloud/router firewall:
  Open UDP $GAME_PORT.

Keep private:
  TCP $REST_PORT REST API
  TCP $RCON_PORT RCON
EOF
}

public_ip() {
  if have curl; then
    curl -fsS --max-time 5 https://api.ipify.org || true
  fi
}

show_udp_listener() {
  local found="false"
  echo "Local UDP listener check:"
  if have ss; then
    if ss -lunp 2>/dev/null | grep -E "[:.]${GAME_PORT}[[:space:]]" >/tmp/palworld-udp-listener.$$ 2>/dev/null; then
      cat /tmp/palworld-udp-listener.$$
      found="true"
    fi
    rm -f /tmp/palworld-udp-listener.$$ 2>/dev/null || true
  elif have netstat; then
    if netstat -lunp 2>/dev/null | grep -E "[:.]${GAME_PORT}[[:space:]]" >/tmp/palworld-udp-listener.$$ 2>/dev/null; then
      cat /tmp/palworld-udp-listener.$$
      found="true"
    fi
    rm -f /tmp/palworld-udp-listener.$$ 2>/dev/null || true
  else
    warn "Neither ss nor netstat is available, so local UDP listener cannot be checked."
    return
  fi
  if [[ "$found" == "true" ]]; then
    ok "Something is listening locally on UDP $GAME_PORT."
  else
    warn "No local UDP listener found on $GAME_PORT. The service may still be starting or bound unexpectedly."
  fi
}

show_firewall_state() {
  echo
  echo "Ubuntu firewall check:"
  if have ufw; then
    ufw status verbose || true
  else
    warn "ufw is not installed."
  fi
}

connection_checklist() {
  load_state
  local ip
  ip="$(public_ip)"
  [[ -n "$ip" ]] || ip="<your-public-ip>"
  echo "Palworld connection checklist"
  echo
  echo "Server process:"
  if server_service_active; then
    ok "$SERVICE_NAME is active."
  else
    warn "$SERVICE_NAME is not active. Start the server first."
  fi
  echo
  show_udp_listener
  show_firewall_state
  echo
  echo "Direct connect from Palworld:"
  echo "  ${ip}:${GAME_PORT}"
  echo
  echo "Also required outside Ubuntu:"
  echo "  Open UDP $GAME_PORT in your VPS/cloud provider firewall or router/NAT."
  echo
  echo "If direct connect still times out while the service is active:"
  echo "  1. Confirm you are using the server public IPv4, not 127.0.0.1 or a private 10.x/172.16.x/192.168.x IP."
  echo "  2. Confirm UDP $GAME_PORT is allowed in the cloud security group/provider firewall."
  echo "  3. Confirm Ubuntu UFW allows UDP $GAME_PORT."
  echo "  4. Wait 60-120 seconds after server start, then try direct connect again."
}

schedule_backup() {
  require_root
  cat >"$(backup_service_file)" <<EOF
[Unit]
Description=Palworld save backup

[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath "$0") backup --install-dir $INSTALL_DIR --backup-dir $BACKUP_DIR --user $SERVER_USER --keep $BACKUP_KEEP
EOF
  cat >"$(backup_timer_file)" <<EOF
[Unit]
Description=Run Palworld save backup periodically

[Timer]
OnBootSec=10min
OnUnitActiveSec=${BACKUP_EVERY_MINUTES}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}.timer"
  ok "Scheduled backups every $BACKUP_EVERY_MINUTES minutes."
}

unschedule_backup() {
  require_root
  systemctl disable --now "${TIMER_NAME}.timer" 2>/dev/null || true
  rm -f "$(backup_service_file)" "$(backup_timer_file)"
  systemctl daemon-reload
  ok "Removed scheduled backup timer."
}

announce_now() {
  local body
  body="$(jq -nc --arg msg "$MESSAGE" '{message:$msg}')"
  api_call POST announce "$body"
}

schedule_announcement() {
  require_root
  local msg
  msg="${ANNOUNCE_MESSAGE//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  msg="${msg//%/%%}"
  cat >"$(announce_service_file)" <<EOF
[Unit]
Description=Palworld automatic announcement

[Service]
Type=oneshot
ExecStart=/bin/bash $(realpath "$0") announce --install-dir $INSTALL_DIR --user $SERVER_USER --message "$msg"
EOF
  cat >"$(announce_timer_file)" <<EOF
[Unit]
Description=Run Palworld automatic announcement periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${ANNOUNCE_EVERY_MINUTES}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  save_state
  systemctl daemon-reload
  systemctl enable --now "${ANNOUNCE_TIMER_NAME}.timer"
  ok "Scheduled announcements every $ANNOUNCE_EVERY_MINUTES minutes."
}

unschedule_announcement() {
  require_root
  systemctl disable --now "${ANNOUNCE_TIMER_NAME}.timer" 2>/dev/null || true
  rm -f "$(announce_service_file)" "$(announce_timer_file)"
  systemctl daemon-reload
  ok "Removed automatic announcement timer."
}

announcement_status() {
  if have systemctl && systemctl list-unit-files "${ANNOUNCE_TIMER_NAME}.timer" >/dev/null 2>&1; then
    systemctl --no-pager status "${ANNOUNCE_TIMER_NAME}.timer" || true
  else
    warn "Automatic announcement timer is not installed."
  fi
  echo "Message: $ANNOUNCE_MESSAGE"
  echo "Interval: every $ANNOUNCE_EVERY_MINUTES minutes"
}

configure_mods() {
  local disable="false"
  local workshop=""
  local packages=()
  while [[ ${#POSITIONAL[@]} -gt 0 ]]; do
    case "${POSITIONAL[0]}" in
      --disable-mods) disable="true"; POSITIONAL=("${POSITIONAL[@]:1}") ;;
      --workshop-root-dir) workshop="${POSITIONAL[1]:-}"; POSITIONAL=("${POSITIONAL[@]:2}") ;;
      *) packages+=("${POSITIONAL[0]}"); POSITIONAL=("${POSITIONAL[@]:1}") ;;
    esac
  done
  mkdir -p "$(dirname "$(mods_file)")"
  {
    echo "[PalModSettings]"
    if [[ "$disable" == "true" || ${#packages[@]} -eq 0 ]]; then
      echo "bGlobalEnableMod=false"
    else
      echo "bGlobalEnableMod=true"
      for pkg in "${packages[@]}"; do
        echo "ActiveModList=$pkg"
      done
    fi
    [[ -n "$workshop" ]] && echo "WorkshopRootDir=$workshop"
  } >"$(mods_file)"
  [[ "$ROOTLESS" != "true" ]] && chown -R "$SERVER_USER:$SERVER_GROUP" "$(dirname "$(mods_file)")" || true
  ok "Wrote mod settings: $(mods_file)"
  warn "Restart the server to deploy mod changes."
}

update_server() {
  [[ "$NO_BACKUP" == "true" ]] || backup "pre-update-$(date +%Y%m%d-%H%M%S)" || true
  if have systemctl && systemctl is-active --quiet "$SERVICE_NAME"; then
    stop_server || [[ "$FORCE" == "true" ]]
  fi
  steam_update
  write_systemd_service
  ok "Update complete."
}

logs() {
  if have journalctl && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    journalctl -u "$SERVICE_NAME" -n 160 --no-pager
  else
    local log_dir
    log_dir="$(server_dir)/Pal/Saved/Logs"
    [[ -d "$log_dir" ]] || fail "No logs directory yet: $log_dir"
    tail -n 160 "$log_dir"/* 2>/dev/null || true
  fi
}

tail_logs() {
  if have journalctl && systemctl list-unit-files "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    journalctl -u "$SERVICE_NAME" -f
  else
    logs
  fi
}

write_web_panel_env() {
  require_root
  local env_file pal_pass detected_ip public_url web_pass session_secret old_web_pass old_session_secret game_host ms_client_id ms_client_secret ms_tenant
  env_file="$(web_panel_dir)/.env"
  pal_pass="$(api_password)"
  detected_ip="${PUBLIC_IP:-}"
  [[ -n "$detected_ip" ]] || detected_ip="$(public_ip || true)"
  public_url="$WEB_PANEL_PUBLIC_URL"
  [[ -z "$public_url" && -n "$WEB_PANEL_DOMAIN" ]] && public_url="https://$WEB_PANEL_DOMAIN"
  [[ -n "$public_url" ]] || public_url="http://${detected_ip:-YOUR_SERVER_IP}:$WEB_PANEL_PORT"
  game_host="$GAME_CONNECT_HOST"
  [[ -z "$game_host" && -n "$WEB_PANEL_DOMAIN" ]] && game_host="$WEB_PANEL_DOMAIN"
  [[ -n "$game_host" ]] || game_host="${detected_ip:-$PUBLIC_IP}"
  web_pass="$WEB_ADMIN_PASSWORD"
  if [[ -z "$web_pass" && -f "$env_file" ]]; then
    old_web_pass="$(grep -m1 '^WEB_ADMIN_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
    web_pass="$old_web_pass"
  fi
  [[ -n "$web_pass" ]] || web_pass="$(random_password)"
  old_session_secret=""
  if [[ -f "$env_file" ]]; then
    old_session_secret="$(grep -m1 '^SESSION_SECRET=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
  fi
  session_secret="${old_session_secret:-$(random_password)$(random_password)}"
  ms_client_id="$MICROSOFT_CLIENT_ID"
  ms_client_secret="$MICROSOFT_CLIENT_SECRET"
  ms_tenant="${MICROSOFT_TENANT:-consumers}"
  if [[ -f "$env_file" ]]; then
    [[ -n "$ms_client_id" ]] || ms_client_id="$(grep -m1 '^MICROSOFT_CLIENT_ID=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
    [[ -n "$ms_client_secret" ]] || ms_client_secret="$(grep -m1 '^MICROSOFT_CLIENT_SECRET=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
    [[ "$ms_tenant" != "consumers" ]] || ms_tenant="$(grep -m1 '^MICROSOFT_TENANT=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
    ms_tenant="${ms_tenant:-consumers}"
  fi

  cat >"$env_file" <<EOF
NODE_ENV=production
WEB_PANEL_HOST=$WEB_PANEL_HOST
WEB_PANEL_PORT=$WEB_PANEL_PORT
WEB_PANEL_PUBLIC_URL=$public_url
WEB_ADMIN_USER=$WEB_ADMIN_USER
WEB_ADMIN_PASSWORD=$web_pass
SESSION_SECRET=$session_secret
ALLOW_REGISTRATION=true
PALWORLD_REST_URL=http://127.0.0.1:$REST_PORT
PALWORLD_REST_USER=$API_USER
PALWORLD_ADMIN_PASSWORD=$pal_pass
PUBLIC_GAME_HOST=$game_host
PUBLIC_GAME_IP=$game_host
PUBLIC_GAME_PORT=${PUBLIC_PORT:-$GAME_PORT}
DISCORD_GUILD_ID=$DISCORD_GUILD_ID
DISCORD_INVITE_URL=$DISCORD_INVITE_URL
STEAM_AUTH_ENABLED=true
MICROSOFT_CLIENT_ID=$ms_client_id
MICROSOFT_CLIENT_SECRET=$ms_client_secret
MICROSOFT_TENANT=$ms_tenant
PALWORLD_CONTROL=$(web_panel_dir)/bin/palctl
PANEL_DATA_DIR=$(web_panel_dir)/data
EOF
  chmod 0600 "$env_file"
  chown "$WEB_PANEL_USER:$WEB_PANEL_USER" "$env_file"
  ok "Web panel admin login: $WEB_ADMIN_USER"
  ok "Web panel admin password: $web_pass"
  warn "Save that password now. It is also stored in $(web_panel_dir)/.env."
}

write_web_panel_service() {
  require_root
  cat >"$(web_panel_service_file)" <<EOF
[Unit]
Description=Neo Palworld Web Panel
Wants=network-online.target
After=network-online.target $SERVICE_NAME.service

[Service]
Type=simple
User=$WEB_PANEL_USER
Group=$WEB_PANEL_USER
WorkingDirectory=$(web_panel_dir)
EnvironmentFile=$(web_panel_dir)/.env
ExecStart=/usr/bin/node $(web_panel_dir)/server.mjs
Restart=on-failure
RestartSec=5
# The panel uses a narrow sudoers rule for palctl so owner actions can call
# systemd and the manager script. Enabling NoNewPrivileges blocks sudo.
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$WEB_PANEL_SERVICE_NAME"
}

install_web_panel() {
  require_root
  local src dst node_major sudoers
  src="$(web_panel_src_dir)"
  dst="$(web_panel_dir)"
  [[ -d "$src" ]] || fail "Web panel source folder not found: $src"

  apt_get_update
  apt_get_install nodejs sudo
  have node || fail "nodejs install failed."
  node_major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ "$node_major" -lt 18 ]]; then
    fail "Node.js v18+ is required for the web panel. Current: $(node -v)"
  fi

  if ! id "$WEB_PANEL_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$dst" --shell /usr/sbin/nologin "$WEB_PANEL_USER"
  fi
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  install -m 0755 "$SCRIPT_PATH" "$INSTALL_DIR/palworld-manager.sh"
  chmod 0755 "$dst/bin/palctl"
  chown -R "$WEB_PANEL_USER:$WEB_PANEL_USER" "$dst"
  chown root:root "$dst/bin/palctl"
  chmod 0755 "$dst/bin/palctl"

  sudoers="/etc/sudoers.d/palworld-web-panel"
  cat >"$sudoers" <<EOF
$WEB_PANEL_USER ALL=(root) NOPASSWD: $dst/bin/palctl *
EOF
  chmod 0440 "$sudoers"
  visudo -cf "$sudoers" >/dev/null

  write_web_panel_env
  write_web_panel_service
  systemctl restart "$WEB_PANEL_SERVICE_NAME"
  sleep 2
  if systemctl is-active --quiet "$WEB_PANEL_SERVICE_NAME"; then
    ok "Web panel is running."
  else
    warn "Web panel did not stay running. Recent logs:"
    journalctl -u "$WEB_PANEL_SERVICE_NAME" -n 80 --no-pager || true
  fi
  save_state
  warn "Open TCP $WEB_PANEL_PORT in your provider firewall/router if you want the website public."
}

web_panel_status() {
  load_state
  local url
  url="$WEB_PANEL_PUBLIC_URL"
  [[ -z "$url" && -n "$WEB_PANEL_DOMAIN" ]] && url="https://$WEB_PANEL_DOMAIN"
  [[ -n "$url" ]] || url="http://YOUR_SERVER_IP:$WEB_PANEL_PORT"
  echo "Web panel dir: $(web_panel_dir)"
  echo "Web panel URL: $url"
  echo "Service:       $WEB_PANEL_SERVICE_NAME"
  if have systemctl && systemctl list-unit-files "${WEB_PANEL_SERVICE_NAME}.service" >/dev/null 2>&1; then
    systemctl --no-pager --full status "$WEB_PANEL_SERVICE_NAME" || true
  else
    warn "Web panel service is not installed yet."
  fi
}

web_panel_logs() {
  require_root
  journalctl -u "$WEB_PANEL_SERVICE_NAME" -n 160 --no-pager || true
}

reset_web_admin_password() {
  require_root
  [[ -d "$(web_panel_dir)" ]] || fail "Web panel is not installed yet."
  WEB_ADMIN_PASSWORD="$(prompt_text "New admin password, blank to generate one" "")"
  [[ -n "$WEB_ADMIN_PASSWORD" ]] || WEB_ADMIN_PASSWORD="$(random_password)"
  write_web_panel_env
  systemctl restart "$WEB_PANEL_SERVICE_NAME"
  ok "Web admin password has been reset."
  warn "Admin login URL: ${WEB_PANEL_PUBLIC_URL:-https://${WEB_PANEL_DOMAIN:-YOUR_DOMAIN}}/admin"
}

install_caddy_package() {
  require_root
  if have caddy; then
    ok "Caddy is already installed: $(command -v caddy)"
    return
  fi
  apt_get_update
  apt_get_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  install -d -m 0755 /usr/share/keyrings
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt_get_update
  apt_get_install caddy
}

write_caddyfile() {
  require_root
  [[ -n "$WEB_PANEL_DOMAIN" ]] || fail "A real domain is required for public HTTPS on 443."
  [[ "$WEB_PANEL_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Domain contains invalid characters: $WEB_PANEL_DOMAIN"
  local global_block=""
  if [[ -n "$WEB_PANEL_TLS_EMAIL" ]]; then
    global_block="{
	email $WEB_PANEL_TLS_EMAIL
}

"
  fi
  if [[ -f "$(caddyfile)" ]]; then
    cp -a "$(caddyfile)" "$(caddyfile).bak.$(date +%Y%m%d-%H%M%S)"
  fi
  cat >"$(caddyfile)" <<EOF
${global_block}$WEB_PANEL_DOMAIN {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
	}

	reverse_proxy 127.0.0.1:$WEB_PANEL_PORT
}
EOF
  caddy validate --config "$(caddyfile)"
}

configure_web_panel_https() {
  require_root
  local detected_ip
  [[ -n "$WEB_PANEL_DOMAIN" ]] || fail "Set Web panel -> Change web panel settings -> Domain first."
  detected_ip="$(public_ip || true)"
  echo "HTTPS domain: $WEB_PANEL_DOMAIN"
  echo "Detected server public IP: ${detected_ip:-unknown}"
  warn "Before continuing, point your domain DNS A/AAAA record to this server."
  warn "Caddy needs public TCP 80 and 443 open for automatic HTTPS certificates."
  if ! prompt_yes_no "Continue with Caddy HTTPS setup" "y"; then
    warn "Caddy HTTPS setup cancelled."
    return
  fi

  if [[ ! -f "$(web_panel_dir)/server.mjs" ]]; then
    warn "Web panel is not installed yet; installing it first."
    install_web_panel
  fi
  install_caddy_package
  WEB_PANEL_HOST="127.0.0.1"
  WEB_PANEL_PUBLIC_URL="https://$WEB_PANEL_DOMAIN"
  write_web_panel_env
  write_web_panel_service
  systemctl restart "$WEB_PANEL_SERVICE_NAME"
  write_caddyfile
  systemctl enable caddy
  systemctl reload caddy || systemctl restart caddy
  if have ufw; then
    ufw allow 80/tcp comment 'Caddy HTTP challenge and redirect'
    ufw allow 443/tcp comment 'Caddy HTTPS web panel'
  fi
  save_state
  ok "HTTPS web panel configured: https://$WEB_PANEL_DOMAIN"
  warn "Keep Palworld REST private. Do not forward TCP $REST_PORT."
}

caddy_status() {
  if have systemctl && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
    echo "Caddyfile: $(caddyfile)"
    systemctl --no-pager --full status caddy || true
    echo
    caddy validate --config "$(caddyfile)" || true
  else
    warn "Caddy is not installed yet."
  fi
}

caddy_logs() {
  require_root
  journalctl -u caddy -n 160 --no-pager || true
}

doctor() {
  echo "Palworld Ubuntu server doctor"
  echo "Install dir: $INSTALL_DIR"
  echo "Server dir:  $(server_dir)"
  echo "Config:      $(settings_file)"
  have curl && ok "curl available" || warn "curl missing"
  have jq && ok "jq available" || warn "jq missing"
  have python3 && ok "python3 available" || warn "python3 missing"
  have steamcmd && ok "steamcmd package available" || warn "steamcmd not in PATH; manual SteamCMD will be used"
  [[ -x "$(server_dir)/PalServer.sh" ]] && ok "PalServer.sh exists" || warn "PalServer.sh missing; run install"
  [[ -f "$(settings_file)" ]] && ok "PalWorldSettings.ini exists" || warn "Settings file missing; run install"
  echo
  echo "Steam content network check:"
  if have curl; then
    if test_url_family -4 "https://cache2-den-iwst.steamcontent.com"; then
      ok "Steam content over IPv4 works."
    else
      warn "Steam content over IPv4 failed."
    fi
    if test_url_family -6 "https://cache2-den-iwst.steamcontent.com"; then
      ok "Steam content over IPv6 works."
    else
      warn "Steam content over IPv6 failed or is unavailable."
    fi
    echo "SteamCMD download mode: $STEAM_FORCE_IPV4"
  else
    warn "curl missing; cannot test Steam content network."
  fi
  if have free; then free -h; fi
  if have df; then df -h "$INSTALL_DIR" 2>/dev/null || df -h .; fi
  show_ports
}

menu_header() {
  load_state
  clear_screen
  cat <<EOF
Neo Palworld Ubuntu Server Manager

Install dir: $INSTALL_DIR
Server dir:  $(server_dir)
Backups:     $BACKUP_DIR
Game port:   UDP $GAME_PORT
REST port:   TCP $REST_PORT local/LAN only

EOF
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "You are not running as root. Most server actions need: sudo bash palworld-manager.sh"
    echo
  fi
}

menu_install() {
  menu_header
  echo "Install / initial setup"
  echo
  INSTALL_DIR="$(prompt_text "Install directory" "$INSTALL_DIR")"
  BACKUP_DIR="$(prompt_text "Backup directory" "$BACKUP_DIR")"
  SERVER_USER="$(prompt_text "Linux server user" "$SERVER_USER")"
  SERVER_GROUP="$SERVER_USER"
  SERVER_NAME="$(prompt_text "Server name" "${SERVER_NAME:-Neo Palworld}")"
  SERVER_DESCRIPTION="$(prompt_text "Server description" "$SERVER_DESCRIPTION")"
  GAME_PORT="$(prompt_text "Game UDP port" "$GAME_PORT")"
  MAX_PLAYERS="$(prompt_text "Max players" "$MAX_PLAYERS")"
  REST_PORT="$(prompt_text "REST API port, keep private" "$REST_PORT")"
  if prompt_yes_no "Show in Palworld community/public lobby" "y"; then
    PUBLIC_LOBBY="true"
  else
    PUBLIC_LOBBY="false"
  fi
  PUBLIC_IP="$(prompt_text "Public IP override, blank for none" "$PUBLIC_IP")"
  PUBLIC_PORT="$(prompt_text "Public port override, blank for game port" "$PUBLIC_PORT")"
  SERVER_PASSWORD="$(prompt_text "Join password, blank for public/no password" "$SERVER_PASSWORD")"
  ADMIN_PASSWORD="$(prompt_text "Admin password, blank to auto-generate" "$ADMIN_PASSWORD")"
  if prompt_yes_no "Enable deprecated RCON" "n"; then
    ENABLE_RCON="true"
  else
    ENABLE_RCON="false"
  fi
  if prompt_yes_no "Use older performance launch args" "n"; then
    USE_PERF_ARGS="true"
    WORKER_THREADS="$(prompt_text "Worker threads, blank for default" "$WORKER_THREADS")"
  else
    USE_PERF_ARGS="false"
    WORKER_THREADS=""
  fi
  if prompt_yes_no "Auto-fix broken IPv6 Steam downloads" "y"; then
    STEAM_FORCE_IPV4="auto"
  else
    STEAM_FORCE_IPV4="false"
  fi
  echo
  warn "Install will apt install dependencies, download SteamCMD/server files, and create a systemd service."
  if prompt_yes_no "Continue with install" "y"; then
    install_server
    if [[ "$ROOTLESS" != "true" ]] && prompt_yes_no "Start the Palworld server now" "y"; then
      start_server || true
      status_server
    fi
  else
    warn "Install cancelled."
  fi
  pause_menu
}

menu_service() {
  while true; do
    menu_header
    cat <<'EOF'
Service Control

1) Start server
2) Stop server gracefully
3) Force stop server
4) Restart server
5) Restart with 60-second in-game warning
6) Status
7) Logs
8) Live log tail
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) start_server; pause_menu ;;
      2) FORCE="false"; stop_server; pause_menu ;;
      3) FORCE="true"; stop_server; FORCE="false"; pause_menu ;;
      4) restart_server; pause_menu ;;
      5)
        SHUTDOWN_WAIT="60"
        MESSAGE="$(prompt_text "Restart countdown message" "Server restart in 60 seconds. Please find a safe spot.")"
        restart_server
        SHUTDOWN_WAIT="30"
        MESSAGE="Server maintenance"
        pause_menu
        ;;
      6)
        status_server
        if ! server_service_active && prompt_yes_no "Start the Palworld server now" "y"; then
          start_server || true
          status_server
        fi
        pause_menu
        ;;
      7) logs; pause_menu ;;
      8) tail_logs ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_update() {
  menu_header
  echo "Update server files"
  echo
  if prompt_yes_no "Create a backup before updating" "y"; then
    NO_BACKUP="false"
  else
    NO_BACKUP="true"
  fi
  if prompt_yes_no "Force stop if graceful shutdown hangs" "n"; then
    FORCE="true"
  else
    FORCE="false"
  fi
  update_server
  FORCE="false"
  NO_BACKUP="false"
  pause_menu
}

menu_backups() {
  while true; do
    menu_header
    cat <<'EOF'
Backups

1) Create backup now
2) List backups
3) Restore newest backup
4) Restore specific backup path
5) Schedule automatic backups
6) Remove automatic backup schedule
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1)
        local name
        name="$(prompt_text "Backup name, blank for timestamp" "")"
        backup "$name"
        pause_menu
        ;;
      2)
        list_backups
        pause_menu
        ;;
      3)
        FORCE="true"
        POSITIONAL=()
        restore_backup
        FORCE="false"
        pause_menu
        ;;
      4)
        local path
        path="$(prompt_text "Backup archive path" "")"
        if [[ -n "$path" ]]; then
          FORCE="true"
          POSITIONAL=("$path")
          restore_backup
          POSITIONAL=()
          FORCE="false"
        fi
        pause_menu
        ;;
      5)
        BACKUP_EVERY_MINUTES="$(prompt_text "Backup interval in minutes" "$BACKUP_EVERY_MINUTES")"
        BACKUP_KEEP="$(prompt_text "Number of backups to keep" "$BACKUP_KEEP")"
        schedule_backup
        pause_menu
        ;;
      6)
        unschedule_backup
        pause_menu
        ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_settings() {
  while true; do
    menu_header
    cat <<'EOF'
Settings

1) Show current PalWorldSettings.ini values
2) Edit common settings
3) Set custom Key=Value pairs
4) Apply preset
5) Guided advanced settings
6) Check WorldOption/WorldOptions.sav setting overrides
7) Disable WorldOption/WorldOptions.sav overrides
8) Enable Global Palbox safely
9) Enable fast travel safely
10) Settings diagnostics
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1)
        show_settings
        pause_menu
        ;;
      2)
        local pairs=()
        local value
        value="$(prompt_text "Server name, blank skip" "")"; [[ -n "$value" ]] && pairs+=("ServerName=$value")
        value="$(prompt_text "Server description, blank skip" "")"; [[ -n "$value" ]] && pairs+=("ServerDescription=$value")
        value="$(prompt_text "Join password, blank skip" "")"; [[ -n "$value" ]] && pairs+=("ServerPassword=$value")
        value="$(prompt_text "Admin password, blank skip" "")"; [[ -n "$value" ]] && pairs+=("AdminPassword=$value")
        value="$(prompt_text "Max players, blank skip" "")"; [[ -n "$value" ]] && pairs+=("ServerPlayerMaxNum=$value")
        value="$(prompt_text "EXP rate, blank skip" "")"; [[ -n "$value" ]] && pairs+=("ExpRate=$value")
        value="$(prompt_text "Capture rate, blank skip" "")"; [[ -n "$value" ]] && pairs+=("PalCaptureRate=$value")
        value="$(prompt_text "Gather/drop rate, blank skip" "")"; [[ -n "$value" ]] && pairs+=("CollectionDropRate=$value")
        value="$(prompt_text "Egg hatch time, blank skip" "")"; [[ -n "$value" ]] && pairs+=("PalEggDefaultHatchingTime=$value")
        if [[ ${#pairs[@]} -gt 0 ]]; then
          set_settings_assoc "${pairs[@]}"
          warn "Restart the server for most settings to take effect."
        else
          warn "No settings changed."
        fi
        pause_menu
        ;;
      3)
        echo "Enter Key=Value pairs separated by spaces."
        echo "Example: ExpRate=1.5 PalCaptureRate=1.2 DeathPenalty=Item"
        printf 'Pairs: '
        read -r line || true
        if [[ -n "$line" ]]; then
          local -a custom_pairs=()
          read -r -a custom_pairs <<<"$line"
          set_settings_assoc "${custom_pairs[@]}"
          warn "Restart the server for most settings to take effect."
        fi
        pause_menu
        ;;
      4)
        echo "Presets: launch-public, balanced, casual, pve, boosted, builder, breeding, event-weekend, performance, pvp, raid, no-raids, hardcore"
        local preset
        preset="$(prompt_text "Preset" "casual")"
        POSITIONAL=("$preset")
        apply_preset
        POSITIONAL=()
        warn "Restart the server for most settings to take effect."
        pause_menu
        ;;
      5)
        menu_guided_settings
        ;;
      6)
        worldoption_status
        pause_menu
        ;;
      7)
        disable_worldoption_overrides
        pause_menu
        ;;
      8)
        enable_global_palbox_safely
        pause_menu
        ;;
      9)
        enable_fast_travel_safely
        pause_menu
        ;;
      10)
        settings_diagnostics
        pause_menu
        ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_network() {
  while true; do
    menu_header
    cat <<'EOF'
Network / Firewall

1) Show port and public IP advice
2) Add UFW rule for Palworld UDP port
3) Change remembered launch ports
4) Change SteamCMD IPv4/IPv6 download mode
5) Connection checklist / direct-connect info
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) show_ports; pause_menu ;;
      2) configure_firewall; pause_menu ;;
      3)
        GAME_PORT="$(prompt_text "Game UDP port" "$GAME_PORT")"
        REST_PORT="$(prompt_text "REST API port, keep private" "$REST_PORT")"
        RCON_PORT="$(prompt_text "RCON port, keep private" "$RCON_PORT")"
        PUBLIC_PORT="$(prompt_text "Public port override, blank for game port" "$PUBLIC_PORT")"
        save_state
        write_systemd_service
        warn "Restart the server after changing launch ports."
        pause_menu
        ;;
      4)
        echo "Current SteamCMD download mode: $STEAM_FORCE_IPV4"
        echo "auto  = detect broken Steam IPv6 and temporarily force IPv4"
        echo "true  = always temporarily disable IPv6 during SteamCMD downloads"
        echo "false = never change IPv6 for SteamCMD"
        STEAM_FORCE_IPV4="$(prompt_text "Mode: auto, true, or false" "$STEAM_FORCE_IPV4")"
        case "$STEAM_FORCE_IPV4" in
          auto|true|false) save_state ;;
          *) warn "Invalid mode; keeping auto."; STEAM_FORCE_IPV4="auto"; save_state ;;
        esac
        pause_menu
        ;;
      5) connection_checklist; pause_menu ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_api() {
  while true; do
    menu_header
    cat <<'EOF'
REST API Tools

1) Server info
2) Player list
3) Metrics
4) Announce message
5) Save world
6) Graceful shutdown countdown
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) api_call GET info; pause_menu ;;
      2) api_call GET players; pause_menu ;;
      3) api_call GET metrics; pause_menu ;;
      4)
        MESSAGE="$(prompt_text "Announcement message" "Restart in 5 minutes")"
        api_call POST announce "$(jq -nc --arg msg "$MESSAGE" '{message:$msg}')"
        pause_menu
        ;;
      5) save_world; pause_menu ;;
      6)
        SHUTDOWN_WAIT="$(prompt_text "Shutdown wait seconds" "$SHUTDOWN_WAIT")"
        MESSAGE="$(prompt_text "Shutdown message" "$MESSAGE")"
        shutdown_api
        pause_menu
        ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_fun_tools() {
  while true; do
    menu_header
    cat <<'EOF'
Server Extras / Fun Tools

1) Send announcement now
2) Schedule repeating announcement
3) Stop repeating announcement
4) Announcement timer status
5) Show vanilla UI/logo limitations
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1)
        MESSAGE="$(prompt_text "Announcement text" "$ANNOUNCE_MESSAGE")"
        announce_now
        pause_menu
        ;;
      2)
        ANNOUNCE_MESSAGE="$(prompt_text "Repeating announcement text" "$ANNOUNCE_MESSAGE")"
        ANNOUNCE_EVERY_MINUTES="$(prompt_text "Repeat every N minutes" "$ANNOUNCE_EVERY_MINUTES")"
        schedule_announcement
        pause_menu
        ;;
      3)
        unschedule_announcement
        pause_menu
        ;;
      4)
        announcement_status
        pause_menu
        ;;
      5)
        cat <<'EOF'
Vanilla Ubuntu dedicated server limits:

- You can send announcements, tune server rules, schedule events, manage backups, and use admin/API commands.
- You cannot inject a permanent custom HUD, top-left logo, clickable UI, scoreboard overlay, or custom client-side panels from a vanilla Linux server.
- That kind of UI requires client-side modding/plugin support. Official Palworld docs currently mark server mods as Windows dedicated server support, not Linux dedicated server support.

Good vanilla alternatives:

- Put the brand/server name in ServerName.
- Put rules/Discord/event info in ServerDescription.
- Use repeating announcements for welcome text, event reminders, raid rules, wipe notices, and Discord links.
- Use presets for weekend XP/drop/capture events.
EOF
        pause_menu
        ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_web_panel() {
  while true; do
    menu_header
    cat <<EOF
Web Panel

Website port: TCP $WEB_PANEL_PORT
Public URL:   ${WEB_PANEL_PUBLIC_URL:-http://YOUR_SERVER_IP:$WEB_PANEL_PORT}
HTTPS domain: ${WEB_PANEL_DOMAIN:-not set}
Game connect: ${GAME_CONNECT_HOST:-${WEB_PANEL_DOMAIN:-auto IP}}
Discord ID:   ${DISCORD_GUILD_ID:-not set}
Xbox login:   $([[ -n "$MICROSOFT_CLIENT_ID" ]] && echo configured || echo not configured)

1) Install / update web panel
2) Start web panel
3) Stop web panel
4) Restart web panel
5) Status
6) Logs
7) Change web panel settings
8) Configure HTTPS 443 with Caddy
9) Caddy status
10) Caddy logs
11) Reset admin password
0) Back

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) install_web_panel; pause_menu ;;
      2) require_root; systemctl start "$WEB_PANEL_SERVICE_NAME"; web_panel_status; pause_menu ;;
      3) require_root; systemctl stop "$WEB_PANEL_SERVICE_NAME"; web_panel_status; pause_menu ;;
      4) require_root; systemctl restart "$WEB_PANEL_SERVICE_NAME"; web_panel_status; pause_menu ;;
      5) web_panel_status; pause_menu ;;
      6) web_panel_logs; pause_menu ;;
      7)
        WEB_PANEL_PORT="$(prompt_text "Web panel TCP port" "$WEB_PANEL_PORT")"
        WEB_PANEL_PUBLIC_URL="$(prompt_text "Public web URL, blank to auto-use IP:port" "$WEB_PANEL_PUBLIC_URL")"
        WEB_PANEL_DOMAIN="$(prompt_text "HTTPS domain, example panel.example.com" "$WEB_PANEL_DOMAIN")"
        WEB_PANEL_TLS_EMAIL="$(prompt_text "TLS email for Caddy/Let's Encrypt notices, optional" "$WEB_PANEL_TLS_EMAIL")"
        GAME_CONNECT_HOST="$(prompt_text "Palworld direct-connect host/domain" "${GAME_CONNECT_HOST:-$WEB_PANEL_DOMAIN}")"
        WEB_ADMIN_USER="$(prompt_text "Initial admin username" "$WEB_ADMIN_USER")"
        WEB_ADMIN_PASSWORD="$(prompt_text "Initial admin password, blank to auto-generate on install" "$WEB_ADMIN_PASSWORD")"
        DISCORD_GUILD_ID="$(prompt_text "Discord guild/server ID, blank to disable widget" "$DISCORD_GUILD_ID")"
        DISCORD_INVITE_URL="$(prompt_text "Discord invite URL" "$DISCORD_INVITE_URL")"
        MICROSOFT_CLIENT_ID="$(prompt_text "Microsoft/Xbox OAuth client ID, blank to keep/disable" "$MICROSOFT_CLIENT_ID")"
        MICROSOFT_CLIENT_SECRET="$(prompt_text "Microsoft/Xbox OAuth client secret, blank to keep existing" "$MICROSOFT_CLIENT_SECRET")"
        MICROSOFT_TENANT="$(prompt_text "Microsoft tenant: consumers, common, organizations, or tenant ID" "$MICROSOFT_TENANT")"
        save_state
        warn "Run Install / update web panel after changing these values."
        pause_menu
        ;;
      8) configure_web_panel_https; pause_menu ;;
      9) caddy_status; pause_menu ;;
      10) caddy_logs; pause_menu ;;
      11) reset_web_admin_password; pause_menu ;;
      0) return ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

menu_mods() {
  menu_header
  cat <<'EOF'
Mods

Only server-compatible mods should be enabled. Back up before testing mods.

1) Enable/set active mod package names
2) Disable mods
0) Back

EOF
  printf 'Choose: '
  read -r choice || true
  case "$choice" in
    1)
      local mods workshop
      printf 'Mod package names separated by spaces: '
      read -r mods || true
      workshop="$(prompt_text "Workshop root, blank for default/none" "")"
      local -a mod_array=()
      read -r -a mod_array <<<"$mods"
      if [[ -n "$workshop" ]]; then
        POSITIONAL=("--workshop-root-dir" "$workshop" "${mod_array[@]}")
      else
        POSITIONAL=("${mod_array[@]}")
      fi
      configure_mods
      POSITIONAL=()
      pause_menu
      ;;
    2)
      POSITIONAL=("--disable-mods")
      configure_mods
      POSITIONAL=()
      pause_menu
      ;;
    0) return ;;
    *) warn "Unknown choice."; pause_menu ;;
  esac
}

run_menu() {
  while true; do
    menu_header
    cat <<'EOF'
Main Menu

1) Install / initial setup
2) Start / stop / status / logs
3) Update server
4) Backups and restore
5) Settings and presets
6) Network / firewall / ports
7) REST API tools
8) Server extras / fun tools
9) Web panel
10) Mods
11) Doctor / health check
h) Help
q) Quit

EOF
    printf 'Choose: '
    read -r choice || true
    case "$choice" in
      1) menu_install ;;
      2) menu_service ;;
      3) menu_update ;;
      4) menu_backups ;;
      5) menu_settings ;;
      6) menu_network ;;
      7) menu_api ;;
      8) menu_fun_tools ;;
      9) menu_web_panel ;;
      10) menu_mods ;;
      11) doctor; pause_menu ;;
      h|H) usage; pause_menu ;;
      q|Q|0) exit 0 ;;
      *) warn "Unknown choice."; pause_menu ;;
    esac
  done
}

case "$ACTION" in
  menu) run_menu ;;
  help) usage ;;
  doctor) load_state; doctor ;;
  install) install_server ;;
  update) load_state; update_server ;;
  start) load_state; start_server ;;
  stop) load_state; stop_server ;;
  restart) load_state; restart_server ;;
  status) load_state; status_server ;;
  backup) load_state; backup "${POSITIONAL[0]:-}" ;;
  list-backups) load_state; list_backups ;;
  restore) load_state; restore_backup ;;
  settings) load_state; show_settings ;;
  settings-diagnostics) load_state; settings_diagnostics ;;
  worldoption-status) load_state; worldoption_status ;;
  worldoption-disable) load_state; disable_worldoption_overrides ;;
  global-palbox-enable) load_state; enable_global_palbox_safely ;;
  fast-travel-enable) load_state; enable_fast_travel_safely ;;
  set) load_state; [[ ${#POSITIONAL[@]} -gt 0 ]] || fail "Use: set Key=Value ..."; set_settings_assoc "${POSITIONAL[@]}" ;;
  preset) load_state; apply_preset ;;
  firewall) load_state; configure_firewall ;;
  ports) load_state; show_ports ;;
  api) load_state; api_call "${POSITIONAL[0]:-GET}" "${POSITIONAL[1]:-info}" "${POSITIONAL[2]:-}" ;;
  info) load_state; api_call GET info ;;
  players) load_state; api_call GET players ;;
  metrics) load_state; api_call GET metrics ;;
  announce) load_state; announce_now ;;
  schedule-announcement) load_state; schedule_announcement ;;
  unschedule-announcement) load_state; unschedule_announcement ;;
  announcement-status) load_state; announcement_status ;;
  web-install) load_state; install_web_panel ;;
  web-start) load_state; require_root; systemctl start "$WEB_PANEL_SERVICE_NAME" ;;
  web-stop) load_state; require_root; systemctl stop "$WEB_PANEL_SERVICE_NAME" ;;
  web-restart) load_state; require_root; systemctl restart "$WEB_PANEL_SERVICE_NAME" ;;
  web-status) load_state; web_panel_status ;;
  web-logs) load_state; web_panel_logs ;;
  web-reset-admin) load_state; reset_web_admin_password ;;
  web-https) load_state; configure_web_panel_https ;;
  caddy-status) load_state; caddy_status ;;
  caddy-logs) load_state; caddy_logs ;;
  save) load_state; save_world ;;
  shutdown) load_state; shutdown_api ;;
  mods) load_state; configure_mods ;;
  schedule-backup) load_state; schedule_backup ;;
  unschedule-backup) load_state; unschedule_backup ;;
  logs) load_state; logs ;;
  tail) load_state; tail_logs ;;
  *) usage; fail "Unknown action: $ACTION" ;;
esac
