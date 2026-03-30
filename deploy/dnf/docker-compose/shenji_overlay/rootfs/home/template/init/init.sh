#!/usr/bin/env bash

set -euo pipefail

sync_file_if_missing() {
  local src="$1"
  local dst="$2"

  [[ -f "$src" ]] || return 0

  if [[ ! -f "$dst" ]]; then
    install -D -m 0644 "$src" "$dst"
  fi
}

sync_file_force() {
  local src="$1"
  local dst="$2"

  [[ -f "$src" ]] || return 0

  install -D -m 0755 "$src" "$dst"
}

sync_tree_force() {
  local src="$1"
  local dst="$2"

  [[ -d "$src" ]] || return 0

  mkdir -p "$dst"
  cp -af "$src"/. "$dst"/
}

rm -rf /home/template/init/init_sql
mkdir -p /home/template/init/init_sql
tar -zxf /home/template/init/init_sql.tgz -C /home/template/init/init_sql
echo "refresh init_sql success"

bash /home/template/init/init_local_db.sh
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "init local db failed!!!!!"
  exit -1
fi

bash /home/template/init/init_main_db.sh
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "init main db failed!!!!!"
  exit -1
fi

bash /home/template/init/init_server_group_db.sh
error_code=$?
if [[ "$error_code" -ne 0 ]]; then
  echo "init server group db failed!!!!!"
  exit -1
fi

if [[ ! -f /data/Script.pvf ]]; then
  if [[ ! -f /home/template/init/Script.pvf ]] && [[ -f /home/template/init/Script.tgz ]]; then
    tar -zxf /home/template/init/Script.tgz -C /home/template/init/
  fi
  if [[ -f /home/template/init/Script.pvf ]]; then
    cp /home/template/init/Script.pvf /data/
    chmod 0644 /data/Script.pvf
    echo "seed Script.pvf from image overlay"
  else
    echo "warning: Script.pvf not found in image overlay"
  fi
else
  echo "Script.pvf already exists in volume, keep existing file"
fi

if [[ -f /home/template/init/df_game_r ]]; then
  install -D -m 0755 /home/template/init/df_game_r /data/df_game_r
  echo "refresh df_game_r from image overlay"
else
  echo "warning: df_game_r not found in image overlay"
fi

if [[ ! -f /data/privatekey.pem ]]; then
  openssl genrsa -out /data/privatekey.pem 2048
  openssl rsa -in /data/privatekey.pem -pubout -out /data/publickey.pem
  echo "init privatekey.pem and publickey.pem success (newly generated)"
else
  echo "privatekey.pem have already inited, do nothing!"
  if [[ ! -f /data/publickey.pem ]]; then
    openssl rsa -in /data/privatekey.pem -pubout -out /data/publickey.pem
    echo "init publickey.pem success (derived from existing privatekey.pem)"
  else
    echo "publickey.pem have already inited, do nothing!"
  fi
fi

sync_tree_force /home/template/init/dp /data/dp
echo "refresh dp overlay files"

rm -rf /etc/supervisor/conf.d/channel.conf
cp /etc/supervisor/conf.d/channel.conf.template /etc/supervisor/conf.d/channel.conf
numbers=$(echo "$OPEN_CHANNEL" | awk -F, '{for(i=1;i<=NF;i++){if($i~/-/){split($i,a,"-");for(j=a[1];j<=a[2];j++)printf j" "}else{printf $i" "}}}')
process_sequence=3
group_programs="channel"
echo "" >> /etc/supervisor/conf.d/channel.conf
for num in $numbers; do
  if [[ $num -eq 1 || $num -eq 6 || $num -eq 7 || ($num -ge 11 && $num -le 39) || ($num -ge 52 && $num -le 56) ]]; then
    if [[ $num -ge 11 && $num -le 51 ]]; then
      process_sequence=3
    else
      process_sequence=5
    fi
    if [[ $num -lt 10 ]]; then
      num="0$num"
    fi
    group_programs="$group_programs,game_$SERVER_GROUP_NAME$num"
    echo "" >> /etc/supervisor/conf.d/channel.conf
    echo "[program:game_$SERVER_GROUP_NAME$num]" >> /etc/supervisor/conf.d/channel.conf
    echo "command=/bin/bash -c \"/data/run/start_game.sh $num $process_sequence\"" >> /etc/supervisor/conf.d/channel.conf
    echo "directory=/home/neople/game" >> /etc/supervisor/conf.d/channel.conf
    echo "user=root" >> /etc/supervisor/conf.d/channel.conf
    echo "autostart=true" >> /etc/supervisor/conf.d/channel.conf
    echo "autorestart=true" >> /etc/supervisor/conf.d/channel.conf
    echo "stopasgroup=true" >> /etc/supervisor/conf.d/channel.conf
    echo "killasgroup=true" >> /etc/supervisor/conf.d/channel.conf
    echo "stdout_logfile=/data/log/game_$SERVER_GROUP_NAME$num.log" >> /etc/supervisor/conf.d/channel.conf
    echo "redirect_stderr=true" >> /etc/supervisor/conf.d/channel.conf
    echo "stdout_logfile_maxbytes=1MB" >> /etc/supervisor/conf.d/channel.conf
    echo "stderr_logfile_maxbytes=1MB" >> /etc/supervisor/conf.d/channel.conf
    echo "depend=channel" >> /etc/supervisor/conf.d/channel.conf
    continue
  fi
  echo "invalid channel number: $num"
done
echo "" >> /etc/supervisor/conf.d/channel.conf
echo "[group:dnf_channel]" >> /etc/supervisor/conf.d/channel.conf
echo "programs=$group_programs" >> /etc/supervisor/conf.d/channel.conf
echo "priority=999" >> /etc/supervisor/conf.d/channel.conf
echo "init channel.conf success"

if [[ ! -f /data/monitor_ip/auto_public_ip.sh ]]; then
  cp /home/template/init/monitor_ip/auto_public_ip.sh /data/monitor_ip/
  echo "init auto_public_ip.sh success"
else
  echo "auto_public_ip.sh have already inited, do nothing!"
fi

if [[ ! -f /data/monitor_ip/get_ddns_ip.sh ]]; then
  cp /home/template/init/monitor_ip/get_ddns_ip.sh /data/monitor_ip/
  echo "init get_ddns_ip.sh success"
else
  echo "get_ddns_ip.sh have already inited, do nothing!"
fi

for fp in /home/template/init/run/*.sh; do
  [[ -f "$fp" ]] || continue
  cp -af "$fp" /data/run/
  echo "refresh $(basename "$fp") from image overlay"
done

if [[ ! -f /data/daily_job/user_daily_script.sh ]]; then
  cp /home/template/init/daily_job/user_daily_script.sh /data/daily_job/
  echo "init user_daily_script.sh success"
else
  echo "user_daily_script.sh have already inited, do nothing!"
fi
