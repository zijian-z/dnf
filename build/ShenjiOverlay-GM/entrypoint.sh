#!/bin/sh

set -eu

seed_root="${GODOFGM_SEED_ROOT:-/opt/godofgm-init}"
work_root="${GODOFGM_WORKDIR:-/opt/godofgm}"
default_admin_hash='$2a$14$8vWIEvq4bx/Zj2.Ch4Vip.CzfYpU9jo2lED8vsHjK2jre4zsmusX2'
seeded_db=0

mkdir -p "$work_root/data" "$work_root/log"

if [ -f "$seed_root/data/data.db" ] && [ ! -f "$work_root/data/data.db" ]; then
  cp "$seed_root/data/data.db" "$work_root/data/data.db"
  seeded_db=1
fi

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

warn_default_admin() {
  db_path="$1"
  row=$(sqlite3 "$db_path" "SELECT COALESCE(username, ''), COALESCE(_password, '') FROM user WHERE is_super_admin = 1 ORDER BY id LIMIT 1;")
  current_user=${row%%|*}
  current_hash=${row#*|}

  if [ "$current_user" = "admin" ] && [ "$current_hash" = "$default_admin_hash" ]; then
    echo "warning: GodOfGM super admin is still admin/123; set GODOFGM_ADMIN_PASSWORD before production use"
  fi
}

configure_admin_account() {
  db_path="$work_root/data/data.db"

  if [ ! -f "$db_path" ]; then
    echo "warning: GodOfGM data.db missing, skip admin account sync"
    return 0
  fi

  admin_user="${GODOFGM_ADMIN_USERNAME:-${GM_ACCOUNT:-}}"
  admin_password="${GODOFGM_ADMIN_PASSWORD:-${GM_PASSWORD:-}}"

  if [ -z "$admin_user" ] && [ -z "$admin_password" ]; then
    warn_default_admin "$db_path"
    return 0
  fi

  super_admin_id=$(sqlite3 "$db_path" "SELECT id FROM user WHERE is_super_admin = 1 ORDER BY id LIMIT 1;")
  if [ -n "$super_admin_id" ] && [ -z "$admin_user" ]; then
    admin_user=$(sqlite3 "$db_path" "SELECT username FROM user WHERE id = $super_admin_id LIMIT 1;")
  fi
  if [ -z "$admin_user" ]; then
    admin_user="admin"
  fi

  admin_user_esc=$(sql_escape "$admin_user")
  password_sql=""
  password_label="unchanged"

  if [ -n "$admin_password" ]; then
    admin_hash=$(htpasswd -nbBC 14 dummy "$admin_password" | cut -d: -f2-)
    admin_hash_esc=$(sql_escape "$admin_hash")
    password_sql=", _password = '$admin_hash_esc'"
    password_label="updated"
  fi

  if [ -n "$super_admin_id" ]; then
    conflict_id=$(sqlite3 "$db_path" "SELECT id FROM user WHERE username = '$admin_user_esc' AND id != $super_admin_id LIMIT 1;")
    if [ -n "$conflict_id" ]; then
      echo "error: GodOfGM admin username '$admin_user' already exists on id=$conflict_id" >&2
      exit 1
    fi
    sqlite3 "$db_path" "UPDATE user SET username = '$admin_user_esc', role = 'admin', is_super_admin = 1$password_sql WHERE id = $super_admin_id;"
  else
    if [ -z "$admin_password" ]; then
      echo "error: cannot create GodOfGM super admin without GODOFGM_ADMIN_PASSWORD or GM_PASSWORD" >&2
      exit 1
    fi
    next_id=$(sqlite3 "$db_path" "SELECT COALESCE(MAX(id), 0) + 1 FROM user;")
    sqlite3 "$db_path" "INSERT INTO user (id, username, _password, last_login_time, time, jwt_key, role, email, desc, is_super_admin) VALUES ($next_id, '$admin_user_esc', '$admin_hash_esc', NULL, CURRENT_TIMESTAMP, '', 'admin', '', '超级管理员', 1);"
    super_admin_id="$next_id"
  fi

  echo "configured GodOfGM super admin: username=$admin_user password=$password_label"

  if [ "$seeded_db" = "1" ]; then
    removed_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM user WHERE id != $super_admin_id;")
    sqlite3 "$db_path" "DELETE FROM user WHERE id != $super_admin_id;"
    echo "pruned GodOfGM seeded users: removed=$removed_count kept_id=$super_admin_id"
  fi
}

cd "$work_root"
configure_admin_account
exec ./godofgm -x -p "$work_root/config/server.json"
