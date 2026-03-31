#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
MANIFEST_FILE="$SCRIPT_DIR/shenji_overlay.manifest"
BASE_DP2_TGZ="$SCRIPT_DIR/dp2.tgz"
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

NBD_DEV=""
MOUNT_DIR=""
VG_NAME=""
VG_NAMES=()
LVM_CONFIG=""
LVM_COMMON_ARGS=()
SOURCE_ROOT_MARKER_MIN_SCORE=2
SOURCE_ROOT_REQUIRED_FILES=(
  "home/neople/game/Script.pvf"
  "home/neople/game/df_game_r"
  "dp2/df_game_r.lua"
  "dp2/df_game_r.js"
  "dp2/libdp2pre.so"
)

usage() {
  cat <<'EOF'
用法:
  sync_from_vmdk.sh <VMDK文件或已挂载根目录> [输出目录]

说明:
  1. 输出目录默认是 deploy/dnf/docker-compose/shenji_overlay
  2. 脚本会直接生成 rootfs/，作为后续镜像打包的唯一 DNF 输入
  3. dp 会以清风仓库自带 dp2.tgz 为基底，再覆盖神迹 VMDK 中确认必要的玩法文件
  4. df_game_r 现已作为默认覆盖文件同步到 rootfs 中

示例:
  ./sync_from_vmdk.sh /home/ubuntu/dnf/DNFServer.vmdk
  ./sync_from_vmdk.sh /mnt/dnf-vmdk/root /tmp/shenji-overlay
EOF
}

cleanup() {
  local stale_mp vg_name
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
  if (( ${#VG_NAMES[@]} > 0 )); then
    for vg_name in "${VG_NAMES[@]}"; do
      run_lvm vgchange -an "$vg_name" >/dev/null 2>&1 || true
    done
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

prepare_lvm_common_args() {
  local filter_entries

  filter_entries='"a|^/dev/nbd[0-9]+$|","a|^/dev/nbd[0-9]+p[0-9]+$|","a|^/dev/dm-[0-9]+$|","a|^/dev/mapper/.*$|","r|.*|"'
  LVM_CONFIG="devices { filter=[$filter_entries] global_filter=[$filter_entries]"
  if sudo lvmconfig --type default devices/use_devicesfile >/dev/null 2>&1; then
    LVM_CONFIG+=" use_devicesfile=0"
  fi
  LVM_CONFIG+=" }"
  LVM_COMMON_ARGS=(--config "$LVM_CONFIG")
}

run_lvm() {
  local cmd="$1"
  shift

  sudo "$cmd" "${LVM_COMMON_ARGS[@]}" "$@"
}

count_source_root_markers() {
  local root_dir="$1"
  local rel matches=0

  for rel in "${SOURCE_ROOT_REQUIRED_FILES[@]}"; do
    if [[ -f "$root_dir/$rel" ]]; then
      ((matches += 1))
    fi
  done

  echo "$matches"
}

mount_candidate_readonly() {
  local candidate="$1"
  local fstype="$2"

  case "$fstype" in
    xfs)
      sudo mount -o ro,norecovery,nouuid "$candidate" "$MOUNT_DIR" 2>/dev/null ||
        sudo mount -o ro,nouuid "$candidate" "$MOUNT_DIR" 2>/dev/null ||
        sudo mount -o ro "$candidate" "$MOUNT_DIR"
      ;;
    *)
      sudo mount -o ro "$candidate" "$MOUNT_DIR"
      ;;
  esac
}

list_nbd_block_devices() {
  lsblk -nrpo NAME,TYPE,SIZE "$NBD_DEV" |
    awk '($2 == "disk" || $2 == "part") && NF >= 3 { print $1 "|" $2 "|" $3 }'
}

device_has_partitions() {
  local dev="$1"

  lsblk -nrpo NAME,TYPE "$dev" 2>/dev/null |
    awk '$1 != "'"$dev"'" && $2 == "part" { found=1 } END { exit(found ? 0 : 1) }'
}

list_source_root_candidates() {
  local dev dev_type dev_size dev_fstype
  local lv_path lv_size lv_vg lv_fstype
  local holder_path holder_size holder_fstype

  {
    while IFS='|' read -r dev dev_type dev_size; do
      [[ -n "$dev" ]] || continue
      dev_fstype=$(resolve_block_fstype "$dev")
      case "$dev_fstype" in
        LVM2_member|linux_raid_member|swap)
          continue
          ;;
      esac
      if [[ "$dev_type" == "disk" ]] && device_has_partitions "$dev"; then
        continue
      fi
      [[ -n "$dev_fstype" ]] || dev_fstype="unknown"
      echo "$dev $dev_fstype $dev_size"
    done < <(list_nbd_block_devices)

    while IFS='|' read -r lv_path lv_size lv_vg; do
      [[ -n "$lv_path" && -n "$lv_size" ]] || continue
      lv_fstype=$(resolve_block_fstype "$lv_path")
      [[ -n "$lv_fstype" ]] || lv_fstype="unknown"
      echo "$lv_path $lv_fstype $lv_size"
    done < <(list_lvm_candidates_for_nbd)

    while IFS='|' read -r holder_path holder_size; do
      [[ -n "$holder_path" ]] || continue
      holder_fstype=$(resolve_block_fstype "$holder_path")
      case "$holder_fstype" in
        ""|LVM2_member|linux_raid_member|swap)
          continue
          ;;
      esac
      echo "$holder_path $holder_fstype ${holder_size:-0}"
    done < <(list_dm_holders_for_nbd)
  } |
    awk '!seen[$1]++' |
    sort -k3h -r
}

