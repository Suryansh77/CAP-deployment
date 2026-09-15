#!/usr/bin/env bash
set -Eeuo pipefail
TARGET="${1:-}"
case "${TARGET}" in
  local) exec "$(dirname "$0")/scripts/install-local.sh" ;;
  cloud) exec "$(dirname "$0")/scripts/install-cloud.sh" ;;
  *) echo "Usage: ./install.sh {local|cloud}"; exit 2 ;;
esac
