#!/bin/sh

set -eu

cd /opt/godofgm
export GIN_MODE="${GIN_MODE:-release}"

while true; do
  ./godofgm -x -p /opt/godofgm/config/server.json && exit 0
  echo "godofgm exited, retry in 5s"
  sleep 5
done
