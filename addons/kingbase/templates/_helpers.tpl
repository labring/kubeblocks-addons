{{- define "kingbase.name" -}}
kingbase
{{- end -}}

{{- define "kingbase.fullname" -}}
{{ include "kingbase.name" . }}
{{- end -}}

{{- define "kingbase.image" -}}
{{- if .Values.image.digest -}}
{{ printf "%s/%s@%s" .Values.image.registry .Values.image.repository .Values.image.digest }}
{{- else -}}
{{ printf "%s/%s:%s" .Values.image.registry .Values.image.repository .Values.image.tag }}
{{- end -}}
{{- end -}}

{{- define "kingbase.labels" -}}
app.kubernetes.io/name: {{ include "kingbase.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end -}}

{{- define "kingbase.clusterSelectorLabels" -}}
app.kubernetes.io/instance: {{ .Values.cluster.name }}
apps.kubeblocks.io/component-name: kingbase
{{- end -}}

{{- define "kingbase.serviceAccountName" -}}
{{- default .Values.cluster.name .Values.cluster.serviceAccountName -}}
{{- end -}}

{{- define "kingbase.configurationNamespace" -}}
{{- default .Release.Namespace .Values.configuration.namespace -}}
{{- end -}}
