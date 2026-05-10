{{- define "openbao.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "openbao.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "openbao.labels" -}}
{{ include "openbao.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version }}"
{{- end }}

{{- define "openbao.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openbao.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "openbao.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openbao.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "openbao.mode" -}}
{{- if .Values.server.ha.enabled -}}
ha
{{- else if .Values.server.standalone.enabled -}}
standalone
{{- else if .Values.server.dev.enabled -}}
dev
{{- else -}}
standalone
{{- end }}
{{- end }}

{{- define "openbao.internalServiceName" -}}
{{- printf "%s-internal" (include "openbao.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "openbao.raftConfig" -}}
{{- $config := .Values.server.ha.raft.config }}
{{- $replicas := int .Values.server.ha.replicas }}
{{- $releaseName := .Release.Name }}
{{- $setNodeId := .Values.server.ha.raft.setNodeId }}
{{- $config | nindent 0 }}
{{- end }}
