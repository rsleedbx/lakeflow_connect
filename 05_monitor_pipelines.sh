#!/usr/bin/env bash
# Monitor Databricks demo pipelines: state + per-update row stats.
#
# Usage:
#   ./05_monitor_pipelines.sh                 # all WHOAMI_<hex8> pipelines
#   ./05_monitor_pipelines.sh --id 6a807c2f
#   ./05_monitor_pipelines.sh --id 6a807c2f --updates 5
#   ./05_monitor_pipelines.sh --json
#
# Match: ^${WHOAMI}_[0-9a-f]{8}(_|$)
# Public REST only: GET /api/2.0/pipelines/{id}/events (INFO/WARN/ERROR).
# METRICS-level events (UI "Output records" for many ICDC flows) are omitted by
# the public API — this script reports INFO metrics + flow status + operation_progress.
# Stats from details.flow_progress.metrics when present:
#   num_output_rows / num_deleted_rows / num_upserted_rows / num_output_bytes /
#   backlog_bytes / backlog_records / backlog_files / backlog_seconds

set -u

_ID=""
_UPDATES=3
_JSON=0
_LFC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MAX_EVENT_PAGES=5
_EVENTS_PAGE_SIZE=200

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9a-fA-F]{8}$ ]]; then
        echo "ERROR: --id requires 8 hex digits" >&2
        kill -INT $$
      fi
      _ID="$(echo "$2" | tr 'A-F' 'a-f')"
      shift 2
      ;;
    --updates)
      if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: --updates requires a positive integer" >&2
        kill -INT $$
      fi
      _UPDATES="$2"
      shift 2
      ;;
    --json) _JSON=1; shift ;;
    -h|--help) usage; kill -INT $$ ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      kill -INT $$
      ;;
  esac
done

# shellcheck source=00_lakeflow_connect_env.sh
if [[ "${_JSON}" -eq 1 ]]; then
  source "${_LFC_REPO_ROOT}/00_lakeflow_connect_env.sh" >/dev/null || kill -INT $$
else
  source "${_LFC_REPO_ROOT}/00_lakeflow_connect_env.sh" || kill -INT $$
fi

if ! DB_EXIT_ON_ERROR="" DBX auth describe >/dev/null; then
  echo "Databricks auth for profile '${DATABRICKS_CONFIG_PROFILE}' is not usable; running auth login..." >&2
  databricks auth login --profile "${DATABRICKS_CONFIG_PROFILE}" || { echo "ERROR: auth login failed" >&2; kill -INT $$; }
  DB_EXIT_ON_ERROR="PRINT_EXIT" DBX auth describe >/dev/null
fi
DATABRICKS_HOST_NAME="$(jq -r '.details.host // empty' /tmp/dbx_stdout.$$)"
DATABRICKS_HOST_NAME="${DATABRICKS_HOST_NAME%/}"
if [[ -z "$DATABRICKS_HOST_NAME" || "$DATABRICKS_HOST_NAME" == "null" ]]; then
  echo "ERROR: could not resolve Databricks host from auth describe" >&2
  kill -INT $$
fi
export DATABRICKS_HOST_NAME

if [[ -n "${_ID}" ]]; then
  _NAME_RE="^${WHOAMI}_${_ID}(_|$)"
else
  _NAME_RE="^${WHOAMI}_[0-9a-f]{8}(_|$)"
fi

if [[ "${_JSON}" -eq 0 ]]; then
  echo "Profile : ${DATABRICKS_CONFIG_PROFILE}"
  echo "WHOAMI  : ${WHOAMI}"
  echo "Pattern : ${_NAME_RE}"
  echo "Updates : last ${_UPDATES} per pipeline"
  echo
fi

_TMP_PIPELINES="$(mktemp)"
_TMP_REPORT="$(mktemp)"
_TMP_UPDATES="$(mktemp)"
_TMP_EVENTS="$(mktemp)"
_TMP_ONE="$(mktemp)"
trap 'rm -f "${_TMP_PIPELINES}" "${_TMP_REPORT}" "${_TMP_UPDATES}" "${_TMP_EVENTS}" "${_TMP_ONE}" "${_TMP_REPORT}.n"' EXIT

# ---------------------------------------------------------------------------
# Discover pipelines (server-side filter + client hex8 / --id narrow)
# ---------------------------------------------------------------------------
_filter="name like '${WHOAMI}_%'"
if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines list-pipelines --filter "${_filter}" >/dev/null; then
  echo "[]" >"${_TMP_PIPELINES}"
