#!/usr/bin/env bash

NBD_DEV="${NBD_DEV:-}"
MOUNT_DIR="${MOUNT_DIR:-}"
VG_NAME="${VG_NAME:-}"
LVM_CONFIG="${LVM_CONFIG:-}"

if ! declare -p VG_NAMES >/dev/null 2>&1; then
  VG_NAMES=()
fi

if ! declare -p LVM_COMMON_ARGS >/dev/null 2>&1; then
  LVM_COMMON_ARGS=()
fi

if ! declare -p SOURCE_ROOT_REQUIRED_FILES >/dev/null 2>&1; then
  SOURCE_ROOT_REQUIRED_FILES=(
    "home/neople/game/Script.pvf"
    "home/neople/game/df_game_r"
    "dp2/df_game_r.lua"
    "dp2/df_game_r.js"
    "dp2/libdp2pre.so"
  )
fi

: "${SOURCE_ROOT_MARKER_MIN_SCORE:=2}"

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

  cleanup_stale_vmdk_state >/dev/null 2>&1 || true
}

cleanup_stale_vmdk_state() {
  local stale_mp vg_name sys dev

  for stale_mp in /tmp/shenji-vmdk.*; do
    [[ -e "$stale_mp" ]] || continue
    if mountpoint -q "$stale_mp"; then
      sudo umount "$stale_mp" >/dev/null 2>&1 || true
    fi
    rmdir "$stale_mp" >/dev/null 2>&1 || true
  done

  while read -r vg_name; do
    [[ -n "$vg_name" ]] || continue
    sudo vgchange -an "$vg_name" >/dev/null 2>&1 || true
  done < <(
    sudo pvs --noheadings -o vg_name,pv_name 2>/dev/null |
      awk '$2 ~ "^/dev/nbd" && $1 != "" { print $1 }' |
      awk '!seen[$0]++'
  )

  for sys in /sys/block/nbd*; do
    [[ -e "$sys/size" ]] || continue
    if [[ "$(cat "$sys/size")" != "0" ]]; then
      dev="/dev/${sys##*/}"
      sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true
    fi
  done

  sudo udevadm settle >/dev/null 2>&1 || true
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

ensure_vmdk_dependencies() {
  local cmd
  local -a missing=()

  for cmd in qemu-nbd lsblk blkid pvscan pvs lvs vgscan vgchange; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ! command -v lvmconfig >/dev/null 2>&1; then
    missing+=("lvmconfig")
  fi

  if (( ${#missing[@]} > 0 )); then
    echo "缺少 VMDK 挂载所需命令: ${missing[*]}" >&2
    echo "当前镜像的主数据分区是 LVM2_member，必须先安装 lvm2 和 qemu-utils" >&2
    echo "Ubuntu/Debian 可执行: sudo apt update && sudo apt install -y lvm2 qemu-utils" >&2
    exit 1
  fi
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

  ensure_vmdk_dependencies

  sudo modprobe nbd max_part=16
  cleanup_stale_vmdk_state
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
    if ! mount_candidate_readonly "$candidate" "$candidate_fstype" >/dev/null 2>&1; then
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
