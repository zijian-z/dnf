#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
DEFAULT_OVERLAY_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/.artifacts"

usage() {
  cat <<'EOF'
用法:
  package_shenji_overlay.sh [overlay目录] [输出目录]

说明:
  1. 默认从 deploy/dnf/docker-compose/shenji_overlay 打包
  2. 默认输出到 .artifacts/
  3. Script.pvf 和 gm/dist/data/data.db 都是可选文件
     - Script.pvf 缺失时，运行时继续走 EXTERNAL_PVF_PATH 外部挂载
     - data.db 缺失时，GM 镜像只打包空 data 目录，首次启动由应用或外部卷接管
EOF
}

require_path() {
  local path="$1"

  [[ -e "$path" ]] || {
    echo "缺少必要路径: $path" >&2
    exit 1
  }
}

copy_any() {
  local src="$1"
  local dst="$2"

  if [[ -d "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    return 0
  fi

  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    return 0
  fi

  return 1
}

main() {
  local overlay_dir="${1:-$DEFAULT_OVERLAY_DIR}"
  local output_dir="${2:-$DEFAULT_OUTPUT_DIR}"
  local tmp_root=""
  local dnf_root
  local gm_root
  local include_pvf="no"
  local include_gm_db="no"
  local dnf_tar="$output_dir/shenji-overlay-dnf.tar.gz"
  local gm_tar="$output_dir/shenji-overlay-gm.tar.gz"
  local summary_file="$output_dir/shenji-overlay-summary.txt"

  if [[ "${overlay_dir:-}" == "-h" || "${overlay_dir:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_path "$overlay_dir/data/dp"
  require_path "$overlay_dir/data/channel"
  require_path "$overlay_dir/data/game"
  require_path "$overlay_dir/data/run"
  require_path "$overlay_dir/data/libfd.so"
  require_path "$overlay_dir/gm/dist/godofgm"
  require_path "$overlay_dir/gm/dist/config/server.json"
  require_path "$overlay_dir/gm/dist/source"
  require_path "$overlay_dir/gm/dist/web"

  mkdir -p "$output_dir"
  rm -f "$dnf_tar" "$gm_tar" "$summary_file"

  tmp_root=$(mktemp -d)
  trap '[[ -n "${tmp_root:-}" ]] && rm -rf "$tmp_root"' EXIT

  dnf_root="$tmp_root/dnf"
  gm_root="$tmp_root/gm"

  mkdir -p "$dnf_root/data" "$dnf_root/optional" "$gm_root/data"

  copy_any "$overlay_dir/data/dp" "$dnf_root/data/dp"
  copy_any "$overlay_dir/data/channel" "$dnf_root/data/channel"
  copy_any "$overlay_dir/data/game" "$dnf_root/data/game"
  copy_any "$overlay_dir/data/run" "$dnf_root/data/run"
  copy_any "$overlay_dir/data/libfd.so" "$dnf_root/data/libfd.so"

  if copy_any "$overlay_dir/data/Script.pvf" "$dnf_root/data/Script.pvf"; then
    include_pvf="yes"
  fi

  if [[ -d "$overlay_dir/meta" ]]; then
    copy_any "$overlay_dir/meta" "$dnf_root/meta"
  fi
  if [[ -f "$overlay_dir/optional/df_game_r.shenji" ]]; then
    copy_any "$overlay_dir/optional/df_game_r.shenji" "$dnf_root/optional/df_game_r.shenji"
  fi

  copy_any "$overlay_dir/gm/dist/config" "$gm_root/config"
  copy_any "$overlay_dir/gm/dist/source" "$gm_root/source"
  copy_any "$overlay_dir/gm/dist/web" "$gm_root/web"
  copy_any "$overlay_dir/gm/dist/godofgm" "$gm_root/godofgm"

  if copy_any "$overlay_dir/gm/dist/data/data.db" "$gm_root/data/data.db"; then
    include_gm_db="yes"
  else
    mkdir -p "$gm_root/data"
  fi

  cat >"$summary_file" <<EOF
Shenji overlay package summary
generated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
overlay_dir=$overlay_dir
dnf_tar=$(basename "$dnf_tar")
gm_tar=$(basename "$gm_tar")
included_script_pvf=$include_pvf
included_gm_data_db=$include_gm_db

Notes:
- included_script_pvf=no 时，运行时请继续通过 EXTERNAL_PVF_PATH 或 shenji_overlay_pvf 外部卷提供 Script.pvf
- included_gm_data_db=no 时，GM 镜像只包含空 data 目录；如需沿用现有账号/权限/日志，请额外挂载或单独分发 data.db
EOF

  (
    cd "$dnf_root"
    tar -czf "$dnf_tar" .
  )
  (
    cd "$gm_root"
    tar -czf "$gm_tar" .
  )

  {
    echo
    sha256sum "$dnf_tar"
    sha256sum "$gm_tar"
  } >>"$summary_file"

  cat "$summary_file"
}

main "$@"
