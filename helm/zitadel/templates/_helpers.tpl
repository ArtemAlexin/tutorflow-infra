{{- define "zitadel.fullname" -}}{{- .Release.Name | trunc 63 | trimSuffix "-" -}}{{- end -}}
{{- define "zitadel.labels" -}}
app.kubernetes.io/name: zitadel
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

