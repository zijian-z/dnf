#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
WORKSPACE_ROOT=$(cd -- "$REPO_ROOT/.." && pwd)
DEFAULT_DUMP_PATH="$WORKSPACE_ROOT/tmp/db_dumps/vmdk_latest_all.sql.gz"
DEFAULT_OVERLAY_DIR="$REPO_ROOT/deploy/dnf/docker-compose/shenji_overlay"
INIT_SQL_TGZ="$REPO_ROOT/build/dnf_data/home/template/init/init_sql.tgz"
ROOTFS_TEMPLATE_DIR="$SCRIPT_DIR/rootfs_template"
DP_PAYLOAD_PATH="payload/dp_overlay.tgz"
TMP_ROOT=""

MAIN_SOURCE_DBS=(
  d_taiwan
  d_taiwan_secu
  d_technical_report
  tw
)

SERVER_SOURCE_DBS=(
  d_channel
  d_guild
  taiwan_cain
  taiwan_cain_2nd
  taiwan_cain_log
  taiwan_cain_web
  taiwan_cain_auction_gold
  taiwan_cain_auction_cera
  taiwan_login
  taiwan_prod
  taiwan_game_event
  taiwan_se_event
  taiwan_login_play
  taiwan_billing
)

usage() {
  cat <<'EOF'
用法:
  build_db_overlay.sh [VMDK导出的全库SQL(.sql/.sql.gz)] [overlay目录]

说明:
  1. 只比较表结构，不比较 INSERT 数据差异
  2. 会把 VMDK dump 拆成可直接用于清风初始化流程的每库 SQL
  3. 会生成:
     - meta/db_compare/*
     - rootfs/home/template/init/init_sql.tgz
     - rootfs/... 其余镜像 overlay 文件
EOF
}

dump_reader() {
  local dump_path="$1"

  case "$dump_path" in
    *.gz) gzip -cd "$dump_path" ;;
    *) cat "$dump_path" ;;
  esac
}

require_overlay_input() {
  local overlay_dir="$1"
  local rel

  for rel in data/dp data/game data/channel data/run data/libfd.so data/df_game_r; do
    [[ -e "$overlay_dir/$rel" ]] || {
      echo "缺少 overlay 输入: $overlay_dir/$rel" >&2
      exit 1
    }
  done
}

prepare_overlay_workspace() {
  local overlay_dir="$1"
  local work_dir="$2"
  local rel

  mkdir -p "$work_dir/data"

  for rel in data/game data/channel data/run data/libfd.so data/df_game_r; do
    if [[ -e "$overlay_dir/$rel" ]]; then
      mkdir -p "$(dirname "$work_dir/$rel")"
      cp -a "$overlay_dir/$rel" "$work_dir/$rel"
    fi
  done

  if [[ ! -f "$work_dir/data/df_game_r" && -f "$overlay_dir/optional/df_game_r.shenji" ]]; then
    mkdir -p "$work_dir/data"
    cp -a "$overlay_dir/optional/df_game_r.shenji" "$work_dir/data/df_game_r"
  fi

  if [[ -f "$overlay_dir/$DP_PAYLOAD_PATH" ]]; then
    tar -xzf "$overlay_dir/$DP_PAYLOAD_PATH" -C "$work_dir"
  elif [[ -d "$overlay_dir/data/dp" ]]; then
    mkdir -p "$work_dir/data"
    cp -a "$overlay_dir/data/dp" "$work_dir/data/dp"
  fi
}

split_vmdk_dump() {
  local dump_path="$1"
  local out_dir="$2"

  mkdir -p "$out_dir"

  dump_reader "$dump_path" | awk -v out_dir="$out_dir" '
function reset_output(db_name, file_path) {
  print "-- generated from VMDK full dump" > file_path
  print "-- source_db=" db_name >> file_path
  print "" >> file_path
}
/^-- Current Database: `/ {
  current=$0
  sub(/^-- Current Database: `/, "", current)
  sub(/`$/, "", current)
  out_file=out_dir "/" current ".sql"
  reset_output(current, out_file)
  next
}
current == "" { next }
/^CREATE DATABASE / { next }
/^USE `/ { next }
{
  print $0 >> out_file
}
'
}

extract_table_definitions() {
  local sql_path="$1"
  local out_dir="$2"

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  [[ -f "$sql_path" ]] || return 0

  awk -v out_dir="$out_dir" '
function normalize(line) {
  sub(/\r$/, "", line)
  sub(/[[:space:]]+$/, "", line)
  gsub(/AUTO_INCREMENT=[0-9]+/, "AUTO_INCREMENT=__IGNORED__", line)
  return line
}
/^CREATE TABLE `/ {
  table_name = $0
  sub(/^CREATE TABLE `/, "", table_name)
  sub(/`.*/, "", table_name)
  file_path = out_dir "/" table_name ".sql"
  print normalize($0) > file_path
  in_table = 1
  next
}
in_table {
  print normalize($0) >> file_path
  if ($0 ~ /;[[:space:]]*$/) {
    close(file_path)
    in_table = 0
    file_path = ""
  }
}
' "$sql_path"
}

