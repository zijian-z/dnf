#!/usr/bin/env bash

set -euo pipefail

overlay_root="${SHENJI_OVERLAY_ROOT:-/opt/shenji-overlay}"

log() {
  echo "[shenji-overlay] $*"
}

copy_tree() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || return 0

  mkdir -p "$dst"
  cp -an "$src"/. "$dst"/
}

install_file_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  [[ -f "$src" ]] || return 0

  if [[ ! -e "$dst" ]]; then
    install -D -m "$mode" "$src" "$dst"
  fi
}

main() {
  if [[ ! -d "$overlay_root" ]]; then
    exit 0
  fi

  if [[ ! -d "$overlay_root/data" ]]; then
    log "overlay root exists but no data directory, skip"
    exit 0
  fi

  log "init missing overlay assets from $overlay_root"

  copy_tree "$overlay_root/data/dp" /data/dp
  copy_tree "$overlay_root/data/game" /data/game
  copy_tree "$overlay_root/data/channel" /data/channel
  copy_tree "$overlay_root/data/run" /data/run

  install_file_if_missing "$overlay_root/data/libfd.so" /data/libfd.so 0755
  install_file_if_missing "$overlay_root/data/Script.pvf" /data/Script.pvf 0644
  install_file_if_missing "$overlay_root/optional/df_game_r.shenji" /data/optional/df_game_r.shenji 0755

  if [[ -d "$overlay_root/meta" ]]; then
    copy_tree "$overlay_root/meta" /data/shenji_overlay_meta
  fi

  log "overlay sync complete"
}

main "$@"
