#!/usr/bin/env bash

set -euo pipefail

LAMPP_ROOT="${LAMPP_ROOT:-/opt/lampp}"
WORK_ROOT="${WORK_ROOT:-/work}"
DATA_DIR="${MYSQL_DATA_DIR:-$WORK_ROOT/mysql}"
RUN_DIR="${MYSQL_RUN_DIR:-$WORK_ROOT/run}"
TMP_DIR="${MYSQL_TMP_DIR:-$WORK_ROOT/tmp}"
CONF_PATH="${MYSQL_CONF_PATH:-$WORK_ROOT/my.cnf}"
DB_LIST_FILE="${MYSQLDUMP_DATABASES_FILE:-$WORK_ROOT/db_names.txt}"
OUTPUT_FILE="${OUTPUT_FILE:-/out/vmdk_latest_all.sql.gz}"
SOCKET_PATH="${MYSQL_SOCKET:-$RUN_DIR/mysql.sock}"
PORT="${MYSQL_PORT:-3306}"

MYSQL_BIN="$LAMPP_ROOT/bin/mysql"
MYSQLADMIN_BIN="$LAMPP_ROOT/bin/mysqladmin"
MYSQLDUMP_BIN="$LAMPP_ROOT/bin/mysqldump"
MYSQLD_BIN="$LAMPP_ROOT/sbin/mysqld"

MYSQL_PID=""

export PATH="$LAMPP_ROOT/bin:$PATH"
export LD_LIBRARY_PATH="$LAMPP_ROOT/lib:$LAMPP_ROOT/lib/mysql${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cleanup() {
  if [[ -x "$MYSQLADMIN_BIN" ]]; then
    "$MYSQLADMIN_BIN" --protocol=socket --socket="$SOCKET_PATH" shutdown >/dev/null 2>&1 || true
  fi

  if [[ -n "$MYSQL_PID" ]] && kill -0 "$MYSQL_PID" >/dev/null 2>&1; then
    kill "$MYSQL_PID" >/dev/null 2>&1 || true
    wait "$MYSQL_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

require_paths() {
  local path
  local -a required=(
    "$LAMPP_ROOT/bin/mysql"
    "$LAMPP_ROOT/bin/mysqladmin"
    "$LAMPP_ROOT/bin/mysqldump"
    "$LAMPP_ROOT/sbin/mysqld"
    "$DATA_DIR"
  )

  for path in "${required[@]}"; do
    if [[ ! -e "$path" ]]; then
      echo "missing required path: $path" >&2
      exit 1
    fi
  done
}

write_conf() {
  local recovery_level="$1"

  cat >"$CONF_PATH" <<EOF
[client]
port = $PORT
socket = $SOCKET_PATH

[mysqld]
user = root
basedir = $LAMPP_ROOT
datadir = $DATA_DIR
port = $PORT
socket = $SOCKET_PATH
pid-file = $RUN_DIR/mysqld.pid
log-error = $RUN_DIR/mysqld.err
tmpdir = $TMP_DIR
plugin_dir = $LAMPP_ROOT/lib/mysql/plugin/
skip-external-locking
skip-name-resolve
skip-grant-tables
bind-address = 127.0.0.1
server-id = 1
read_only
innodb_data_home_dir = $DATA_DIR/
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = $DATA_DIR/
innodb_buffer_pool_size = 64M
innodb_additional_mem_pool_size = 8M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 0
innodb_lock_wait_timeout = 50
EOF

  if [[ "$recovery_level" -gt 0 ]]; then
    printf 'innodb_force_recovery = %s\n' "$recovery_level" >>"$CONF_PATH"
  fi
}

wait_for_mysql() {
  local try

  for try in $(seq 1 60); do
    if "$MYSQLADMIN_BIN" --protocol=socket --socket="$SOCKET_PATH" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

stop_mysql() {
  "$MYSQLADMIN_BIN" --protocol=socket --socket="$SOCKET_PATH" shutdown >/dev/null 2>&1 || true

  if [[ -n "$MYSQL_PID" ]] && kill -0 "$MYSQL_PID" >/dev/null 2>&1; then
    kill "$MYSQL_PID" >/dev/null 2>&1 || true
    wait "$MYSQL_PID" >/dev/null 2>&1 || true
  fi

  MYSQL_PID=""
  rm -f "$SOCKET_PATH" "$RUN_DIR/mysqld.pid"
}

start_mysql() {
  local recovery_level

  mkdir -p "$RUN_DIR" "$TMP_DIR" "$(dirname "$OUTPUT_FILE")"
  rm -f "$SOCKET_PATH" "$RUN_DIR/mysqld.pid" "$RUN_DIR/mysqld.err"

  for recovery_level in 0 1 2 3 4 5 6; do
    write_conf "$recovery_level"
    "$MYSQLD_BIN" --defaults-file="$CONF_PATH" --user=root >/dev/null 2>&1 &
    MYSQL_PID=$!

    if wait_for_mysql; then
      echo "mysql started with innodb_force_recovery=$recovery_level"
      return 0
    fi

    stop_mysql
  done

  if [[ -f "$RUN_DIR/mysqld.err" ]]; then
    cat "$RUN_DIR/mysqld.err" >&2
  fi

  echo "failed to start temporary mysql for dump" >&2
  exit 1
}

load_db_list() {
  local db

  if [[ -s "$DB_LIST_FILE" ]]; then
    mapfile -t DBS <"$DB_LIST_FILE"
    return
  fi

  DBS=()
  while IFS= read -r db; do
    [[ -n "$db" ]] || continue
    DBS+=("$db")
  done < <(
    find "$DATA_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
      grep -E '^(d_.*|taiwan_.*|tw|frida)$' |
      sort
  )
}

dump_sql() {
  local tmp_sql="$WORK_ROOT/vmdk_latest_all.sql"

  load_db_list

  if (( ${#DBS[@]} == 0 )); then
    echo "no databases selected for export" >&2
    exit 1
  fi

  "$MYSQLDUMP_BIN" \
    --protocol=socket \
    --socket="$SOCKET_PATH" \
    --skip-lock-tables \
    --quick \
    --hex-blob \
    --databases "${DBS[@]}" >"$tmp_sql"

  if [[ "$OUTPUT_FILE" == *.gz ]]; then
    gzip -c "$tmp_sql" >"$OUTPUT_FILE"
  else
    cp "$tmp_sql" "$OUTPUT_FILE"
  fi
}

main() {
  require_paths
  start_mysql
  dump_sql
}

main "$@"