table_names_from_defs_dir() {
  local defs_dir="$1"

  [[ -d "$defs_dir" ]] || return 0

  find "$defs_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' \
    | sed 's/\.sql$//' \
    | sort -u
}

compare_schema() {
  local qf_sql_dir="$1"
  local vmdk_sql_dir="$2"
  local compare_dir="$3"
  local db
  local db_list

  mkdir -p "$compare_dir"

  find "$qf_sql_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sed 's/\.sql$//' | sort -u > "$compare_dir/_qf_db_list.txt"
  find "$vmdk_sql_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sed 's/\.sql$//' | sort -u > "$compare_dir/_vmdk_db_list.txt"

  comm -23 "$compare_dir/_qf_db_list.txt" "$compare_dir/_vmdk_db_list.txt" > "$compare_dir/only_in_qf_databases.txt"
  comm -13 "$compare_dir/_qf_db_list.txt" "$compare_dir/_vmdk_db_list.txt" > "$compare_dir/only_in_vmdk_databases.txt"

  : > "$compare_dir/qf_only_tables.txt"
  : > "$compare_dir/vmdk_only_tables.txt"
  : > "$compare_dir/table_structure_diff.txt"
  printf 'db\tqf_only_table_count\tvmdk_only_table_count\tstructure_diff_count\n' > "$compare_dir/table_diff_counts.tsv"

  db_list=$(cat "$compare_dir/_qf_db_list.txt" "$compare_dir/_vmdk_db_list.txt" | sort -u)
  while IFS= read -r db; do
    local qf_defs_dir
    local vmdk_defs_dir
    local common_tables
    local table
    local qf_def
    local vmdk_def
    local diff_tmp
    local structure_diff_count=0
    [[ -n "$db" ]] || continue

    qf_tables="$compare_dir/.${db}.qf.tables"
    vmdk_tables="$compare_dir/.${db}.vmdk.tables"
    qf_only="$compare_dir/.${db}.qf_only.tables"
    vmdk_only="$compare_dir/.${db}.vmdk_only.tables"
    qf_defs_dir="$compare_dir/.${db}.qf_defs"
    vmdk_defs_dir="$compare_dir/.${db}.vmdk_defs"
    diff_tmp="$compare_dir/.${db}.structure.diff"

    extract_table_definitions "$qf_sql_dir/$db.sql" "$qf_defs_dir"
    extract_table_definitions "$vmdk_sql_dir/$db.sql" "$vmdk_defs_dir"
    table_names_from_defs_dir "$qf_defs_dir" > "$qf_tables"
    table_names_from_defs_dir "$vmdk_defs_dir" > "$vmdk_tables"
    comm -23 "$qf_tables" "$vmdk_tables" > "$qf_only"
    comm -13 "$qf_tables" "$vmdk_tables" > "$vmdk_only"

    qf_only_count=$(grep -c . "$qf_only" || true)
    vmdk_only_count=$(grep -c . "$vmdk_only" || true)
    common_tables=$(comm -12 "$qf_tables" "$vmdk_tables" || true)
    while IFS= read -r table; do
      [[ -n "$table" ]] || continue
      qf_def="$qf_defs_dir/$table.sql"
      vmdk_def="$vmdk_defs_dir/$table.sql"
      if ! diff -u \
        --label "qf:${db}.${table}" \
        --label "vmdk:${db}.${table}" \
        "$qf_def" \
        "$vmdk_def" > "$diff_tmp"; then
        structure_diff_count=$((structure_diff_count + 1))
        {
          echo "[$db.$table]"
          cat "$diff_tmp"
          echo
        } >> "$compare_dir/table_structure_diff.txt"
      fi
    done <<< "$common_tables"

    printf '%s\t%s\t%s\t%s\n' "$db" "$qf_only_count" "$vmdk_only_count" "$structure_diff_count" >> "$compare_dir/table_diff_counts.tsv"

    if [[ "$qf_only_count" -gt 0 ]]; then
      {
        echo "[$db]"
        cat "$qf_only"
        echo
      } >> "$compare_dir/qf_only_tables.txt"
    fi

    if [[ "$vmdk_only_count" -gt 0 ]]; then
      {
        echo "[$db]"
        cat "$vmdk_only"
        echo
      } >> "$compare_dir/vmdk_only_tables.txt"
    fi

    rm -f "$diff_tmp"
  done <<< "$db_list"

  {
    echo "schema_compare_mode=table_structure_only"
    echo "generated_at=$(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "ignored_statement_types=INSERT,REPLACE,LOCK TABLES,UNLOCK TABLES"
    echo "ignored_create_table_options=AUTO_INCREMENT(current value only)"
    echo
    echo "[qf_only_databases]"
    cat "$compare_dir/only_in_qf_databases.txt"
    echo
    echo "[vmdk_only_databases]"
    cat "$compare_dir/only_in_vmdk_databases.txt"
    echo
    echo "[table_diff_counts]"
    cat "$compare_dir/table_diff_counts.tsv"
  } > "$compare_dir/schema_summary.txt"

  rm -f "$compare_dir"/_qf_db_list.txt "$compare_dir"/_vmdk_db_list.txt "$compare_dir"/.*.tables "$compare_dir"/.*.structure.diff
  rm -rf "$compare_dir"/.*.qf_defs "$compare_dir"/.*.vmdk_defs
}

