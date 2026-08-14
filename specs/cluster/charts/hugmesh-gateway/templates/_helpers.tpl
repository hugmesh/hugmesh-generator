{{- define "hugmesh-gateway.name" -}}
{{- .Values.instance.name | default .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "hugmesh-gateway.labels" -}}
app.kubernetes.io/name: {{ include "hugmesh-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: hugmesh.net
app.kubernetes.io/component: gateway
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "hugmesh-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hugmesh-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "hugmesh-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "hugmesh-gateway.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
