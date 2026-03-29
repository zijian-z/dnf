#!/bin/bash

set -euo pipefail

channel_no=$1
process_sequence=$2
channel_name="${SERVER_GROUP_NAME}${channel_no}"

echo "channel_name is ${channel_name}"
echo "prepare to start ch.${channel_no}, process_sequence is ${process_sequence}"

counter=0
while [ "${counter}" -lt 30 ]; do
  if nc -zv "${MAIN_BRIDGE_IP}" 7000 2>&1 | grep succeeded >/dev/null; then
    echo "bridge 7000 port ready"
    break
  fi
  sleep 2
  counter=$((counter + 1))
done

while [ -z "$(cat /data/monitor_ip/MONITOR_PUBLIC_IP 2>/dev/null || true)" ]; do
  echo "wait set MONITOR_PUBLIC_IP, sleep 5s"
  sleep 5
done

MONITOR_PUBLIC_IP=$(cat /data/monitor_ip/MONITOR_PUBLIC_IP 2>/dev/null || true)
echo "MONITOR_PUBLIC_IP is ${MONITOR_PUBLIC_IP}"

if [ -d /data/game/channel_info ]; then
  mkdir -p /home/neople/game/channel_info
  cp -rf /data/game/channel_info/. /home/neople/game/channel_info/
  chmod 777 /home/neople/game/channel_info/* 2>/dev/null || true
  echo "using Shenji game channel_info from /data/game/channel_info"
fi

rm -rf "/tmp/${channel_name}.cfg"
cp /home/template/neople/game/cfg/server.template "/tmp/${channel_name}.cfg"
sed -i "s/MAIN_BRIDGE_IP/${MAIN_BRIDGE_IP}/g" "/tmp/${channel_name}.cfg"
sed -i "s/CHANNEL_NO/${channel_no}/g" "/tmp/${channel_name}.cfg"
sed -i "s/PROCESS_SEQUENCE/${process_sequence}/g" "/tmp/${channel_name}.cfg"
sed -i "s/PUBLIC_IP/${MONITOR_PUBLIC_IP}/g" "/tmp/${channel_name}.cfg"
sed -i "s/DEC_GAME_PWD/${DEC_GAME_PWD}/g" "/tmp/${channel_name}.cfg"
sed -i "s/SERVER_GROUP/${SERVER_GROUP}/g" "/tmp/${channel_name}.cfg"
cp "/tmp/${channel_name}.cfg" "/home/neople/game/cfg/${channel_name}.cfg"
rm -rf "/tmp/${channel_name}.cfg"

old_pid=$(pgrep -f "df_game_r ${channel_name} start" || true)
echo "ch.${channel_no} old pid is ${old_pid}"
if [ -n "${old_pid}" ]; then
  echo "old pid not empty, kill ${old_pid}"
  kill -9 "${old_pid}"
fi
rm -rf "pid/${channel_name}.pid"

preload_chain="/dp2/libhook.so"

# 神迹原始 run 语义: 游戏进程并不是挂 frida.so，而是挂 libfd.so。
if [ -f /data/libfd.so ]; then
  cp /data/libfd.so /home/neople/game/libfd.so
  chmod 777 /home/neople/game/libfd.so
  preload_chain="${preload_chain}:/home/neople/game/libfd.so"
  echo "using Shenji libfd.so from /data/libfd.so"
elif [ -f /home/neople/game/libfd.so ]; then
  preload_chain="${preload_chain}:/home/neople/game/libfd.so"
  echo "using existing /home/neople/game/libfd.so"
elif [ -f /home/neople/game/frida.so ]; then
  preload_chain="${preload_chain}:/home/neople/game/frida.so"
  echo "libfd.so missing, fallback to frida.so"
else
  echo "warning: no libfd.so/frida.so found, preload only /dp2/libhook.so"
fi

echo "LD_PRELOAD=${preload_chain}"
LD_PRELOAD="${preload_chain}" ./df_game_r "${channel_name}" start
sleep 2
cat "pid/${channel_name}.pid" | xargs -n1 -I{} tail --pid={} -f /dev/null