resolve_block_fstype() {
  local dev="$1"
  local fstype=""

  fstype=$(lsblk -nrpo FSTYPE "$dev" 2>/dev/null | awk 'NF {print $1; exit}')
  if [[ -z "$fstype" ]]; then
    fstype=$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null | awk 'NF {print $1; exit}')
  fi

  echo "$fstype"
}

find_volume_groups_for_nbd() {
  run_lvm pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null |
    awk -F'|' -v nbd="$NBD_DEV" '
      function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      {
        pv = trim($1)
        vg = trim($2)
        if (pv ~ "^" nbd && vg != "") {
          print vg
        }
      }
    '
}

list_lvm_candidates_for_nbd() {
  run_lvm lvs --noheadings --separator '|' -o lv_path,lv_size,devices,vg_name 2>/dev/null |
    awk -F'|' -v nbd="$NBD_DEV" '
      function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      {
        lv_path = trim($1)
        lv_size = trim($2)
        devices = trim($3)
        vg_name = trim($4)
        if (lv_path != "" && devices ~ nbd) {
          print lv_path "|" lv_size "|" vg_name
        }
      }
    '
}

scan_lvm_devices_for_nbd() {
  local dev dev_type dev_size

  while IFS='|' read -r dev dev_type dev_size; do
    [[ -n "$dev" ]] || continue
    run_lvm pvscan --cache "$dev" >/dev/null 2>&1 || true
    run_lvm pvscan --cache -aay "$dev" >/dev/null 2>&1 || true
  done < <(list_nbd_block_devices)

  run_lvm vgscan --mknodes >/dev/null 2>&1 || true
  sudo udevadm settle
}

list_dm_holders_for_nbd() {
  local dev dev_type dev_size holder holder_name holder_path holder_size

  while IFS='|' read -r dev dev_type dev_size; do
    [[ -n "$dev" ]] || continue
    for holder in "/sys/class/block/${dev##*/}/holders/"*; do
      [[ -e "$holder" ]] || continue
      holder_name="${holder##*/}"
      holder_path="/dev/$holder_name"
      holder_size=$(lsblk -nrpo SIZE "$holder_path" 2>/dev/null | awk 'NF {print $1; exit}')
      echo "$holder_path|${holder_size:-0}"
    done
  done < <(list_nbd_block_devices)
}

print_nbd_layout() {
  local dev type size fstype lv_path lv_size lv_vg holder_path holder_size

  while read -r dev type size; do
    [[ -n "$dev" ]] || continue
    fstype=$(resolve_block_fstype "$dev")
    [[ -n "$fstype" ]] || fstype="-"
    echo "  $dev [$type $size] fstype=$fstype" >&2
  done < <(lsblk -nrpo NAME,TYPE,SIZE "$NBD_DEV")

  while IFS='|' read -r lv_path lv_size lv_vg; do
    [[ -n "$lv_path" && -n "$lv_size" ]] || continue
    fstype=$(resolve_block_fstype "$lv_path")
    [[ -n "$fstype" ]] || fstype="-"
    echo "  $lv_path [lvm $lv_size] fstype=$fstype vg=${lv_vg:-unknown}" >&2
  done < <(list_lvm_candidates_for_nbd)

  while IFS='|' read -r holder_path holder_size; do
    [[ -n "$holder_path" ]] || continue
    fstype=$(resolve_block_fstype "$holder_path")
    [[ -n "$fstype" ]] || fstype="-"
    echo "  $holder_path [holder ${holder_size:-0}] fstype=$fstype" >&2
  done < <(list_dm_holders_for_nbd)
}

