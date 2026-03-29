#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
MANIFEST_FILE="$SCRIPT_DIR/shenji_overlay.manifest"
BASE_DP2_TGZ="$SCRIPT_DIR/dp2.tgz"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
COMPOSE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/docker-compose.yaml"
GODOFGM_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/gm-start.sh"
GODOFGM_DOCKERFILE_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/Dockerfile.godofgm"
GAME_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/game-start.sh.template"
CHANNEL_START_TEMPLATE="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay/channel-start.sh.template"

NBD_DEV=""
MOUNT_DIR=""
VG_NAME=""

usage() {
  cat <<'EOF'
用法:
  sync_from_vmdk.sh <VMDK文件或已挂载根目录> [输出目录]

说明:
  1. 输出目录默认是 deploy/dnf/docker-compose/shenji_overlay
  2. 脚本会以清风仓库自带 dp2.tgz 为基底，再覆盖神迹 VMDK 中确认必要的玩法文件
  3. 默认不会直接启用神迹 df_game_r，只会放到 optional/ 目录备用

示例:
  ./sync_from_vmdk.sh /home/ubuntu/dnf/DNFServer.vmdk
  ./sync_from_vmdk.sh /mnt/dnf-vmdk/root /tmp/shenji-overlay
EOF
}

cleanup() {
  local stale_mp
  for stale_mp in /tmp/shenji-vmdk.*; do
    [[ -e "$stale_mp" ]] || continue
    if mountpoint -q "$stale_mp"; then
      sudo umount "$stale_mp" >/dev/null 2>&1 || true
    fi
    rmdir "$stale_mp" >/dev/null 2>&1 || true
  done
  if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR"; then
    sudo umount "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NBD_DEV" ]]; then
    sudo qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT_DIR" ]] && [[ -d "$MOUNT_DIR" ]]; then
    rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
}

find_free_nbd() {
  local sys dev
  for sys in /sys/block/nbd*; do
    [[ -e "$sys/size" ]] || continue
    if [[ "$(cat "$sys/size")" == "0" ]]; then
      dev="/dev/${sys##*/}"
      echo "$dev"
      return 0
    fi
  done
  return 1
}

attach_vmdk() {
  local vmdk_path="$1"
  local candidate root_dev=""
  local pv_path=""

  command -v qemu-nbd >/dev/null || {
    echo "缺少 qemu-nbd，请先安装 qemu-utils" >&2
    exit 1
  }

  sudo modprobe nbd max_part=16
  NBD_DEV=$(find_free_nbd) || {
    echo "没有找到空闲的 /dev/nbdX 设备" >&2
    exit 1
  }

  sudo qemu-nbd --read-only --connect="$NBD_DEV" "$vmdk_path"
  sudo udevadm settle
  sleep 1
  pv_path=$(lsblk -nrpo NAME,FSTYPE,TYPE "$NBD_DEV" | awk '$2 == "LVM2_member" { print $1; exit }')
  VG_NAME=""
  if [[ -n "$pv_path" ]]; then
    VG_NAME=$(sudo pvs --noheadings -o vg_name "$pv_path" 2>/dev/null | awk 'NF {print $1; exit}')
  fi
  if [[ -n "$VG_NAME" ]]; then
    sudo vgchange -an "$VG_NAME" >/dev/null 2>&1 || true
  fi
  sudo vgscan --mknodes >/dev/null 2>&1 || true
  if [[ -n "$VG_NAME" ]]; then
    sudo vgchange -ay "$VG_NAME" >/dev/null 2>&1 || true
  else
    sudo vgchange -ay >/dev/null 2>&1 || true
  fi
  sudo udevadm settle

  MOUNT_DIR=$(mktemp -d /tmp/shenji-vmdk.XXXXXX)
  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    sudo mount -o ro "$candidate" "$MOUNT_DIR"
    if [[ -f "$MOUNT_DIR/home/neople/game/Script.pvf" ]] && [[ -f "$MOUNT_DIR/dp2/df_game_r.lua" ]]; then
      root_dev="$candidate"
      break
    fi
    sudo umount "$MOUNT_DIR"
  done < <(
    {
      lsblk -nrpo NAME,FSTYPE,TYPE,SIZE "$NBD_DEV" | awk '$2 == "ext4" && ($3 == "lvm" || $3 == "part") { print $1, $4 }'
      if [[ -n "$VG_NAME" ]]; then
        while read -r lv_path lv_size; do
          [[ -n "$lv_path" && -n "$lv_size" ]] || continue
          if [[ "$(lsblk -nrpo FSTYPE "$lv_path" 2>/dev/null | head -1)" == "ext4" ]]; then
            echo "$lv_path $lv_size"
          fi
        done < <(sudo lvs --noheadings -o lv_path,lv_size "$VG_NAME" 2>/dev/null)
      else
        while read -r lv_path lv_size; do
          [[ -n "$lv_path" && -n "$lv_size" ]] || continue
          if [[ "$(lsblk -nrpo FSTYPE "$lv_path" 2>/dev/null | head -1)" == "ext4" ]]; then
            echo "$lv_path $lv_size"
          fi
        done < <(sudo lvs --noheadings -o lv_path,lv_size 2>/dev/null)
      fi
    } | sort -k2h -r | awk '{print $1}' | awk '!seen[$0]++'
  )

  [[ -n "$root_dev" ]] || {
    echo "未能在 $NBD_DEV 中识别出包含神迹文件的根分区" >&2
    exit 1
  }

  echo "$MOUNT_DIR"
}