else
  jq --arg re "${_NAME_RE}" '[.[]? | select(.name | test($re))] | sort_by(.name)' \
    /tmp/dbx_stdout.$$ >"${_TMP_PIPELINES}"
fi

_np="$(jq 'length' "${_TMP_PIPELINES}")"
if [[ "${_np}" -eq 0 ]]; then
  if [[ "${_JSON}" -eq 1 ]]; then
    echo '[]'
  else
    echo "No pipelines matched."
  fi
  kill -INT $$
fi

# ---------------------------------------------------------------------------
# Helpers: fetch updates + event metrics for one pipeline
# ---------------------------------------------------------------------------
fetch_updates_json() {
  local pid="$1"
  if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines list-updates "${pid}" --max-results "${_UPDATES}" >/dev/null; then
    echo '{"updates":[]}'
    return
  fi
  # CLI may return {updates:[...]} or a bare array
  jq 'if type=="array" then {updates: .} else . end | .updates |= (.[0:'"${_UPDATES}"'])' \
    /tmp/dbx_stdout.$$
}

# Collect flow_progress / operation_progress / error events via raw API; page up to cap.
# Writes JSON array to outfile (avoids ARG_MAX from --argjson with large payloads).
# Public REST returns INFO/WARN/ERROR only (no METRICS-level row counters).
fetch_metric_events_json() {
  local pid="$1"
  local outfile="$2"
  local page=0
  local token=""
  local qs next
  local page_file

  echo '[]' >"${outfile}"
  page_file="$(mktemp)"
  while [[ "${page}" -lt "${_MAX_EVENT_PAGES}" ]]; do
    qs="max_results=${_EVENTS_PAGE_SIZE}"
    if [[ -n "${token}" ]]; then
      qs="${qs}&page_token=${token}"
    fi
    if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api get "/api/2.0/pipelines/${pid}/events?${qs}" >/dev/null; then
      break
    fi
    jq '[.events[]? | select(
        .event_type == "flow_progress"
        or .event_type == "operation_progress"
        or .level == "ERROR"
        or (.details.update_progress.state // "") == "FAILED"
      )]' /tmp/dbx_stdout.$$ >"${page_file}"
    jq -s 'add' "${outfile}" "${page_file}" >"${outfile}.n" \
      && mv "${outfile}.n" "${outfile}"
    next="$(jq -r '.next_page_token // empty' /tmp/dbx_stdout.$$)"
    if [[ -z "${next}" ]]; then
      break
    fi
    token="${next}"
    page=$((page + 1))
  done
  rm -f "${page_file}"
}

