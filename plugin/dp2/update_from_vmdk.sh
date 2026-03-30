#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORKSPACE_ROOT=$(cd -- "$REPO_ROOT/.." && pwd)

DEFAULT_DUMP_PATH="$WORKSPACE_ROOT/tmp/db_dumps/vmdk_latest_all.sql.gz"
DEFAULT_OVERLAY_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
DEFAULT_ARTIFACTS_DIR="$REPO_ROOT/.artifacts"

usage() {
  cat <<'EOF'
用法:
  update_from_vmdk.sh <VMDK文件或已挂载根目录> [VMDK SQL dump(.sql/.sql.gz)] [overlay目录] [输出目录]

说明:
  1. 先同步神迹文件到 overlay 目录
  2. 再基于 VMDK dump 生成数据库 compare 报告和 rootfs overlay
  3. 最后打包 DNF / GM 两份镜像构建工件

示例:
  ./update_from_vmdk.sh /home/ubuntu/dnf/DNFServer.vmdk
  ./update_from_vmdk.sh /mnt/dnf-vmdk/root /tmp/vmdk_latest_all.sql.gz
EOF
}

main() {
  local source_input="${1:-}"
  local dump_path="${2:-$DEFAULT_DUMP_PATH}"
  local overlay_dir="${3:-$DEFAULT_OVERLAY_DIR}"
  local artifacts_dir="${4:-$DEFAULT_ARTIFACTS_DIR}"

  if [[ "${source_input:-}" == "-h" || "${source_input:-}" == "--help" || -z "${source_input:-}" ]]; then
    usage
    exit $([[ -n "${source_input:-}" ]] && echo 0 || echo 1)
  fi

  "$SCRIPT_DIR/sync_from_vmdk.sh" "$source_input" "$overlay_dir"
  "$SCRIPT_DIR/build_db_overlay.sh" "$dump_path" "$overlay_dir"
  "$SCRIPT_DIR/package_shenji_overlay.sh" "$overlay_dir" "$artifacts_dir"

  cat <<EOF
一键更新完成:
  overlay_dir: $overlay_dir
  artifacts_dir: $artifacts_dir

建议下一步:
  1. 检查 $overlay_dir/meta/db_compare/schema_summary.txt
  2. 运行 $overlay_dir/compose.sh up -d --build
EOF
}

main "$@"