attach_vmdk() {
  local vmdk_path="$1"
  local candidate candidate_fstype candidate_size
  local root_dev="" root_fstype="" best_score=0 candidate_score
  local vg_name
  local -a candidate_reports=()

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
  sudo blockdev --rereadpt "$NBD_DEV" >/dev/null 2>&1 || true
  sudo partprobe "$NBD_DEV" >/dev/null 2>&1 || true
  sudo udevadm settle
  sleep 1
  VG_NAME=""
  VG_NAMES=()
  LVM_CONFIG=""
  LVM_COMMON_ARGS=()
  prepare_lvm_common_args
  scan_lvm_devices_for_nbd

  while read -r vg_name; do
    [[ -n "$vg_name" ]] || continue
    VG_NAMES+=("$vg_name")
  done < <(find_volume_groups_for_nbd | awk '!seen[$0]++')

  if (( ${#VG_NAMES[@]} > 0 )); then
    VG_NAME="${VG_NAMES[0]}"
  fi

  MOUNT_DIR=$(mktemp -d /tmp/shenji-vmdk.XXXXXX)
  while read -r candidate candidate_fstype candidate_size; do
    [[ -n "$candidate" && -n "$candidate_fstype" ]] || continue
    if ! mount_candidate_readonly "$candidate" "$candidate_fstype"; then
      candidate_reports+=("$candidate [$candidate_fstype $candidate_size] mount_failed")
      continue
    fi

    candidate_score=$(count_source_root_markers "$MOUNT_DIR")
    candidate_reports+=(
      "$candidate [$candidate_fstype $candidate_size] markers=$candidate_score/${#SOURCE_ROOT_REQUIRED_FILES[@]}"
    )

    sudo umount "$MOUNT_DIR"

    if (( candidate_score > best_score )); then
      root_dev="$candidate"
      root_fstype="$candidate_fstype"
      best_score=$candidate_score
    fi

    if (( best_score == ${#SOURCE_ROOT_REQUIRED_FILES[@]} )); then
      break
    fi
  done < <(list_source_root_candidates)

  if [[ -z "$root_dev" ]] || (( best_score < SOURCE_ROOT_MARKER_MIN_SCORE )); then
    echo "未能在 $NBD_DEV 中识别出包含神迹文件的根分区" >&2
    echo "块设备布局:" >&2
    print_nbd_layout
    if (( ${#VG_NAMES[@]} > 0 )); then
      echo "已识别卷组: ${VG_NAMES[*]}" >&2
    fi
    if (( ${#candidate_reports[@]} > 0 )); then
      echo "已检查候选分区:" >&2
      printf '  %s\n' "${candidate_reports[@]}" >&2
    fi
    echo "如自动识别失败，请手动挂载正确根分区后，将挂载目录作为脚本第一个参数传入" >&2
    exit 1
  fi

  mount_candidate_readonly "$root_dev" "$root_fstype"
  echo "自动识别根分区: $root_dev [$root_fstype] markers=$best_score/${#SOURCE_ROOT_REQUIRED_FILES[@]}" >&2

  echo "$MOUNT_DIR"
}

validate_source_root() {
  local root_dir="$1"
  local missing=0
  local rel

  for rel in "${SOURCE_ROOT_REQUIRED_FILES[@]}"; do
    if [[ ! -f "$root_dir/$rel" ]]; then
      echo "缺少必要文件: $root_dir/$rel" >&2
      missing=1
    fi
  done

  [[ "$missing" -eq 0 ]] || exit 1
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

  tmp_dir=$(mktemp -d)
  mkdir -p "$tmp_dir/dp"
  tar -xzf "$BASE_DP2_TGZ" -C "$tmp_dir/dp"

  install -D -m 0644 "$source_root/dp2/df_game_r.lua" "$tmp_dir/dp/df_game_r.lua"
  install -D -m 0644 "$source_root/dp2/df_game_r.js" "$tmp_dir/dp/df_game_r.js"
  install -D -m 0755 "$source_root/dp2/libdp2pre.so" "$tmp_dir/dp/libhook.so"

  (
    cd "$tmp_dir"
    tar -czf "$out_dir/rootfs/home/template/init/dp.tgz" dp
  )

  rm -rf "$tmp_dir"
}

copy_sidecar_files() {
  local source_root="$1"
  local out_dir="$2"
  local source_scripts_dir="$out_dir/rootfs/opt/shenji-overlay-meta/source_scripts"

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
  local source_scripts_tmp=""

  if [[ -d "$meta_root/source_scripts" ]]; then
    source_scripts_tmp=$(mktemp -d)
    cp -a "$meta_root/source_scripts" "$source_scripts_tmp/source_scripts"
  fi

  rm -rf "$meta_root"
  mkdir -p "$meta_root"

  if [[ -d "$out_dir/meta" ]]; then
    cp -a "$out_dir/meta"/. "$meta_root"/
  fi

  if [[ -n "$source_scripts_tmp" ]] && [[ -d "$source_scripts_tmp/source_scripts" ]]; then
    cp -a "$source_scripts_tmp/source_scripts" "$meta_root/source_scripts"
    rm -rf "$source_scripts_tmp"
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
    echo "如果要一键处理 VMDK 和 SQL，请执行: plugin/dp2/update_from_vmdk.sh <VMDK文件> <SQL文件>" >&2
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

建议下一步:
  1. 执行 plugin/dp2/build_db_overlay.sh <VMDK导出的全库SQL> $out_dir
  2. 执行 plugin/dp2/package_shenji_overlay.sh $out_dir
  3. 进入 $out_dir 执行 ./compose.sh up -d --build
EOF
}

main "$@"
