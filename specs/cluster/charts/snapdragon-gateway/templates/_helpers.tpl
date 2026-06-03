{{- define "snapdragon-gateway.name" -}}
{{- .Values.instance.name | default .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "snapdragon-gateway.labels" -}}
app.kubernetes.io/name: {{ include "snapdragon-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: snapdragon.systems
app.kubernetes.io/component: gateway
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "snapdragon-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "snapdragon-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "snapdragon-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "snapdragon-gateway.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