validate_source_root() {
  local root_dir="$1"
  local missing=0
  local rel

  for rel in \
    "home/neople/game/Script.pvf" \
    "dp2/df_game_r.lua" \
    "dp2/df_game_r.js" \
    "dp2/libdp2pre.so"; do
    if [[ ! -f "$root_dir/$rel" ]]; then
      echo "缺少必要文件: $root_dir/$rel" >&2
      missing=1
    fi
  done

  [[ "$missing" -eq 0 ]] || exit 1
}

copy_manifest_files() {
  local source_root="$1"
  local out_dir="$2"
  local line source_rel dest_rel mode level reason source_path dest_path

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    IFS='|' read -r source_rel dest_rel mode level reason <<<"$line"
    source_path="$source_root/$source_rel"
    dest_path="$out_dir/$dest_rel"

    if [[ "$level" == "required" ]]; then
      install -D -m "$mode" "$source_path" "$dest_path"
    else
      install -D -m "$mode" "$source_path" "$dest_path"
    fi
  done <"$MANIFEST_FILE"
}

copy_sidecar_files() {
  local source_root="$1"
  local out_dir="$2"

  rm -rf "$out_dir/gm" "$out_dir/optional/libfd_source" "$out_dir/meta/source_scripts"
  mkdir -p "$out_dir/gm" "$out_dir/optional" "$out_dir/meta/source_scripts"

  sudo cp -a "$source_root/root/dist" "$out_dir/gm/dist"
  sudo cp -a "$source_root/root/server" "$out_dir/optional/libfd_source"
  sudo cp -a "$source_root/root/run" "$out_dir/meta/source_scripts/run"
  sudo cp -a "$source_root/root/run_nopvp" "$out_dir/meta/source_scripts/run_nopvp"
  sudo cp -a "$source_root/root/stop" "$out_dir/meta/source_scripts/stop"
  sudo chown -R "$(id -u):$(id -g)" "$out_dir/gm" "$out_dir/optional/libfd_source"
  sudo chown -R "$(id -u):$(id -g)" "$out_dir/meta/source_scripts"
}

