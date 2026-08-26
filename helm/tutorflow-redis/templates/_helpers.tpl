{{- define "tutorflow-redis.passwordSecretName" -}}
{{- .Values.redis.auth.existingSecret | default .Values.redis.auth.secretName -}}
{{- end }}

{{- define "tutorflow-redis.labels" -}}
app.kubernetes.io/name: tutorflow-redis
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}
