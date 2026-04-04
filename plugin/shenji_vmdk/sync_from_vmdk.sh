#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
ROOTFS_TEMPLATE_DIR="$SCRIPT_DIR/rootfs_template"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
COMPOSE_PROJECT_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/docker-compose.project.yaml"
COMPOSE_OVERRIDE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/docker-compose.override.yaml"
COMPOSE_WRAPPER_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/compose.sh"
GODOFGM_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/gm-start.sh"
GODOFGM_DOCKERFILE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/Dockerfile.godofgm"
GM_DIST_PAYLOAD_REL="payload/gm_dist.tgz"

source "$SCRIPT_DIR/vmdk_mount_lib.sh"

usage() {
  cat <<'EOF'
用法:
  sync_from_vmdk.sh <VMDK文件或已挂载根目录> [输出目录]

说明:
  1. 输出目录默认是 deploy/dnf/docker-compose/shenji_overlay
  2. 脚本会直接生成 rootfs/，作为后续镜像打包的唯一 DNF 输入
  3. dp 会直接使用神迹 VMDK 中的完整 dp2 目录，并重打包为 dp.tgz
  4. df_game_r 现已作为默认覆盖文件同步到 rootfs 中

示例:
  ./sync_from_vmdk.sh /path/to/DNFServer.vmdk
  ./sync_from_vmdk.sh /mnt/dnf-vmdk/root /tmp/shenji-overlay
EOF
}

prepare_rootfs_layout() {
  local out_dir="$1"
  local rootfs_dir="$out_dir/rootfs"
  local current_run_dir="$rootfs_dir/home/template/init/run"
  local tmp_run_dir

  tmp_run_dir=$(mktemp -d)
  if [[ -f "$current_run_dir/start_game.sh" ]]; then
    cp "$current_run_dir/start_game.sh" "$tmp_run_dir/start_game.sh"
  fi
  if [[ -f "$current_run_dir/start_channel.sh" ]]; then
    cp "$current_run_dir/start_channel.sh" "$tmp_run_dir/start_channel.sh"
  fi

  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir"
  cp -a "$ROOTFS_TEMPLATE_DIR"/. "$rootfs_dir"/

  mkdir -p \
    "$rootfs_dir/home/template/init/run" \
    "$rootfs_dir/home/template/neople/game/channel_info" \
    "$rootfs_dir/home/template/neople/channel/channel_info"

  if [[ -f "$tmp_run_dir/start_game.sh" ]]; then
    install -D -m 0755 "$tmp_run_dir/start_game.sh" "$rootfs_dir/home/template/init/run/start_game.sh"
  fi
  if [[ -f "$tmp_run_dir/start_channel.sh" ]]; then
    install -D -m 0755 "$tmp_run_dir/start_channel.sh" "$rootfs_dir/home/template/init/run/start_channel.sh"
  fi

  rm -rf "$tmp_run_dir"
}

copy_vmdk_files_to_rootfs() {
  local source_root="$1"
  local out_dir="$2"
  local rootfs_dir="$out_dir/rootfs"

  install -D -m 0644 "$source_root/home/neople/game/Script.pvf" \
    "$rootfs_dir/home/template/init/Script.pvf"
  install -D -m 0755 "$source_root/home/neople/game/df_game_r" \
    "$rootfs_dir/home/template/init/df_game_r"
  install -D -m 0755 "$source_root/home/neople/game/libfd.so" \
    "$rootfs_dir/home/template/neople/game/libfd.so"
  install -D -m 0644 "$source_root/home/neople/game/channel_info/channel_info.etc" \
    "$rootfs_dir/home/template/neople/game/channel_info/channel_info.etc"
  install -D -m 0644 "$source_root/home/neople/game/channel_info/version" \
    "$rootfs_dir/home/template/neople/game/channel_info/version"
  install -D -m 0755 "$source_root/home/neople/channel/channel_amd64" \
    "$rootfs_dir/home/template/neople/channel/channel_amd64"
  install -D -m 0644 "$source_root/home/neople/channel/channel_info/channel_info.etc" \
    "$rootfs_dir/home/template/neople/channel/channel_info/channel_info.etc"
  install -D -m 0644 "$source_root/home/neople/channel/channel_info/version" \
    "$rootfs_dir/home/template/neople/channel/channel_info/version"
}

build_dp_archive() {
  local source_root="$1"
  local out_dir="$2"
  local tmp_dir

  if [[ ! -d "$source_root/dp2" ]]; then
    echo "缺少 VMDK 中的 dp2 目录: $source_root/dp2" >&2
    exit 1
  fi

  tmp_dir=$(mktemp -d)
  mkdir -p "$tmp_dir/dp"

  (
    cd "$source_root/dp2"
    tar -cf - .
  ) | (
    cd "$tmp_dir/dp"
    tar -xf -
  )

  # Qingfeng and the current overlay templates both expect /dp2/libhook.so.
  # When the VMDK dp2 payload only ships libdp2pre.so, add the expected filename
  # without changing the rest of the payload layout.
  if [[ -f "$tmp_dir/dp/libdp2pre.so" && ! -f "$tmp_dir/dp/libhook.so" ]]; then
    install -m 0755 "$tmp_dir/dp/libdp2pre.so" "$tmp_dir/dp/libhook.so"
  fi

  (
    cd "$tmp_dir"
    tar -czf "$out_dir/rootfs/home/template/init/dp.tgz" dp
  )

  rm -rf "$tmp_dir"
}