# Build per-update flow stats from metric events + update list (file paths).
build_pipeline_report() {
  local name="$1"
  local pid="$2"
  local state="$3"
  local updates_file="$4"
  local events_file="$5"

  jq -n \
    --arg name "${name}" \
    --arg pid "${pid}" \
    --arg state "${state}" \
    --arg url "${DATABRICKS_HOST_NAME}/pipelines/${pid}" \
    --slurpfile updates_raw "${updates_file}" \
    --slurpfile events "${events_file}" \
    '
    ($updates_raw[0] | if type=="array" then {updates:.} else . end | .updates // []) as $updates
    | ($events[0] // []) as $events
    |
    def activity:
      .num_deleted_rows + .num_upserted_rows + .num_output_rows + .num_output_bytes +
      .backlog_bytes + .backlog_records + .backlog_files + .backlog_seconds;

    # latest metrics event per (update_id, flow_name) — metrics-bearing only
    def flow_rows:
      ($events
        | map(select(
            .event_type == "flow_progress"
            and .details.flow_progress.metrics != null
            and ((.details.flow_progress.metrics | type) == "object")
            and ((.details.flow_progress.metrics | length) > 0)
          ))
        | map({
            update_id: .origin.update_id,
            flow: (.origin.flow_name // "unknown"),
            ts: .timestamp,
            status: (.details.flow_progress.status // ""),
            num_output_rows: (.details.flow_progress.metrics.num_output_rows // 0),
            num_deleted_rows: (.details.flow_progress.metrics.num_deleted_rows // 0),
            num_upserted_rows: (.details.flow_progress.metrics.num_upserted_rows // 0),
            num_output_bytes: (.details.flow_progress.metrics.num_output_bytes // 0),
            backlog_bytes: (.details.flow_progress.metrics.backlog_bytes // 0),
            backlog_records: (.details.flow_progress.metrics.backlog_records // 0),
            backlog_files: (.details.flow_progress.metrics.backlog_files // 0),
            backlog_seconds: (.details.flow_progress.metrics.backlog_seconds // 0)
          })
        | group_by([.update_id, .flow])
        | map(
            # Prefer highest activity; tie-break by latest timestamp
            sort_by([activity, .ts]) | last
          )
        | map(select(activity > 0))
      );

    # latest flow_progress.status per (update_id, flow)
    def flow_statuses:
      ($events
        | map(select(
            .event_type == "flow_progress"
            and (.origin.flow_name // "") != ""
            and (.details.flow_progress.status // "") != ""
          ))
        | map({
            update_id: .origin.update_id,
            flow: .origin.flow_name,
            ts: .timestamp,
            status: .details.flow_progress.status
          })
        | group_by([.update_id, .flow])
        | map(sort_by(.ts) | last)
      );

    def truncate_msg($s):
      if ($s | type) != "string" then null
      elif ($s | length) <= 500 then $s
      else ($s[0:500] + "…")
      end;

    # Prefer update_progress FAILED summary, then ERROR messages, then flow FAILED, then update.cause
    def error_for($uid; $u):
      ($events | map(select((.origin.update_id // "") == $uid))) as $ev
      | (
          ($ev | map(select((.details.update_progress.state // "") == "FAILED") | .message) | map(select(. != null and . != "")) | .[0] // null)
          // ($ev | map(select(.level == "ERROR") | .message) | map(select(. != null and . != "")) | .[0] // null)
          // ($ev | map(select(((.details.flow_progress.status // "") | test("FAILED"; "i"))) | .message) | map(select(. != null and . != "")) | .[0] // null)
          // (if ($u.cause | type) == "string" and ($u.cause | length) > 0 then $u.cause else null end)
          // (if $u.error != null then ($u.error | tostring) else null end)
        )
      | truncate_msg(.);

    def ops_for($uid):
      ($events
        | map(select(
            (.origin.update_id // .origin.request_id // "") == $uid
            and .event_type == "operation_progress"
            and .details.operation_progress != null
          ))
        | map(.details.operation_progress as $op | {
            ts: .timestamp,
            type: ($op.type // ""),
            status: ($op.status // ""),
            cdc_discovery_latency_ms: (
              $op.direct_cdc_extraction_completion.cdc_discovery_latency_ms
              // $op.cdc_discovery_latency_ms
              // null
            ),
            pending_snapshots: (
              $op.direct_cdc_extraction_completion.pending_snapshots
              // null
            )
          })
        | map(select(.type != ""))
        | group_by(.type)
        | map(sort_by(.ts) | last)
        | map({type, status, cdc_discovery_latency_ms, pending_snapshots})
      );

    def stats_for($uid):
      (flow_rows | map(select(.update_id == $uid))) as $flows
      | (flow_statuses | map(select(.update_id == $uid) | {flow, status})) as $statuses
      | {
          flows: ($flows | map({
            flow,
            num_output_rows,
            num_deleted_rows,
            num_upserted_rows,
            num_output_bytes,
            backlog_bytes,
            backlog_records,
            backlog_files,
            backlog_seconds
          })),
          flow_statuses: $statuses,
          operations: ops_for($uid),
          total: {
            num_output_rows: ($flows | map(.num_output_rows) | add // 0),
            num_deleted_rows: ($flows | map(.num_deleted_rows) | add // 0),
            num_upserted_rows: ($flows | map(.num_upserted_rows) | add // 0),
            num_output_bytes: ($flows | map(.num_output_bytes) | add // 0),
            backlog_bytes: ($flows | map(.backlog_bytes) | add // 0),
            backlog_records: ($flows | map(.backlog_records) | add // 0),
            backlog_files: ($flows | map(.backlog_files) | add // 0),
            backlog_seconds: ($flows | map(.backlog_seconds) | add // 0)
          }
        };

    {
      name: $name,
      pipeline_id: $pid,
      state: $state,
      url: $url,
      updates: (
        $updates | map(
          . as $u
          | {
              update_id: $u.update_id,
              state: $u.state,
              creation_time: $u.creation_time,
              cause: ($u.cause // null),
              error: error_for($u.update_id; $u)
            }
            + stats_for($u.update_id)
        )
      )
    }
    '
}

# ---------------------------------------------------------------------------
# Collect report for all pipelines
# ---------------------------------------------------------------------------
echo '[]' >"${_TMP_REPORT}"

while IFS=$'\t' read -r _name _pid _state; do
  [[ -z "${_pid}" ]] && continue
  if [[ "${_JSON}" -eq 0 ]]; then
    echo "Fetching ${_name} (${_pid})..."
  else
    echo "Fetching ${_name} (${_pid})..." >&2
  fi
  fetch_updates_json "${_pid}" >"${_TMP_UPDATES}"
  fetch_metric_events_json "${_pid}" "${_TMP_EVENTS}"
  build_pipeline_report "${_name}" "${_pid}" "${_state}" "${_TMP_UPDATES}" "${_TMP_EVENTS}" \
    >"${_TMP_ONE}"
  jq -s '.[0] + [.[1]]' "${_TMP_REPORT}" "${_TMP_ONE}" >"${_TMP_REPORT}.n" \
    && mv "${_TMP_REPORT}.n" "${_TMP_REPORT}"
done < <(jq -r '.[] | [.name, .pipeline_id, (.state // "")] | @tsv' "${_TMP_PIPELINES}")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "${_JSON}" -eq 1 ]]; then
  cat "${_TMP_REPORT}"
  kill -INT $$
fi

_np_report="$(jq 'length' "${_TMP_REPORT}")"
for ((_i = 0; _i < _np_report; _i++)); do
  jq -r --argjson i "${_i}" '
    .[$i] |
    "================================================================================",
    "pipeline  \(.name)",
    "id        \(.pipeline_id)",
    "state     \(.state)",
    "url       \(.url)",
    ""
  ' "${_TMP_REPORT}"

  _nu="$(jq --argjson i "${_i}" '.[$i].updates | length' "${_TMP_REPORT}")"
  for ((_j = 0; _j < _nu; _j++)); do
    jq -r --argjson i "${_i}" --argjson j "${_j}" '
      .[$i].updates[$j] |
      "update \(.update_id)  state=\(.state)  created=\(.creation_time)"
    ' "${_TMP_REPORT}"

    _ustate="$(jq -r --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].state // ""' "${_TMP_REPORT}")"
    _uerr="$(jq -r --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].error // empty' "${_TMP_REPORT}")"
    _failed=0
    if [[ "${_ustate}" == "FAILED" || "${_ustate}" == "CANCELED" ]]; then
      _failed=1
    fi
    if [[ "${_failed}" -eq 1 && -n "${_uerr}" ]]; then
      echo "  error  ${_uerr}"
    fi

    _nf="$(jq --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].flows | length' "${_TMP_REPORT}")"
    _ns="$(jq --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].flow_statuses | length' "${_TMP_REPORT}")"
    _nop="$(jq --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].operations | length' "${_TMP_REPORT}")"

    if [[ "${_nf}" -gt 0 ]]; then
      # TSV -> column -t so adjacent zeros cannot render as "00" from tab stops
      jq -r --argjson i "${_i}" --argjson j "${_j}" '
        .[$i].updates[$j] |
        (
          ["flow", "num_output_rows", "num_deleted_rows", "num_upserted_rows", "num_output_bytes",
           "backlog_bytes", "backlog_records", "backlog_files", "backlog_seconds"],
          (.flows[] | [
            .flow,
            .num_output_rows,
            .num_deleted_rows,
            .num_upserted_rows,
            .num_output_bytes,
            .backlog_bytes,
            .backlog_records,
            .backlog_files,
            .backlog_seconds
          ]),
          ["TOTAL",
           .total.num_output_rows,
           .total.num_deleted_rows,
           .total.num_upserted_rows,
           .total.num_output_bytes,
           .total.backlog_bytes,
           .total.backlog_records,
           .total.backlog_files,
           .total.backlog_seconds]
        ) | @tsv
      ' "${_TMP_REPORT}" | column -t | sed 's/^/  /'
    elif [[ "${_ns}" -gt 0 ]]; then
      jq -r --argjson i "${_i}" --argjson j "${_j}" '
        .[$i].updates[$j] |
        (
          ["flow", "status"],
          (.flow_statuses[] | [.flow, .status])
        ) | @tsv
      ' "${_TMP_REPORT}" | column -t | sed 's/^/  /'
    elif [[ "${_failed}" -eq 0 || -z "${_uerr}" ]]; then
      echo "  (no flow_progress metrics or status in recent INFO events)"
    fi

    if [[ "${_nop}" -gt 0 ]]; then
      jq -r --argjson i "${_i}" --argjson j "${_j}" '
        .[$i].updates[$j].operations[] |
        (
          "  op  \(.type)  status=\(.status)"
          + (if .cdc_discovery_latency_ms != null then "  cdc_discovery_latency_ms=\(.cdc_discovery_latency_ms)" else "" end)
          + (if .pending_snapshots != null then "  pending_snapshots=\(.pending_snapshots)" else "" end)
        )
      ' "${_TMP_REPORT}"
    fi
    echo
  done
done

kill -INT $$
