#!/usr/bin/env bash
set -Eeuo pipefail

# Submit one KubeBlocks 0.8 capacity operation after validating the HA cluster.
# KubeBlocks 0.8 uses spec.clusterRef; newer releases use clusterName instead.

usage() {
  cat <<'EOF'
Usage:
  scale-kb08.sh vertical --namespace <ns> --cluster <cluster> \
    --request-cpu <quantity> --request-memory <quantity> \
    --limit-cpu <quantity> --limit-memory <quantity> [--name <ops-name>] [--timeout <seconds>] [--dry-run]

  scale-kb08.sh volume --namespace <ns> --cluster <cluster> \
    --storage <larger-quantity> [--name <ops-name>] [--timeout <seconds>] [--dry-run]

The operations address the Kingbase component and its data PVC. A vertical
operation replaces the main Kingbase container's complete CPU/memory resource
requirements. A volume operation is expansion-only and cannot be cancelled.
EOF
}

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

quantity_to_bytes() {
  local quantity="$1" number unit multiplier
  if [[ "$quantity" =~ ^([0-9]+)(Ki|Mi|Gi|Ti)?$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-}"
  else
    die "storage must be an integer Ki, Mi, Gi, or Ti quantity (for example: 1Gi)"
  fi
  case "$unit" in
    "") multiplier=1 ;;
    Ki) multiplier=1024 ;;
    Mi) multiplier=$((1024 * 1024)) ;;
    Gi) multiplier=$((1024 * 1024 * 1024)) ;;
    Ti) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
  esac
  printf '%s\n' "$((number * multiplier))"
}

cpu_to_millicores() {
  local quantity="$1" number suffix
  if [[ "$quantity" =~ ^([0-9]+)(m)?$ ]]; then
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]:-}"
  else
    die "CPU must be an integer core quantity or millicores (for example: 2 or 500m)"
  fi
  if [[ "$suffix" == "m" ]]; then
    printf '%s\n' "$number"
  else
    printf '%s\n' "$((number * 1000))"
  fi
}

namespace=""
cluster=""
operation="${1:-}"
request_cpu=""
request_memory=""
limit_cpu=""
limit_memory=""
storage=""
name=""
timeout_seconds=1800
dry_run=false

[[ $# -gt 0 ]] || { usage; exit 2; }
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="${2:-}"; shift 2 ;;
    --cluster) cluster="${2:-}"; shift 2 ;;
    --request-cpu) request_cpu="${2:-}"; shift 2 ;;
    --request-memory) request_memory="${2:-}"; shift 2 ;;
    --limit-cpu) limit_cpu="${2:-}"; shift 2 ;;
    --limit-memory) limit_memory="${2:-}"; shift 2 ;;
    --storage) storage="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --timeout) timeout_seconds="${2:-}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$operation" == "vertical" || "$operation" == "volume" ]] || { usage; exit 2; }
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "--namespace must be a DNS label"
[[ "$cluster" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "--cluster must be a DNS label"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive number of seconds"

require_command kubectl

if [[ "$operation" == "vertical" ]]; then
  [[ -n "$request_cpu" && -n "$request_memory" && -n "$limit_cpu" && -n "$limit_memory" ]] \
    || die "vertical scaling requires all CPU and memory request/limit options"
  request_cpu_millicores="$(cpu_to_millicores "$request_cpu")"
  limit_cpu_millicores="$(cpu_to_millicores "$limit_cpu")"
  request_memory_bytes="$(quantity_to_bytes "$request_memory")"
  limit_memory_bytes="$(quantity_to_bytes "$limit_memory")"
  (( limit_cpu_millicores >= request_cpu_millicores )) \
    || die "--limit-cpu must be greater than or equal to --request-cpu"
  (( limit_memory_bytes >= request_memory_bytes )) \
    || die "--limit-memory must be greater than or equal to --request-memory"
else
  [[ -n "$storage" ]] || die "volume expansion requires --storage"
fi

if [[ -z "$name" ]]; then
  suffix="$(date -u +%Y%m%d%H%M%S)"
  case "$operation" in
    vertical) name="${cluster}-vscale-${suffix}" ;;
    volume) name="${cluster}-vexpand-${suffix}" ;;
  esac
fi
[[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 63 ]] \
  || die "--name must be a DNS label of at most 63 characters"

phase="$(kubectl -n "$namespace" get cluster "$cluster" -o jsonpath='{.status.phase}')"
[[ "$phase" == "Running" ]] || die "Cluster $namespace/$cluster must be Running, got ${phase:-empty}"

kubectl -n "$namespace" wait --for=condition=Ready pod \
  -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase" \
  --timeout=120s >/dev/null || die "all Kingbase Pods must be Ready before a capacity operation"

role_rows="$(kubectl -n "$namespace" get pod \
  -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase" \
  -o go-template='{{range .items}}{{.metadata.name}} {{index .metadata.labels "kubeblocks.io/role"}}{{"\n"}}{{end}}')"
