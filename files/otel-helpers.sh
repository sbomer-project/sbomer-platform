#!/usr/bin/env bash

# OTel bash tracing, logging, and metrics helpers for Tekton task steps.
# Sends spans, logs, and metrics to OTLP HTTP/JSON endpoint via curl.
# All telemetry includes resource attributes (service.name, service.version, host.name, step.name, telemetry.sdk.language, telemetry.sdk.name).
# Span attributes (step.name + key=value pairs from otel_start_span) are inherited by child spans, logs, and metrics.
# Metrics use sbomer.taskrun.<category>.<measurement> naming and delta counter type for exemplar support.
# Required env vars: OTEL_SERVICE_NAME, OTEL_SERVICE_VERSION, OTEL_EXPORTER_OTLP_ENDPOINT, TRACEPARENT

# Resource attributes JSON array.
# Called by otel_start_span.
# Used by otel_send_span, otel_log, and otel_metric.
otel_resource() {
  OTEL_RESOURCE=$(jq -nc \
    --arg service "$OTEL_SERVICE_NAME" \
    --arg version "${OTEL_SERVICE_VERSION:-unknown}" \
    --arg hostname "${HOSTNAME:-unknown}" \
    --arg step "$STEP_SPAN_NAME" '
    [{key:"service.name",value:{stringValue:$service}},
     {key:"service.version",value:{stringValue:$version}},
     {key:"host.name",value:{stringValue:$hostname}},
     {key:"telemetry.sdk.language",value:{stringValue:"bash"}},
     {key:"telemetry.sdk.name",value:{stringValue:"bash-otel"}},
     {key:"step.name",value:{stringValue:$step}}]')
}

# POSTs JSON payload to $OTEL_EXPORTER_OTLP_ENDPOINT/<path>.
# Backgrounded (&) so script doesn't block waiting for OTel collector.
# Uses --max-time 5 (seconds) as safety net to avoid hanging if OTel collector is slow.
# Args: path (e.g. v1/traces), json_payload
otel_send() {
  curl -sf --max-time 5 -o /dev/null -X POST "${OTEL_EXPORTER_OTLP_ENDPOINT}/$1" -H "Content-Type: application/json" -d "$2" &
}

# Converts key=value pairs into OTLP attributes JSON array.
# Values containing '=' are handled correctly (splits on first '=' only).
# Returns '[]' when called with no arguments.
# Args: [key=value...]
otel_attrs() {
  if [ $# -eq 0 ]; then echo "[]"; return; fi
  printf '%s\n' "$@" | jq -Rnc '[inputs | split("=") | {key:.[0], value:{stringValue:(.[1:] | join("="))}}]'
}

# Sends single OTLP span to OTel collector via HTTP/JSON.
# Args: trace_id, span_id, parent_span_id, name, start_ns, end_ns, status_code (1=OK, 2=ERROR), [attrs_json]
otel_send_span() {
  local span_json
  span_json=$(jq -nc \
    --argjson resource "$OTEL_RESOURCE" \
    --arg trace_id "$1" \
    --arg span_id "$2" \
    --arg parent_span_id "$3" \
    --arg name "$4" \
    --arg start_time "$5" \
    --arg end_time "$6" \
    --argjson status_code "$7" \
    --argjson attrs "${8:-[]}" '
    {resourceSpans:[{
      resource:{attributes:$resource},
      scopeSpans:[{scope:{name:"bash-otel"},spans:[{
        traceId:$trace_id, spanId:$span_id, parentSpanId:$parent_span_id,
        name:$name, kind:1,
        startTimeUnixNano:$start_time, endTimeUnixNano:$end_time,
        status:{code:$status_code},
        attributes:$attrs
      }]}]
    }]}') || return 0
  otel_send "v1/traces" "$span_json"
}

# Opens step-level parent span (e.g. 'step-inspect', 'step-generate', 'step-upload').
# Parses TRACEPARENT (W3C traceparent header: 00-<trace_id>-<span_id>-<trace_flags>) and creates
# new child span ID.
# Uses STEP_-prefixed vars so nested otel_trace calls don't overwrite them.
# Updates TRACEPARENT so downstream commands (e.g. curl with -H traceparent) propagate new context.
# Calls otel_resource to build OTEL_RESOURCE with step.name included.
# Span attributes (STEP_SPAN_ATTRS) are inherited by child spans (otel_trace),
# log record attributes (otel_log), and datapoint attributes (otel_metric).
# Must be paired with otel_end_span, typically via: trap 'otel_end_span $?' EXIT
# Args: span_name [key=value...] - span_name is auto-prefixed with 'step-'. key=value pairs are sent as span attributes.
otel_start_span() {
  STEP_TRACE_ID="${TRACEPARENT:3:32}"
  STEP_PARENT_SPAN_ID="${TRACEPARENT:36:16}"
  STEP_TRACE_FLAGS="${TRACEPARENT:53:2}"
  STEP_SPAN_ID=$(openssl rand -hex 8)
  STEP_SPAN_NAME="step-$1"; shift
  STEP_SPAN_ATTRS=$(otel_attrs "step.name=$STEP_SPAN_NAME" "$@")
  STEP_SPAN_START=$(date +%s%N)
  otel_resource
  export TRACEPARENT="00-${STEP_TRACE_ID}-${STEP_SPAN_ID}-${STEP_TRACE_FLAGS}"
}

# Closes step-level span opened by otel_start_span.
# Maps exit code to OTLP status (0 -> OK=1, non-zero -> ERROR=2) and posts span.
# Passes STEP_SPAN_ATTRS (set by otel_start_span) as span attributes.
# Waits for final backgrounded curl ($!) to flush before the script exits.
# Args: exit_code (0 = OK, non-zero = ERROR)
otel_end_span() {
  local status_code
  status_code=$([ "${1:-0}" -ne 0 ] && echo 2 || echo 1)
  otel_send_span "$STEP_TRACE_ID" "$STEP_SPAN_ID" "$STEP_PARENT_SPAN_ID" "$STEP_SPAN_NAME" "$STEP_SPAN_START" "$(date +%s%N)" "$status_code" "$STEP_SPAN_ATTRS"
  wait $! 2>/dev/null || true
}

# Wraps command in child span under current TRACEPARENT context.
# Saves and restores TRACEPARENT so sibling commands get correct parent.
# Wrapped command receives updated TRACEPARENT for further propagation.
# Captures and propagates original exit code - maps it to OTLP status.
# Inherits all span attributes from parent step span (set by otel_start_span).
# Args: span_name, command...
otel_trace() {
  local span_name="$1"; shift
  local trace_id="${TRACEPARENT:3:32}"
  local parent_span_id="${TRACEPARENT:36:16}"
  local trace_flags="${TRACEPARENT:53:2}"
  local span_id
  span_id=$(openssl rand -hex 8)
  local span_start
  span_start=$(date +%s%N)
  local parent_traceparent="$TRACEPARENT"
  TRACEPARENT="00-${trace_id}-${span_id}-${trace_flags}"
  local exit_code
  exit_code=0; "$@" || exit_code=$?
  TRACEPARENT="$parent_traceparent"
  local status_code
  status_code=$([ "$exit_code" -ne 0 ] && echo 2 || echo 1)
  otel_send_span "$trace_id" "$span_id" "$parent_span_id" "$span_name" "$span_start" "$(date +%s%N)" "$status_code" "$STEP_SPAN_ATTRS"
  return $exit_code
}

# Retries command with exponential backoff, wrapped in traced span via otel_trace.
# Entire retry loop (all attempts) is recorded as single span.
# Delay doubles after each failure, capped at max_delay.
# Defaults are controlled via env vars: RETRY_COUNT (30), RETRY_DELAY (1s), RETRY_MAX_DELAY (60s).
# Args: span_name, command...
retry() {
  local span_name=$1; shift
  local retries=${RETRY_COUNT:-30}
  local delay=${RETRY_DELAY:-1}
  local max_delay=${RETRY_MAX_DELAY:-60}
  local count=0
  inner() {
    until "$@"; do
      last_exit_code=$?
      count=$((count + 1))
      if [ "$count" -lt "$retries" ]; then
        sleep "$delay"
        delay=$((delay * 2))
        if [ "$delay" -gt "$max_delay" ]; then delay="$max_delay"; fi
      else
        return "$last_exit_code"
      fi
    done
  }
  otel_trace "$span_name" inner "$@"
}

# Sends single log line as OTLP log record.
# Includes STEP_TRACE_ID and STEP_SPAN_ID so logs are correlated with step's span.
# Includes all span attributes from otel_start_span as log record attributes.
# Must be called after otel_start_span.
# Args: log_line
otel_log() {
  local log_json
  log_json=$(jq -nc \
    --argjson resource "$OTEL_RESOURCE" \
    --arg trace_id "$STEP_TRACE_ID" \
    --arg span_id "$STEP_SPAN_ID" \
    --arg body "$1" \
    --arg time "$(date +%s%N)" \
    --argjson attrs "$STEP_SPAN_ATTRS" '
    {resourceLogs:[{
      resource:{attributes:$resource},
      scopeLogs:[{scope:{name:"bash-otel"},logRecords:[{
        timeUnixNano:$time,
        observedTimeUnixNano:$time,
        body:{stringValue:$body},
        traceId:$trace_id,
        spanId:$span_id,
        attributes:$attrs
      }]}]
    }]}') || return 0
  otel_send "v1/logs" "$log_json"
}

# Sends single delta counter data point with exemplar linking to current trace/span.
# Uses Sum with cumulative temporality so exemplars are preserved in Prometheus/Mimir (gauge exemplars are dropped).
# Metric names get _total suffix. Query with increase() for per-TaskRun values.
# Includes all span attributes from otel_start_span as datapoint attributes.
# Must be called after otel_start_span.
# Args: metric_name, value (integer)
otel_metric() {
  local metric_json
  metric_json=$(jq -nc \
    --argjson resource "$OTEL_RESOURCE" \
    --arg trace_id "$STEP_TRACE_ID" \
    --arg span_id "$STEP_SPAN_ID" \
    --arg name "$1" \
    --argjson value "$2" \
    --arg time "$(date +%s%N)" \
    --argjson attrs "$STEP_SPAN_ATTRS" '
    {resourceMetrics:[{
      resource:{attributes:$resource},
      scopeMetrics:[{scope:{name:"bash-otel"},metrics:[{
        name:$name,
        sum:{
          dataPoints:[{
            asInt:($value | tostring),
            timeUnixNano:$time,
            attributes:$attrs,
            exemplars:[{timeUnixNano:$time,traceId:$trace_id,spanId:$span_id,asInt:($value | tostring)}]
          }],
          aggregationTemporality:2,
          isMonotonic:true
        }
      }]}]
    }]}') || return 0
  otel_send "v1/metrics" "$metric_json"
}

# Replaces 'exec &> >(tee <file>)'. Redirects stdout/stderr through process substitution that:
# 1. Writes raw line to log file via tee
# 2. Streams raw line to OTel collector via otel_log (correlated by trace/span ID)
# 3. Echoes line to Kubernetes pod stdout prefixed with traceId/parentId/spanId, matching Quarkus log format
# Trace fields are only added to Kubernetes stdout, not to log file or OTLP log records.
# Must be called after otel_start_span so STEP_TRACE_ID, STEP_SPAN_ID, and STEP_PARENT_SPAN_ID are set.
# Args: log_path
otel_tee() {
  exec &> >(tee "$1" | while IFS= read -r line; do echo "traceId=$STEP_TRACE_ID parentId=$STEP_PARENT_SPAN_ID spanId=$STEP_SPAN_ID $line"; otel_log "$line"; done)
}