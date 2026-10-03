#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
if [[ "$current" == "bbr" ]]; then
  echo "BBR уже включён. Пропускаю."
  exit 0
fi

conf="/etc/sysctl.conf"
touch "$conf"

append_if_missing() {
  local line="$1"
  if grep -qxF "$line" "$conf"; then
    return 0
  fi
  printf '%s\n' "$line" >> "$conf"
}

append_if_missing "net.core.default_qdisc=fq"
append_if_missing "net.ipv4.tcp_congestion_control=bbr"

sysctl -p
echo "BBR включён."
