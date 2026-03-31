#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
DEFAULT_OVERLAY_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/.artifacts"
GM_DIST_PAYLOAD_PATH="payload/gm_dist.tgz"
TMP_ROOT=""

usage() {
  cat <<'EOF'
用法:
  package_shenji_overlay.sh [overlay目录] [输出目录]

说明:
  1. 默认从 deploy/dnf/docker-compose/shenji_overlay 打包
  2. 默认输出到 .artifacts/
  3. DNF 主服务现在打包的是 rootfs overlay，而不是旧的 data 目录快照
  4. Script.pvf 和 gm/dist/data/data.db 是否内置到镜像取决于当前打包输入
     - Script.pvf 是运行所需文件，打包时缺失则部署时需要自行准备 ./data/Script.pvf
     - data.db 是 GodOfGM 运行所需文件，打包时缺失则部署时需要自行准备 ./data/godofgm/data.db
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
  local dnf_root
  local gm_root
  local gm_input_dir
  local include_pvf="no"
  local include_gm_db="no"
  local dnf_tar="$output_dir/shenji-overlay-dnf.tar.gz"
  local gm_tar="$output_dir/shenji-overlay-gm.tar.gz"
  local summary_file="$output_dir/shenji-overlay-summary.txt"

  if [[ "${overlay_dir:-}" == "-h" || "${overlay_dir:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_path "$overlay_dir/rootfs"
  require_path "$overlay_dir/rootfs/home/template/init/init.sh"
  require_path "$overlay_dir/rootfs/home/template/init/init_main_db.sh"
  require_path "$overlay_dir/rootfs/home/template/init/init_server_group_db.sh"
  require_path "$overlay_dir/rootfs/home/template/init/init_sql.tgz"
  require_path "$overlay_dir/rootfs/home/template/init/dp.tgz"
  require_path "$overlay_dir/rootfs/home/template/init/df_game_r"

  mkdir -p "$output_dir"
  rm -f "$dnf_tar" "$gm_tar" "$summary_file"

  TMP_ROOT=$(mktemp -d)
  trap '[[ -n "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"' EXIT

  dnf_root="$TMP_ROOT/dnf"
  gm_root="$TMP_ROOT/gm"
  gm_input_dir="$overlay_dir/gm/dist"

  mkdir -p "$dnf_root" "$gm_root/data"

  cp -a "$overlay_dir/rootfs"/. "$dnf_root"/

  if [[ -f "$overlay_dir/rootfs/home/template/init/Script.pvf" ]]; then
    include_pvf="yes"
  fi

  if [[ ! -d "$gm_input_dir" ]]; then
    require_path "$overlay_dir/$GM_DIST_PAYLOAD_PATH"
    mkdir -p "$TMP_ROOT/gm_input"
    tar -xzf "$overlay_dir/$GM_DIST_PAYLOAD_PATH" -C "$TMP_ROOT/gm_input"
    gm_input_dir="$TMP_ROOT/gm_input/gm/dist"
  fi

  require_path "$gm_input_dir/godofgm"
  require_path "$gm_input_dir/config/server.json"
  require_path "$gm_input_dir/source"
  require_path "$gm_input_dir/web"

  copy_any "$gm_input_dir/config" "$gm_root/config"
  copy_any "$gm_input_dir/source" "$gm_root/source"
  copy_any "$gm_input_dir/web" "$gm_root/web"
  copy_any "$gm_input_dir/godofgm" "$gm_root/godofgm"

  if copy_any "$gm_input_dir/data/data.db" "$gm_root/data/data.db"; then
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

Notes:
- DNF 主镜像已带 VMDK 生成的 rootfs overlay 和数据库初始化 SQL
- 外部 ./data/Script.pvf 优先于镜像内种子；需要替换时直接覆盖外部卷中的同名文件
- 外部 ./data/dp/ 优先于镜像内 dp.tgz；只有 ./data/dp 为空时才会自动解压镜像内种子
- 外部 ./data/godofgm/data.db 优先于镜像内种子；需要替换时直接覆盖外部卷中的同名文件
EOF

  if [[ "$include_pvf" != "yes" ]]; then
    echo "- 当前打包输入未内置 Script.pvf，首次启动前请自行准备 ./data/Script.pvf" >>"$summary_file"
  fi

  if [[ "$include_gm_db" != "yes" ]]; then
    echo "- 当前打包输入未内置 GodOfGM data.db，首次启动前请自行准备 ./data/godofgm/data.db" >>"$summary_file"
  fi

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