copy_vmdk_sql() {
  local src_dir="$1"
  local dst_dir="$2"
  local db

  mkdir -p "$dst_dir"

  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    case "$db" in
      mysql|phpmyadmin|cdcol|test) continue ;;
    esac
    if [[ "$db" == d_* || "$db" == taiwan_* || "$db" == "tw" || "$db" == "frida" ]]; then
      cp "$src_dir/$db.sql" "$dst_dir/$db.sql"
    fi
  done < <(find "$src_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sed 's/\.sql$//' | sort -u)
}

write_db_lists() {
  local sql_dir="$1"
  local missing_required=0
  local db

  : > "$sql_dir/main_db.list"
  : > "$sql_dir/server_group_db.list"
  : > "$sql_dir/extra_db.list"

  for db in "${MAIN_SOURCE_DBS[@]}"; do
    if [[ -f "$sql_dir/$db.sql" ]]; then
      printf '%s|%s.sql\n' "$db" "$db" >> "$sql_dir/main_db.list"
    elif [[ "$db" != "tw" ]]; then
      echo "缺少主库 SQL: $db.sql" >&2
      missing_required=1
    fi
  done

  for db in "${SERVER_SOURCE_DBS[@]}"; do
    if [[ -f "$sql_dir/$db.sql" ]]; then
      printf '%s|%s.sql\n' "$db" "$db" >> "$sql_dir/server_group_db.list"
    else
      echo "缺少大区库 SQL: $db.sql" >&2
      missing_required=1
    fi
  done

  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    grep -q "^$db|" "$sql_dir/main_db.list" 2>/dev/null && continue
    grep -q "^$db|" "$sql_dir/server_group_db.list" 2>/dev/null && continue
    printf '%s|%s.sql\n' "$db" "$db" >> "$sql_dir/extra_db.list"
  done < <(find "$sql_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sed 's/\.sql$//' | sort -u)

  [[ "$missing_required" -eq 0 ]] || exit 1
}

assemble_rootfs() {
  local source_overlay_dir="$1"
  local overlay_dir="$2"
  local generated_sql_tgz="$3"
  local rootfs_dir="$overlay_dir/rootfs"

  rm -rf "$rootfs_dir"
  mkdir -p "$rootfs_dir"
  cp -a "$ROOTFS_TEMPLATE_DIR"/. "$rootfs_dir"/

  mkdir -p \
    "$rootfs_dir/home/template/init" \
    "$rootfs_dir/home/template/init/run" \
    "$rootfs_dir/home/template/neople/game" \
    "$rootfs_dir/home/template/neople/channel" \
    "$rootfs_dir/opt/shenji-overlay-meta"

  cp "$source_overlay_dir/data/df_game_r" "$rootfs_dir/home/template/init/df_game_r"
  cp "$source_overlay_dir/data/libfd.so" "$rootfs_dir/home/template/neople/game/libfd.so"
  (
    cd "$source_overlay_dir/data"
    tar -czf "$rootfs_dir/home/template/init/dp.tgz" dp
  )
  cp -a "$source_overlay_dir/data/run"/. "$rootfs_dir/home/template/init/run"/
  cp -a "$source_overlay_dir/data/game"/. "$rootfs_dir/home/template/neople/game"/
  cp -a "$source_overlay_dir/data/channel"/. "$rootfs_dir/home/template/neople/channel"/
  cp "$generated_sql_tgz" "$rootfs_dir/home/template/init/init_sql.tgz"

  if [[ -f "$overlay_dir/data/Script.pvf" ]]; then
    cp "$overlay_dir/data/Script.pvf" "$rootfs_dir/home/template/init/Script.pvf"
  fi

  if [[ -d "$overlay_dir/meta" ]]; then
    cp -a "$overlay_dir/meta"/. "$rootfs_dir/opt/shenji-overlay-meta"/
  fi

  chmod +x \
    "$rootfs_dir/home/template/init/init.sh" \
    "$rootfs_dir/home/template/init/init_main_db.sh" \
    "$rootfs_dir/home/template/init/init_server_group_db.sh"
}

main() {
  local dump_path="${1:-$DEFAULT_DUMP_PATH}"
  local overlay_dir="${2:-$DEFAULT_OVERLAY_DIR}"
  local qf_sql_dir
  local vmdk_sql_dir
  local generated_sql_dir
  local generated_sql_tgz
  local compare_dir
  local source_overlay_dir

  if [[ "${dump_path:-}" == "-h" || "${dump_path:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  [[ -f "$dump_path" ]] || {
    echo "缺少 VMDK SQL dump: $dump_path" >&2
    exit 1
  }

  mkdir -p "$overlay_dir/meta"

  TMP_ROOT=$(mktemp -d "$overlay_dir/.builddb.XXXXXX")
  trap '[[ -n "${TMP_ROOT:-}" ]] && rm -rf "$TMP_ROOT"' EXIT

  qf_sql_dir="$TMP_ROOT/qf_sql"
  vmdk_sql_dir="$TMP_ROOT/vmdk_sql"
  generated_sql_dir="$TMP_ROOT/generated_init_sql"
  generated_sql_tgz="$TMP_ROOT/init_sql.tgz"
  compare_dir="$overlay_dir/meta/db_compare"
  source_overlay_dir="$TMP_ROOT/source_overlay"

  mkdir -p "$qf_sql_dir"
  prepare_overlay_workspace "$overlay_dir" "$source_overlay_dir"
  require_overlay_input "$source_overlay_dir"
  tar -xzf "$INIT_SQL_TGZ" -C "$qf_sql_dir"

  split_vmdk_dump "$dump_path" "$vmdk_sql_dir"
  compare_schema "$qf_sql_dir" "$vmdk_sql_dir" "$compare_dir"

  copy_vmdk_sql "$vmdk_sql_dir" "$generated_sql_dir"
  write_db_lists "$generated_sql_dir"

  tar -czf "$generated_sql_tgz" -C "$generated_sql_dir" .
  assemble_rootfs "$source_overlay_dir" "$overlay_dir" "$generated_sql_tgz"

  cat >"$overlay_dir/meta/db_overlay_summary.txt" <<EOF
generated_at=$(date '+%Y-%m-%d %H:%M:%S %z')
dump_path=$dump_path
schema_compare=$compare_dir/schema_summary.txt
qf_only_tables=$compare_dir/qf_only_tables.txt
vmdk_only_tables=$compare_dir/vmdk_only_tables.txt
table_structure_diff=$compare_dir/table_structure_diff.txt
rootfs_dir=$overlay_dir/rootfs
init_sql_tgz=$overlay_dir/rootfs/home/template/init/init_sql.tgz
EOF

  cat <<EOF
数据库 overlay 生成完成:
  dump: $dump_path
  compare: $compare_dir/schema_summary.txt
  rootfs: $overlay_dir/rootfs

说明:
  1. 对比报告只看表结构，不比较 INSERT 数据差异
  2. 结构级差异明细: $compare_dir/table_structure_diff.txt
  3. 镜像内 init_sql.tgz 已改为基于 VMDK dump 生成
  4. df_game_r / dp / run / channel / game 已写入 rootfs overlay
EOF
}

main "$@"
