#!/usr/bin/env bash
set -Eeuo pipefail

role="$(curl -fsS --max-time 2 http://127.0.0.1:${KINGBASE_HA_HTTP_PORT:-8008}/v1.0/getrole)"
case "$role" in
  primary|standby)
    printf '%s\n' "$role"
    ;;
  *)
    printf 'HA manager returned invalid role: %s\n' "$role" >&2
    exit 1
    ;;
esac