copy_support_files() {
  local out_dir="$1"

  if [[ ! -f "$out_dir/docker-compose.yaml" ]]; then
    cp "$COMPOSE_TEMPLATE" "$out_dir/docker-compose.yaml"
  fi

  if [[ ! -f "$out_dir/gm-start.sh" ]]; then
    cp "$GODOFGM_START_TEMPLATE" "$out_dir/gm-start.sh"
    chmod +x "$out_dir/gm-start.sh"
  fi

  if [[ ! -f "$out_dir/Dockerfile.godofgm" ]]; then
    cp "$GODOFGM_DOCKERFILE_TEMPLATE" "$out_dir/Dockerfile.godofgm"
  fi

  mkdir -p "$out_dir/data/run"
  cp "$GAME_START_TEMPLATE" "$out_dir/data/run/start_game.sh"
  chmod +x "$out_dir/data/run/start_game.sh"
  cp "$CHANNEL_START_TEMPLATE" "$out_dir/data/run/start_channel.sh"
  chmod +x "$out_dir/data/run/start_channel.sh"
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
    echo "2. 已启用神迹 dp2 脚本覆盖"
    echo "3. 已启用神迹 run 语义提取版 start_game.sh 与 start_channel.sh"
    echo "4. 已同步神迹 channel_amd64 与双份 channel_info"
    echo "5. 已同步网页 GM 运行目录到 gm/dist"
    echo "6. 未默认启用神迹 df_game_r，文件保存在 optional/df_game_r.shenji"
    echo "7. 已保存 libfd.so 的源码和原始 run 脚本以便后续比对更新"
  } >"$out_dir/meta/recommended-env.txt"

  (
    cd "$out_dir"
    sha256sum \
      data/Script.pvf \
      data/libfd.so \
      data/game/channel_info/channel_info.etc \
      data/game/channel_info/version \
      data/channel/channel_amd64 \
      data/channel/channel_info/channel_info.etc \
      data/channel/channel_info/version \
      data/dp/df_game_r.lua \
      data/dp/df_game_r.js \
      data/dp/libhook.so \
      gm/dist/godofgm \
      gm/dist/config/server.json \
      gm/dist/data/data.db \
      data/run/start_game.sh \
      data/run/start_channel.sh \
      optional/df_game_r.shenji \
      > meta/checksums.txt
  )
}

main() {
  local source_input="${1:-}"
  local out_dir="${2:-$DEFAULT_OUTPUT_DIR}"
  local source_root

  [[ -n "$source_input" ]] || {
    usage
    exit 1
  }

  trap cleanup EXIT

  if [[ "$source_input" == *.vmdk ]]; then
    source_root=$(attach_vmdk "$source_input")
  else
    source_root="$source_input"
  fi

  validate_source_root "$source_root"

  mkdir -p "$out_dir"
  rm -rf "$out_dir/data/dp.tmp"
  mkdir -p "$out_dir/data/dp.tmp"
  tar -xzf "$BASE_DP2_TGZ" -C "$out_dir/data/dp.tmp"
  rm -rf "$out_dir/data/dp"
  mv "$out_dir/data/dp.tmp" "$out_dir/data/dp"
  mkdir -p "$out_dir/meta" "$out_dir/optional"

  copy_manifest_files "$source_root" "$out_dir"
  copy_sidecar_files "$source_root" "$out_dir"
  copy_support_files "$out_dir"
  write_metadata "$source_input" "$source_root" "$out_dir"

  cat <<EOF
同步完成:
  输出目录: $out_dir

已生成:
  $out_dir/data/Script.pvf
  $out_dir/data/dp
  $out_dir/gm/dist
  $out_dir/optional/df_game_r.shenji
  $out_dir/meta

建议下一步:
  1. 检查 $out_dir/meta/recommended-env.txt
  2. 进入 $out_dir 执行 docker compose up -d --build
  3. 只有在 Script.pvf + 神迹 dp2 仍无法跑通时，才考虑启用 optional/df_game_r.shenji
EOF
}

main "$@"
