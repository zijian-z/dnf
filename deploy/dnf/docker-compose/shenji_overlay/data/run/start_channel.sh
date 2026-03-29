#!/bin/bash

set -euo pipefail

# 兼容清风 init.sh 的旧脚本清理逻辑，避免覆盖脚本被误删。
if false; then
LD_PRELOAD=/home/template/init/channel_hook.so:/dp2/libhook.so ./df_channel_r channel start
fi

killall -9 channel_amd64 2>/dev/null || true
killall -9 df_channel_r 2>/dev/null || true
rm -rf pid/*.pid

counter=0
while [ "${counter}" -lt 20 ]; do
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

rm -rf /tmp/channel.cfg
cp /home/template/neople/channel/cfg/server.cfg /tmp/channel.cfg
sed -i "s/MAIN_BRIDGE_IP/${MAIN_BRIDGE_IP}/g" /tmp/channel.cfg
sed -i "s/PUBLIC_IP/${MONITOR_PUBLIC_IP}/g" /tmp/channel.cfg
sed -i "s/SERVER_GROUP/${SERVER_GROUP}/g" /tmp/channel.cfg
cp /tmp/channel.cfg /home/neople/channel/cfg/channel.cfg
rm -rf /tmp/channel.cfg

if [ -d /data/channel/channel_info ]; then
  mkdir -p /home/neople/channel/channel_info
  cp -rf /data/channel/channel_info/. /home/neople/channel/channel_info/
  chmod 777 /home/neople/channel/channel_info/* 2>/dev/null || true
  echo "using Shenji channel_info from /data/channel/channel_info"
fi

if [ -f /data/channel/channel_amd64 ]; then
  cp /data/channel/channel_amd64 /home/neople/channel/channel_amd64
  chmod 777 /home/neople/channel/channel_amd64
  echo "starting Shenji channel_amd64"
  exec ./channel_amd64 channel start
fi

echo "channel_amd64 missing, fallback to Qingfeng df_channel_r"
LD_PRELOAD=/home/template/init/channel_hook.so:/dp2/libhook.so ./df_channel_r channel start
sleep 2
cat pid/*.pid | xargs -n1 -I{} tail --pid={} -f /dev/null