copy_sidecar_files() {
  local source_root="$1"
  local out_dir="$2"

  rm -rf "$out_dir/gm"
  mkdir -p "$out_dir/gm"

  sudo cp -a "$source_root/root/dist" "$out_dir/gm/dist"
  sudo chown -R "$(id -u):$(id -g)" "$out_dir/gm"
}

copy_support_files() {
  local out_dir="$1"

  if [[ ! -f "$out_dir/docker-compose.project.yaml" ]]; then
    cp "$COMPOSE_PROJECT_TEMPLATE" "$out_dir/docker-compose.project.yaml"
  fi

  if [[ ! -f "$out_dir/docker-compose.override.yaml" ]]; then
    cp "$COMPOSE_OVERRIDE_TEMPLATE" "$out_dir/docker-compose.override.yaml"
  fi

  if [[ ! -f "$out_dir/compose.sh" ]]; then
    cp "$COMPOSE_WRAPPER_TEMPLATE" "$out_dir/compose.sh"
    chmod +x "$out_dir/compose.sh"
  fi

  if [[ ! -f "$out_dir/gm-start.sh" ]]; then
    cp "$GODOFGM_START_TEMPLATE" "$out_dir/gm-start.sh"
    chmod +x "$out_dir/gm-start.sh"
  fi

  if [[ ! -f "$out_dir/Dockerfile.godofgm" ]]; then
    cp "$GODOFGM_DOCKERFILE_TEMPLATE" "$out_dir/Dockerfile.godofgm"
  fi

  if [[ ! -f "$out_dir/rootfs/home/template/init/run/start_game.sh" ]]; then
    echo "缺少 rootfs/home/template/init/run/start_game.sh，请先在 overlay rootfs 中维护该脚本" >&2
    exit 1
  fi

  if [[ ! -f "$out_dir/rootfs/home/template/init/run/start_channel.sh" ]]; then
    echo "缺少 rootfs/home/template/init/run/start_channel.sh，请先在 overlay rootfs 中维护该脚本" >&2
    exit 1
  fi

  chmod +x "$out_dir/rootfs/home/template/init/run/start_game.sh"
  chmod +x "$out_dir/rootfs/home/template/init/run/start_channel.sh"
}

pack_payloads() {
  local out_dir="$1"

  mkdir -p "$out_dir/payload"

  if [[ -d "$out_dir/gm/dist" ]]; then
    (
      cd "$out_dir"
      tar -czf "$GM_DIST_PAYLOAD_REL" gm/dist
    )
    rm -rf "$out_dir/gm/dist"
  fi
}

main() {
  local source_input="${1:-}"
  local out_dir="${2:-$DEFAULT_OUTPUT_DIR}"
  local source_root

  [[ -n "$source_input" ]] || {
    usage
    exit 1
  }

  if [[ -e "$out_dir" && ! -d "$out_dir" ]]; then
    echo "输出路径已存在且不是目录: $out_dir" >&2
    exit 1
  fi

  if [[ "$out_dir" =~ \.sql(\.gz)?$ ]]; then
    echo "警告: sync_from_vmdk.sh 的第二个参数是输出目录，不是 SQL dump 路径" >&2
    echo "如果要一键处理 VMDK、SQL 导出和数据库 overlay，请执行: plugin/shenji_vmdk/update_from_vmdk.sh <VMDK文件>" >&2
  fi

  trap cleanup EXIT

  if [[ "$source_input" == *.vmdk ]]; then
    source_root=$(attach_vmdk "$source_input")
  else
    source_root="$source_input"
  fi

  validate_source_root "$source_root"

  mkdir -p "$out_dir"
  rm -rf "$out_dir/data" "$out_dir/optional"
  rm -f "$out_dir/payload/dp_overlay.tgz"

  prepare_rootfs_layout "$out_dir"
  copy_vmdk_files_to_rootfs "$source_root" "$out_dir"
  build_dp_archive "$source_root" "$out_dir"
  copy_sidecar_files "$source_root" "$out_dir"
  copy_support_files "$out_dir"
  pack_payloads "$out_dir"

  cat <<EOF
同步完成:
  输出目录: $out_dir

已生成:
  $out_dir/rootfs
  $out_dir/payload/gm_dist.tgz
EOF

  if [[ "${DP2_SUPPRESS_INTERMEDIATE_HINTS:-0}" != "1" ]]; then
    cat <<EOF

建议下一步:
  1. 执行 plugin/shenji_vmdk/build_db_overlay.sh <VMDK导出的全库SQL> $out_dir
  2. 执行 plugin/shenji_vmdk/package_shenji_overlay.sh $out_dir
  3. 进入 $out_dir 执行 ./compose.sh up -d --build
EOF
  fi
}

main "$@"
