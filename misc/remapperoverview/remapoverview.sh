#!/usr/bin/env bash
set -eu

# adjust if your UID is different
USER_ID=1000
NIRI_SOCKET=$(find /run/user/$USER_ID/niri* -type s -name '*.sock' -print -quit)

export NIRI_SOCKET

OG_CONF="/etc/keyd/overview-closed.conf"
ON_CONF="/etc/keyd/overview-open.conf"
SYMLINK="/etc/keyd/default.conf"

prev="unknown"
while sleep 0.2; do
  out=$(niri msg overview-state)
  if [[ "$out" =~ Overview\ is\ open ]]; then
    if [[ "$prev" != "open" ]]; then
      ln -fs "$ON_CONF" "$SYMLINK"
      keyd reload
      prev="open"
    fi
  elif [[ "$out" =~ Overview\ is\ closed ]]; then
    if [[ "$prev" != "closed" ]]; then
      ln -fs "$OG_CONF" "$SYMLINK"
      keyd reload
      prev="closed"
    fi
  fi
done
