#!/usr/bin/env bash

set -uo pipefail

SQL_DIR="/home/template/init/init_sql"
LIST_FILE="$SQL_DIR/server_group_db.list"

extract_mysql_error_code() {
  printf '%s\n' "$1" | grep -oE 'ERROR [0-9]+' | awk '{print $2}' | head -1
}

resolve_target_db() {
  case "$1" in
    d_channel) echo "d_channel_${SERVER_GROUP_DB}" ;;
    taiwan_cain) echo "taiwan_${SERVER_GROUP_DB}" ;;
    taiwan_cain_2nd) echo "taiwan_${SERVER_GROUP_DB}_2nd" ;;
    taiwan_cain_log) echo "taiwan_${SERVER_GROUP_DB}_log" ;;
    taiwan_cain_web) echo "taiwan_${SERVER_GROUP_DB}_web" ;;
    taiwan_cain_auction_gold) echo "taiwan_${SERVER_GROUP_DB}_auction_gold" ;;
    taiwan_cain_auction_cera) echo "taiwan_${SERVER_GROUP_DB}_auction_cera" ;;
    *) echo "$1" ;;
  esac
}

if [[ -z "${CUR_SG_DB_GAME_ALLOW_IP:-}" ]]; then
  CUR_SG_DB_GAME_ALLOW_IP=$(ip route | awk '/default/ { print $3 }')
  check_result=$(mysql --connect_timeout=2 -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u game 2>&1)
  error_code=$?
  if [[ "$error_code" -ne 0 ]]; then
    echo "try to get game allow ip....."
    mysql_error_code=$(extract_mysql_error_code "$check_result")
    if [[ "$mysql_error_code" == "1045" ]]; then
      CUR_SG_DB_GAME_ALLOW_IP=$(echo "$check_result" | awk -F"'" '{print $4}')
      echo "set CUR_SG_DB_GAME_ALLOW_IP=$CUR_SG_DB_GAME_ALLOW_IP"
    fi
  fi
fi

echo "init server group db $CUR_SG_DB_HOST:$CUR_SG_DB_PORT"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "missing server group db list: $LIST_FILE"
  exit -1
fi

while IFS='|' read -r source_db sql_file; do
  [[ -n "${source_db:-}" ]] || continue
  [[ "${source_db:0:1}" == "#" ]] && continue
  sql_path="$SQL_DIR/$sql_file"
  target_db=$(resolve_target_db "$source_db")

  if [[ ! -f "$sql_path" ]]; then
    echo "missing server group db sql: $sql_path"
    exit -1
  fi

  echo "prepare init $target_db from $sql_file....."
  check_result=$(mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u root -p"$CUR_SG_DB_ROOT_PASSWORD" -e "use $target_db" 2>&1)
  error_code=$?
  if [[ "$error_code" -eq 0 ]]; then
    echo "server group db: $target_db already inited."
  else
    mysql_error_code=$(extract_mysql_error_code "$check_result")
    if [[ "$mysql_error_code" == "1049" ]]; then
      mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u root -p"$CUR_SG_DB_ROOT_PASSWORD" <<EOF
CREATE SCHEMA IF NOT EXISTS \`$target_db\` DEFAULT CHARACTER SET utf8;
use \`$target_db\`;
source $sql_path;
flush privileges;
EOF
    else
      echo "server group db: can not connect to mysql service $CUR_SG_DB_HOST:$CUR_SG_DB_PORT"
      echo "$check_result"
      exit -1
    fi
  fi
done < "$LIST_FILE"

echo "server group db: flush privileges....."
mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u root -p"$CUR_SG_DB_ROOT_PASSWORD" <<EOF
delete from mysql.user where user='game' and host='%';
flush privileges;
grant all privileges on *.* to 'game'@'%' identified by '$DNF_DB_GAME_PASSWORD';
flush privileges;
EOF

echo "server group db: show db_connect config, server_group is $SERVER_GROUP"
mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u game -p"$DNF_DB_GAME_PASSWORD" <<EOF
select gc_type, gc_ip, gc_channel from taiwan_$SERVER_GROUP_DB.game_channel where gc_type=$SERVER_GROUP;
EOF

EXTENDED_USERS=()
IFS=',' read -r -a EXTENDED_USERS <<<"${DNF_DB_USER_EXTENDED_QF:-}"
for db_user_extended in "${EXTENDED_USERS[@]}"; do
  [[ -n "${db_user_extended:-}" ]] || continue
  echo "server group db: extended user: ${db_user_extended}, flush privileges....."
  mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u root -p"$CUR_SG_DB_ROOT_PASSWORD" <<EOF
delete from mysql.user where user='$db_user_extended' and host='$CUR_SG_DB_GAME_ALLOW_IP';
flush privileges;
grant all privileges on *.* to '$db_user_extended'@'$CUR_SG_DB_GAME_ALLOW_IP' identified by '$DNF_DB_GAME_PASSWORD';
flush privileges;
EOF
  echo "server group db: using extended user $db_user_extended to show db_connect config, server_group is $SERVER_GROUP"
  mysql -h "$CUR_SG_DB_HOST" -P "$CUR_SG_DB_PORT" -u "$db_user_extended" -p"$DNF_DB_GAME_PASSWORD" <<EOF
select gc_type, gc_ip, gc_channel from taiwan_$SERVER_GROUP_DB.game_channel where gc_type=$SERVER_GROUP;
EOF
done

echo "server_group_db: init server group-$SERVER_GROUP($SERVER_GROUP_DB) done."
