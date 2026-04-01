#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORKSPACE_ROOT=$(cd -- "$REPO_ROOT/.." && pwd)
DEFAULT_DUMP_PATH="$WORKSPACE_ROOT/tmp/db_dumps/vmdk_latest_all.sql.gz"
EXPORTER_DIR="$SCRIPT_DIR/vmdk_sql_exporter"
EXPORTER_IMAGE_TAG="dof-vmdk-sql-exporter:local"

TMP_ROOT=""
CONTAINER_NAME=""

source "$SCRIPT_DIR/vmdk_mount_lib.sh"

usage() {
  cat <<'EOF'
用法:
  export_vmdk_sql.sh <VMDK文件或已挂载根目录> [dump输出路径(.sql/.sql.gz)]

说明:
  1. 使用 Docker 启动临时导出容器，不污染宿主机 MySQL 环境
  2. 使用 VMDK 自带的 /opt/lampp MySQL 二进制和复制出的数据目录做逻辑导出
  3. 导出完成后会自动关闭容器、清理临时目录，并卸载 VMDK

示例:
  ./export_vmdk_sql.sh /path/to/DNFServer.vmdk
  ./export_vmdk_sql.sh /path/to/DNFServer.vmdk /tmp/vmdk_latest_all.sql.gz
EOF
}

docker_cmd() {
  sudo docker "$@"
}

cleanup_export_workspace() {
  if [[ -n "$CONTAINER_NAME" ]]; then
    docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    CONTAINER_NAME=""
  fi

  if [[ -n "$TMP_ROOT" ]] && [[ -d "$TMP_ROOT" ]]; then
    sudo rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true
    TMP_ROOT=""
  fi
}

cleanup_all() {
  cleanup_export_workspace
  cleanup
}

ensure_docker_dependencies() {
  local cmd
  local -a missing=()

  ensure_vmdk_dependencies

  for cmd in docker sudo rsync realpath gzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "缺少 SQL 导出所需命令: ${missing[*]}" >&2
    echo "请先安装 Docker、sudo、rsync 与 gzip。" >&2
    echo "Ubuntu/Debian 可执行: sudo apt update && sudo apt install -y docker.io rsync gzip" >&2
    exit 1
  fi

  if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker 不可用，无法执行 VMDK SQL 导出。" >&2
    echo "请先安装并启动 Docker。" >&2
    echo "Ubuntu/Debian 可执行:" >&2
    echo "  sudo apt update && sudo apt install -y docker.io" >&2
    echo "  sudo systemctl enable --now docker" >&2
    exit 1
  fi
}

validate_lampp_mysql_root() {
  local source_root="$1"
  local rel
  local -a required=(
    "opt/lampp/bin/mysql"
    "opt/lampp/bin/mysqladmin"
    "opt/lampp/bin/mysqldump"
    "opt/lampp/sbin/mysqld"
    "opt/lampp/etc/my.cnf"
    "opt/lampp/var/mysql"
  )

  validate_source_root "$source_root"

  for rel in "${required[@]}"; do
    if [[ ! -e "$source_root/$rel" ]]; then
      echo "缺少导出 SQL 所需文件: $source_root/$rel" >&2
      exit 1
    fi
  done
}

prepare_tmp_workspace() {
  mkdir -p "$WORKSPACE_ROOT/tmp"
  TMP_ROOT=$(mktemp -d "$WORKSPACE_ROOT/tmp/vmdk_sql_export.XXXXXX")
  mkdir -p "$TMP_ROOT/mysql"
}

copy_mysql_datadir() {
  local source_root="$1"
  local mysql_src="$source_root/opt/lampp/var/mysql"

  sudo rsync -a \
    --delete \
    --exclude='*.pid' \
    --exclude='*.sock' \
    --exclude='*.err' \
    "$mysql_src"/ "$TMP_ROOT/mysql"/
  sudo chown -R "$(id -u):$(id -g)" "$TMP_ROOT"
}

write_db_list() {
  local db

  : > "$TMP_ROOT/db_names.txt"

  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    case "$db" in
      mysql|performance_schema|phpmyadmin|cdcol|test) continue ;;
    esac
    if [[ "$db" == d_* || "$db" == taiwan_* || "$db" == "tw" || "$db" == "frida" ]]; then
      printf '%s\n' "$db" >> "$TMP_ROOT/db_names.txt"
    fi
  done < <(find "$TMP_ROOT/mysql" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)

  if [[ ! -s "$TMP_ROOT/db_names.txt" ]]; then
    echo "没有在 VMDK 数据目录中识别出可导出的 DNF 数据库" >&2
    exit 1
  fi
}

build_exporter_image() {
  if [[ "${FORCE_REBUILD_VMDK_EXPORTER:-0}" != "1" ]] && docker_cmd image inspect "$EXPORTER_IMAGE_TAG" >/dev/null 2>&1; then
    return 0
  fi

  docker_cmd build -t "$EXPORTER_IMAGE_TAG" "$EXPORTER_DIR" >/dev/null
}

run_exporter() {
  local source_root="$1"
  local dump_path="$2"
  local output_dir output_file

  dump_path=$(realpath -m "$dump_path")
  output_dir=$(dirname "$dump_path")
  output_file=$(basename "$dump_path")

  mkdir -p "$output_dir"

  CONTAINER_NAME="dof-vmdk-sql-export-$$"
  docker_cmd run --rm \
    --name "$CONTAINER_NAME" \
    -v "$source_root/opt/lampp:/opt/lampp:ro" \
    -v "$TMP_ROOT:/work" \
    -v "$output_dir:/out" \
    -e OUTPUT_FILE="/out/$output_file" \
    -e MYSQL_DATA_DIR="/work/mysql" \
    -e MYSQLDUMP_DATABASES_FILE="/work/db_names.txt" \
    "$EXPORTER_IMAGE_TAG"
  CONTAINER_NAME=""
}

main() {
  local source_input="${1:-}"
  local dump_path="${2:-$DEFAULT_DUMP_PATH}"
  local source_root

  if [[ "${source_input:-}" == "-h" || "${source_input:-}" == "--help" || -z "${source_input:-}" ]]; then
    usage
    exit $([[ -n "${source_input:-}" ]] && echo 0 || echo 1)
  fi

  trap cleanup_all EXIT

  ensure_docker_dependencies

  if [[ "$source_input" == *.vmdk ]]; then
    source_root=$(attach_vmdk "$source_input")
  else
    source_root="$source_input"
  fi

  validate_lampp_mysql_root "$source_root"
  prepare_tmp_workspace
  copy_mysql_datadir "$source_root"
  write_db_list
  build_exporter_image
  run_exporter "$source_root" "$dump_path"

  cat <<EOF
SQL 导出完成:
  source_root: $source_root
  dump_path: $(realpath -m "$dump_path")
EOF
}

main "$@"
