#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
MANIFEST_FILE="$SCRIPT_DIR/shenji_overlay.manifest"
ROOTFS_TEMPLATE_DIR="$SCRIPT_DIR/rootfs_template"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
COMPOSE_PROJECT_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/docker-compose.project.yaml"
COMPOSE_OVERRIDE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/docker-compose.override.yaml"
COMPOSE_WRAPPER_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/compose.sh"
GODOFGM_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/gm-start.sh"
GODOFGM_DOCKERFILE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/Dockerfile.godofgm"
GAME_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/game-start.sh.template"
CHANNEL_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/channel-start.sh.template"
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

  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir"
  cp -a "$ROOTFS_TEMPLATE_DIR"/. "$rootfs_dir"/

  mkdir -p \
    "$rootfs_dir/home/template/init/run" \
    "$rootfs_dir/home/template/neople/game/channel_info" \
    "$rootfs_dir/home/template/neople/channel/channel_info" \
    "$rootfs_dir/opt/shenji-overlay-meta"
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
  local source_scripts_dir="$out_dir/meta/source_scripts"

  rm -rf "$out_dir/gm" "$source_scripts_dir"
  mkdir -p "$out_dir/gm" "$source_scripts_dir"

  sudo cp -a "$source_root/root/dist" "$out_dir/gm/dist"
  sudo cp -a "$source_root/root/run" "$source_scripts_dir/run"
  sudo cp -a "$source_root/root/run_nopvp" "$source_scripts_dir/run_nopvp"
  sudo cp -a "$source_root/root/stop" "$source_scripts_dir/stop"
  sudo chown -R "$(id -u):$(id -g)" "$out_dir/gm"
  sudo chown -R "$(id -u):$(id -g)" "$source_scripts_dir"
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

  mkdir -p "$out_dir/rootfs/home/template/init/run"
  cp "$GAME_START_TEMPLATE" "$out_dir/rootfs/home/template/init/run/start_game.sh"
  chmod +x "$out_dir/rootfs/home/template/init/run/start_game.sh"
  cp "$CHANNEL_START_TEMPLATE" "$out_dir/rootfs/home/template/init/run/start_channel.sh"
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

write_metadata() {
  local source_input="$1"
  local source_root="$2"
  local out_dir="$3"

  cat >"$out_dir/meta/source.txt" <<EOF
source_input=$source_input
source_root=$source_root
generated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
EOF

  cp "$MANIFEST_FILE" "$out_dir/meta/shenji_overlay.manifest"

  {
    echo "# 必须保留的环境变量"
    echo "SERVER_GROUP=3"
    echo "SERVER_GROUP_DB=cain"
    echo "DNF_DB_GAME_PASSWORD=uu5!^%jg"
    echo "OPEN_CHANNEL=11"
    echo
    echo "# 默认策略"
    echo "1. 已启用神迹 Script.pvf 覆盖"
    echo "2. 已启用神迹 df_game_r 覆盖"
    echo "3. 已启用神迹 dp2 脚本覆盖"
    echo "4. 已启用神迹 run 语义提取版 start_game.sh 与 start_channel.sh"
    echo "5. 已同步神迹 channel_amd64 与双份 channel_info"
    echo "6. 已同步网页 GM，并压缩为 payload/gm_dist.tgz"
    echo "7. 已保留运行所需的 libfd.so，并保存原始 run 脚本以便后续比对更新"
  } >"$out_dir/meta/recommended-env.txt"

  (
    cd "$out_dir"
    sha256sum \
      rootfs/home/template/init/Script.pvf \
      rootfs/home/template/init/df_game_r \
      rootfs/home/template/init/dp.tgz \
      rootfs/home/template/neople/game/libfd.so \
      rootfs/home/template/neople/game/channel_info/channel_info.etc \
      rootfs/home/template/neople/game/channel_info/version \
      rootfs/home/template/neople/channel/channel_amd64 \
      rootfs/home/template/neople/channel/channel_info/channel_info.etc \
      rootfs/home/template/neople/channel/channel_info/version \
      rootfs/home/template/init/run/start_game.sh \
      rootfs/home/template/init/run/start_channel.sh \
      payload/gm_dist.tgz \
      > meta/checksums.txt
  )
}

refresh_rootfs_meta() {
  local out_dir="$1"
  local meta_root="$out_dir/rootfs/opt/shenji-overlay-meta"

  rm -rf "$meta_root"
  mkdir -p "$meta_root"

  if [[ -d "$out_dir/meta" ]]; then
    cp -a "$out_dir/meta"/. "$meta_root"/
    rm -rf "$meta_root/source_scripts"
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
  mkdir -p "$out_dir/meta"

  prepare_rootfs_layout "$out_dir"
  copy_vmdk_files_to_rootfs "$source_root" "$out_dir"
  build_dp_archive "$source_root" "$out_dir"
  copy_sidecar_files "$source_root" "$out_dir"
  copy_support_files "$out_dir"
  pack_payloads "$out_dir"
  write_metadata "$source_input" "$source_root" "$out_dir"
  refresh_rootfs_meta "$out_dir"

  cat <<EOF
同步完成:
  输出目录: $out_dir

已生成:
  $out_dir/rootfs
  $out_dir/payload/gm_dist.tgz
  $out_dir/meta
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
