#!/bin/sh

set -eu

seed_root="${GODOFGM_SEED_ROOT:-/opt/godofgm-init}"
work_root="${GODOFGM_WORKDIR:-/opt/godofgm}"

mkdir -p "$work_root/data" "$work_root/log"

if [ -f "$seed_root/data/data.db" ] && [ ! -f "$work_root/data/data.db" ]; then
  cp "$seed_root/data/data.db" "$work_root/data/data.db"
fi

cd "$work_root"
exec ./godofgm -x -p "$work_root/config/server.json"
