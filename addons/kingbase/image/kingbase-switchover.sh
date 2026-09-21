#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-without-candidate}"
leader_fqdn="${KB_REPLICATION_PRIMARY_POD_FQDN:-${KB_LEADER_POD_FQDN:-}}"
candidate_name=""
: "${KINGBASE_HA_API_TOKEN:?KINGBASE_HA_API_TOKEN is required}"

case "$mode" in
  with-candidate)
    candidate_name="${KB_SWITCHOVER_CANDIDATE_NAME:?KB_SWITCHOVER_CANDIDATE_NAME is required}"
    ;;
  without-candidate)
    ;;
  *)
    printf 'unknown switchover mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac

[ -n "$leader_fqdn" ] || { printf 'current primary FQDN is unavailable\n' >&2; exit 1; }
response="$(curl -fsS --max-time "${KINGBASE_SWITCHOVER_REQUEST_TIMEOUT_SECONDS:-90}" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${KINGBASE_HA_API_TOKEN}" \
  -X POST "http://${leader_fqdn}:8008/v1.0/switchover" \
  --data "{\"candidate\":\"${candidate_name}\"}")"

selected="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["candidate"])')"
candidate_fqdn="${KB_SWITCHOVER_CANDIDATE_FQDN:-}"
if [ -z "$candidate_fqdn" ] && [ -n "${KB_CLUSTER_NAME:-}" ] && [ -n "${KB_COMP_NAME:-}" ]; then
  candidate_fqdn="${selected}.${KB_CLUSTER_NAME}-${KB_COMP_NAME}-headless.${KB_NAMESPACE}.svc.cluster.local"
fi

# With an explicit candidate, wait for its role probe so the operation only
# succeeds after KubeBlocks can observe the new primary.
if [ -n "$candidate_fqdn" ]; then
  deadline=$((SECONDS + ${KINGBASE_SWITCHOVER_TIMEOUT_SECONDS:-80}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(curl -fsS --max-time 2 "http://${candidate_fqdn}:8008/v1.0/getrole" 2>/dev/null || true)" = "primary" ]; then
      printf 'switchover completed: %s\n' "$selected"
      exit 0
    fi
    sleep 2
  done
  printf 'timed out waiting for %s to become primary\n' "$selected" >&2
  exit 1
fi

printf 'switchover accepted: %s\n' "$selected"
