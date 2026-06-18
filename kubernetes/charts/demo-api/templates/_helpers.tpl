{{/*
Template helpers for the demo-api chart.
These centralize naming and the standard label sets so every resource is
consistent and matches the project SPEC.
*/}}

{{/* Base name, overridable via nameOverride. Truncated to 63 chars (DNS limit). */}}
{{- define "demo-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name used as the resource name prefix.
Honors fullnameOverride; otherwise combines release + chart name, avoiding
duplication when the release name already contains the chart name.
*/}}
{{- define "demo-api.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Chart name and version label value, e.g. demo-api-0.1.0. */}}
{{- define "demo-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels: the stable, immutable subset used in selectors and
matchLabels. These MUST NOT change across upgrades (Deployment selectors are
immutable).
*/}}
{{- define "demo-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Standard labels applied to every object. Combines the recommended
app.kubernetes.io/* set with the project-wide labels from the SPEC
(Project=eks-gitops-platform, ManagedBy, Environment).
*/}}
{{- define "demo-api.labels" -}}
helm.sh/chart: {{ include "demo-api.chart" . }}
{{ include "demo-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: eks-gitops-platform
project: eks-gitops-platform
managed-by: helm
environment: {{ .Values.environment | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Name of the ServiceAccount to use. */}}
{{- define "demo-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "demo-api.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