primary_count="$(printf '%s\n' "$role_rows" | awk '$2 == "primary" { count += 1 } END { print count + 0 }')"
standby_count="$(printf '%s\n' "$role_rows" | awk '$2 == "standby" { count += 1 } END { print count + 0 }')"
[[ "$primary_count" == 1 && "$standby_count" -ge 2 ]] \
  || die "expected one primary and at least two standbys before the operation; observed: ${role_rows:-none}"

active_ops="$(kubectl -n "$namespace" get opsrequest \
  -o custom-columns=NAME:.metadata.name,CLUSTER:.spec.clusterRef,PHASE:.status.phase --no-headers 2>/dev/null \
  | awk -v cluster="$cluster" '$2 == cluster && $3 !~ /^(Succeed|Failed|Aborted|Cancelled)$/ { print $1 }')"
[[ -z "$active_ops" ]] || die "another non-terminal OpsRequest targets $cluster: $(tr '\n' ' ' <<<"$active_ops")"

if [[ "$operation" == "volume" ]]; then
  target_bytes="$(quantity_to_bytes "$storage")"
  pvc_rows="$(kubectl -n "$namespace" get pvc \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase,apps.kubeblocks.io/vct-name=data" \
    -o custom-columns=NAME:.metadata.name,REQUEST:.spec.resources.requests.storage,SC:.spec.storageClassName --no-headers)"
  [[ -n "$pvc_rows" ]] || die "no Kingbase data PVCs found for $cluster"
  while read -r pvc current_storage storage_class; do
    [[ -n "$pvc" && -n "$current_storage" && -n "$storage_class" ]] || die "could not read PVC storage information"
    current_bytes="$(quantity_to_bytes "$current_storage")"
    (( target_bytes > current_bytes )) \
      || die "volume expansion is irreversible; $pvc is already $current_storage, not smaller than $storage"
    expansion_allowed="$(kubectl get storageclass "$storage_class" -o jsonpath='{.allowVolumeExpansion}')"
    [[ "$expansion_allowed" == "true" ]] \
      || die "StorageClass $storage_class does not declare allowVolumeExpansion=true"
  done <<<"$pvc_rows"
fi

if [[ "$operation" == "vertical" ]]; then
  manifest="$(cat <<EOF
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: $name
  namespace: $namespace
spec:
  clusterRef: $cluster
  type: VerticalScaling
  verticalScaling:
    - componentName: kingbase
      requests:
        cpu: $request_cpu
        memory: $request_memory
      limits:
        cpu: $limit_cpu
        memory: $limit_memory
EOF
)"
else
  manifest="$(cat <<EOF
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: $name
  namespace: $namespace
spec:
  clusterRef: $cluster
  type: VolumeExpansion
  volumeExpansion:
    - componentName: kingbase
      volumeClaimTemplates:
        - name: data
          storage: $storage
EOF
)"
fi

printf '%s\n' "$manifest"
if "$dry_run"; then
  printf '%s\n' "$manifest" | kubectl apply --server-side --dry-run=server -f -
  printf 'PASS  server-side dry-run accepted %s/%s\n' "$namespace" "$name"
  exit 0
fi

printf '%s\n' "$manifest" | kubectl apply --server-side -f -
printf 'Waiting for OpsRequest %s/%s ...\n' "$namespace" "$name"
deadline=$(( $(date +%s) + timeout_seconds ))
while :; do
  phase="$(kubectl -n "$namespace" get opsrequest "$name" -o jsonpath='{.status.phase}')"
  case "$phase" in
    Succeed)
      printf 'PASS  OpsRequest %s succeeded\n' "$name"
      break
      ;;
    Failed|Aborted|Cancelled)
      kubectl -n "$namespace" describe opsrequest "$name" >&2 || true
      die "OpsRequest $name finished with $phase"
      ;;
  esac
  (( $(date +%s) < deadline )) || die "timed out waiting for OpsRequest $name; inspect it with kubectl describe"
  sleep 5
done

kubectl -n "$namespace" wait --for=condition=Ready pod \
  -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase" \
  --timeout=120s >/dev/null || die "Kingbase Pods are not Ready after $name"

if [[ "$operation" == "vertical" ]]; then
  kubectl -n "$namespace" get pod \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase" \
    -o go-template='{{range .items}}{{.metadata.name}}{{range .spec.containers}}{{if eq .name "kingbase"}} request.cpu={{index .resources.requests "cpu"}} request.memory={{index .resources.requests "memory"}} limit.cpu={{index .resources.limits "cpu"}} limit.memory={{index .resources.limits "memory"}}{{end}}{{end}}{{"\n"}}{{end}}'
else
  kubectl -n "$namespace" get pvc \
    -l "app.kubernetes.io/instance=$cluster,apps.kubeblocks.io/component-name=kingbase,apps.kubeblocks.io/vct-name=data" \
    -o custom-columns=NAME:.metadata.name,REQUEST:.spec.resources.requests.storage,CAPACITY:.status.capacity.storage,CONDITIONS:.status.conditions[*].type
fi
