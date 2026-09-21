#!/usr/bin/env bash
set -Eeuo pipefail

namespace="${KINGBASE_NAMESPACE:-kingbase-system}"
kubeblocks_namespace="${KUBEBLOCKS_NAMESPACE:-kb-system}"
storage_class="${KINGBASE_STORAGE_CLASS:-}"
image="${KINGBASE_IMAGE:-}"
license_secret="${KINGBASE_LICENSE_SECRET:-kingbase-license}"
tls_secret="${KINGBASE_TLS_SECRET:-kingbase-tls}"
ha_token_secret="${KINGBASE_HA_TOKEN_SECRET:-kingbase-ha-token}"
replicas="${KINGBASE_REPLICAS:-3}"
failed=0

pass() {
  printf 'PASS  %s\n' "$*"
}

warn() {
  printf 'WARN  %s\n' "$*" >&2
}

fail() {
  printf 'FAIL  %s\n' "$*" >&2
  failed=1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'FAIL  required command not found: %s\n' "$1" >&2
    exit 2
  }
}

check_secret_key() {
  local secret="$1" key="$2" encoded
  encoded="$(kubectl -n "$namespace" get secret "$secret" \
    -o "go-template={{index .data \"$key\"}}" 2>/dev/null || true)"
  if [[ -n "$encoded" ]]; then
    pass "Secret $namespace/$secret contains $key"
  else
    fail "Secret $namespace/$secret must contain a non-empty $key key"
  fi
}

require_command kubectl

if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  fail "cannot reach the Kubernetes API with the active kubeconfig"
fi

if kubectl get crd clusters.apps.kubeblocks.io >/dev/null 2>&1 \
  && kubectl get crd componentdefinitions.apps.kubeblocks.io >/dev/null 2>&1; then
  pass "KubeBlocks Cluster and ComponentDefinition CRDs are installed"
else
  fail "KubeBlocks 0.8 CRDs are missing"
fi

for deployment in kubeblocks kubeblocks-dataprotection; do
  if ! kubectl -n "$kubeblocks_namespace" get deployment "$deployment" >/dev/null 2>&1; then
    fail "KubeBlocks deployment $kubeblocks_namespace/$deployment does not exist"
    continue
  fi
  encryption_key_ref="$(kubectl -n "$kubeblocks_namespace" get deployment "$deployment" \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="DP_ENCRYPTION_KEY")].valueFrom.secretKeyRef.name}{"/"}{.spec.template.spec.containers[*].env[?(@.name=="DP_ENCRYPTION_KEY")].valueFrom.secretKeyRef.key}')"
  if [[ "$encryption_key_ref" == "kubeblocks-secret/dataProtectionEncryptionKey" ]]; then
    pass "$deployment uses the shared DataProtection encryption key"
  else
    fail "$deployment must set DP_ENCRYPTION_KEY from kubeblocks-secret/dataProtectionEncryptionKey"
  fi
done

if kubectl auth can-i create clusters.apps.kubeblocks.io -n "$namespace" | grep -qx yes; then
  pass "current identity can create Cluster resources in $namespace"
else
  fail "current identity cannot create Cluster resources in $namespace"
fi

if kubectl auth can-i create opsrequests.apps.kubeblocks.io -n "$namespace" | grep -qx yes; then
  pass "current identity can create OpsRequest resources in $namespace"
else
  fail "current identity cannot create OpsRequest resources in $namespace"
fi

if kubectl get namespace "$namespace" >/dev/null 2>&1; then
  pass "namespace $namespace exists"
else
  fail "namespace $namespace does not exist"
fi

if kubectl -n "$namespace" get secret "$license_secret" >/dev/null 2>&1; then
  pass "Secret $namespace/$license_secret exists"
  check_secret_key "$license_secret" "license.dat"
else
  fail "Secret $namespace/$license_secret does not exist"
fi

if kubectl -n "$namespace" get secret "$tls_secret" >/dev/null 2>&1; then
  pass "Secret $namespace/$tls_secret exists"
  check_secret_key "$tls_secret" "tls.crt"
  check_secret_key "$tls_secret" "tls.key"
  check_secret_key "$tls_secret" "ca.crt"
else
  fail "Secret $namespace/$tls_secret does not exist"
fi

if kubectl -n "$namespace" get secret "$ha_token_secret" >/dev/null 2>&1; then
  pass "Secret $namespace/$ha_token_secret exists"
  check_secret_key "$ha_token_secret" "token"
else
  fail "Secret $namespace/$ha_token_secret does not exist"
fi

if [[ -n "$image" ]]; then
  pass "Kingbase image reference supplied: $image"
else
  fail "KINGBASE_IMAGE is required; this script cannot verify registry pull credentials without creating a Pod"
fi

if [[ -n "$storage_class" ]] && kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
  pass "StorageClass $storage_class exists"
else
  fail "KINGBASE_STORAGE_CLASS is required and must name an existing StorageClass"
fi

if [[ -n "$storage_class" ]] && kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
  expansion_allowed="$(kubectl get storageclass "$storage_class" -o jsonpath='{.allowVolumeExpansion}')"
  if [[ "$expansion_allowed" == "true" ]]; then
    pass "StorageClass $storage_class supports online volume expansion"
  else
    fail "StorageClass $storage_class must set allowVolumeExpansion=true for the supported volume-expansion workflow"
  fi
fi

ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" { count += 1 } END { print count + 0 }')"
if (( ready_nodes >= replicas )); then
  pass "$ready_nodes Ready nodes satisfy the $replicas replica minimum"
else
  fail "only $ready_nodes Ready nodes are available; $replicas replicas require at least $replicas"
fi

zone_nodes="$(kubectl get nodes -o go-template='{{range .items}}{{if index .metadata.labels "topology.kubernetes.io/zone"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | sed '/^$/d' | wc -l | tr -d ' ')"
if (( zone_nodes >= replicas )); then
  pass "$zone_nodes nodes carry topology.kubernetes.io/zone labels"
else
  warn "only $zone_nodes nodes carry zone labels; hostname anti-affinity does not prove multi-zone HA"
fi

if kubectl get backuprepo -A -o jsonpath='{range .items[?(@.status.phase=="Ready")]}{.metadata.name}{"\n"}{end}' \
  | grep -q .; then
  pass "at least one BackupRepo is Ready"
else
  fail "no Ready BackupRepo was found"
fi

if [[ -n "$storage_class" ]]; then
  pending_claims="$(kubectl get pvc -A -o go-template='{{range .items}}{{if ne .status.phase "Bound"}}{{if eq .spec.storageClassName "'"$storage_class"'"}}{{.metadata.namespace}}/{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null || true)"
  if [[ -n "$pending_claims" ]]; then
    fail "StorageClass $storage_class already has Pending claims; confirm capacity before creating $replicas database PVCs"
    printf '%s\n' "$pending_claims" >&2
  fi
fi

if (( failed )); then
  printf '\nDeployment preflight failed. Do not install the chart until every FAIL is resolved.\n' >&2
  exit 1
fi

printf '\nDeployment preflight passed. Registry pullability and database behavior still require a real controlled deployment.\n'
