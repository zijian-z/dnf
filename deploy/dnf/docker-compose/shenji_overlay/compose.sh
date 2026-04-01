#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
PROJECT_FILE="$SCRIPT_DIR/docker-compose.project.yaml"
BASE_FILE="$SCRIPT_DIR/../basic/docker-compose.yaml"
OVERRIDE_FILE="$SCRIPT_DIR/docker-compose.override.yaml"
ARTIFACTS_DIR="$REPO_ROOT/.artifacts"

if [[ ! -f "$ARTIFACTS_DIR/shenji-overlay-dnf.tar.gz" ]]; then
  echo "缺少 $ARTIFACTS_DIR/shenji-overlay-dnf.tar.gz" >&2
  echo "请先执行 plugin/shenji_vmdk/update_from_vmdk.sh 生成 overlay 打包产物" >&2
  exit 1
fi

if [[ ! -f "$ARTIFACTS_DIR/shenji-overlay-gm.tar.gz" ]]; then
  echo "缺少 $ARTIFACTS_DIR/shenji-overlay-gm.tar.gz" >&2
  echo "请先执行 plugin/shenji_vmdk/update_from_vmdk.sh 生成 overlay 打包产物" >&2
  exit 1
fi

exec docker compose \
  --project-directory "$SCRIPT_DIR" \
  -f "$PROJECT_FILE" \
  -f "$BASE_FILE" \
  -f "$OVERRIDE_FILE" \
  "$@"
