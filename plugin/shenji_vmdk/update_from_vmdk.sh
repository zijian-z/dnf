#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORKSPACE_ROOT=$(cd -- "$REPO_ROOT/.." && pwd)

DEFAULT_DUMP_PATH="$WORKSPACE_ROOT/tmp/db_dumps/vmdk_latest_all.sql.gz"
DEFAULT_OVERLAY_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
DEFAULT_ARTIFACTS_DIR="$REPO_ROOT/.artifacts"

ensure_docker_available() {
  local cmd
  local -a missing=()

  for cmd in docker sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "缺少 SQL 导出所需命令: ${missing[*]}" >&2
    echo "请先安装 Docker 和 sudo。" >&2
    echo "Ubuntu/Debian 可执行: sudo apt update && sudo apt install -y docker.io" >&2
    exit 1
  fi

  if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker 不可用，无法执行一键更新。" >&2
    echo "请先安装并启动 Docker。" >&2
    echo "Ubuntu/Debian 可执行:" >&2
    echo "  sudo apt update && sudo apt install -y docker.io" >&2
    echo "  sudo systemctl enable --now docker" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
用法:
  update_from_vmdk.sh <VMDK文件或已挂载根目录> [overlay目录] [输出目录] [dump输出路径]

说明:
  1. 先从 VMDK 同步神迹文件到 overlay 目录
  2. 再用 Docker 导出 VMDK 内的 MySQL SQL dump
  3. 然后沿用旧的数据库 compare/build 逻辑生成:
     - meta/db_compare/*
     - rootfs/home/template/init/init_sql.tgz
  4. 最后继续打包 DNF / GM 两份镜像构建工件
  5. VMDK 路径是唯一必填参数，其余路径都有默认值

示例:
  ./update_from_vmdk.sh /path/to/DNFServer.vmdk
  ./update_from_vmdk.sh /mnt/dnf-vmdk/root
EOF
}

main() {
  local source_input="${1:-}"
  local overlay_dir="${2:-$DEFAULT_OVERLAY_DIR}"
  local artifacts_dir="${3:-$DEFAULT_ARTIFACTS_DIR}"
  local dump_path="${4:-$DEFAULT_DUMP_PATH}"

  if [[ "${source_input:-}" == "-h" || "${source_input:-}" == "--help" || -z "${source_input:-}" ]]; then
    usage
    exit $([[ -n "${source_input:-}" ]] && echo 0 || echo 1)
  fi

  ensure_docker_available

  DP2_SUPPRESS_INTERMEDIATE_HINTS=1 "$SCRIPT_DIR/sync_from_vmdk.sh" "$source_input" "$overlay_dir"
  "$SCRIPT_DIR/export_vmdk_sql.sh" "$source_input" "$dump_path"
  "$SCRIPT_DIR/build_db_overlay.sh" "$dump_path" "$overlay_dir"
  "$SCRIPT_DIR/package_shenji_overlay.sh" "$overlay_dir" "$artifacts_dir"

  cat <<EOF
一键更新完成:
  source_input: $source_input
  dump_path: $dump_path
  overlay_dir: $overlay_dir
  artifacts_dir: $artifacts_dir

建议下一步:
  1. 检查 $overlay_dir/meta/db_compare/schema_summary.txt
  2. 运行 $overlay_dir/compose.sh up -d --build
EOF
}

main "$@"
