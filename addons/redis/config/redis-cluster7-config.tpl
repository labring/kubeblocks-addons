appendonly yes
cluster-enabled yes
cluster-config-file nodes.conf
cluster-allow-replica-migration no
cluster-node-timeout 5000
cluster-replica-validity-factor 0
cluster-require-full-coverage yes
cluster-allow-reads-when-down no

# maxmemory <bytes>
{{- $memory_limit := getContainerMemory (index $.podSpec.containers 0) }}
{{- if gt $memory_limit 0 }}
maxmemory {{ div (mul $memory_limit 8) 10 }}
{{- end }}
