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
# Stats from pipelines events API details.flow_progress.metrics
#   (num_deleted_rows / num_upserted_rows / num_output_bytes /
#    backlog_bytes / backlog_records / backlog_files / backlog_seconds)

set -u

_ID=""
_UPDATES=3
_JSON=0
_LFC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MAX_EVENT_PAGES=5
_EVENTS_PAGE_SIZE=100

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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
trap 'rm -f "${_TMP_PIPELINES}" "${_TMP_REPORT}"' EXIT

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

# Collect flow_progress metrics events (with details) via raw API; page up to cap.
fetch_metric_events_json() {
  local pid="$1"
  local page=0
  local token=""
  local all='[]'
  local qs more next

  while [[ "${page}" -lt "${_MAX_EVENT_PAGES}" ]]; do
    qs="max_results=${_EVENTS_PAGE_SIZE}"
    if [[ -n "${token}" ]]; then
      qs="${qs}&page_token=${token}"
    fi
    if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api get "/api/2.0/pipelines/${pid}/events?${qs}" >/dev/null; then
      break
    fi
    more="$(jq '[.events[]? | select(
        .event_type == "flow_progress"
        and .details.flow_progress.metrics != null
      )]' /tmp/dbx_stdout.$$)"
    all="$(jq -n --argjson a "${all}" --argjson b "${more}" '$a + $b')"
    next="$(jq -r '.next_page_token // empty' /tmp/dbx_stdout.$$)"
    if [[ -z "${next}" ]]; then
      break
    fi
    token="${next}"
    page=$((page + 1))
  done
  echo "${all}"
}

# Build per-update flow stats from metric events + update list.
# stdin unused; args via env files / vars.
build_pipeline_report() {
  local name="$1"
  local pid="$2"
  local state="$3"
  local updates_json="$4"
  local events_json="$5"

  jq -n \
    --arg name "${name}" \
    --arg pid "${pid}" \
    --arg state "${state}" \
    --arg url "${DATABRICKS_HOST_NAME}/pipelines/${pid}" \
    --argjson updates "$(jq '.updates // []' <<<"${updates_json}")" \
    --argjson events "${events_json}" \
    '
    # latest metrics event per (update_id, flow_name)
    def flow_rows:
      ($events
        | map({
            update_id: .origin.update_id,
            flow: (.origin.flow_name // "unknown"),
            ts: .timestamp,
            status: (.details.flow_progress.status // ""),
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
            sort_by([(
              .num_deleted_rows + .num_upserted_rows + .num_output_bytes +
              .backlog_bytes + .backlog_records + .backlog_files + .backlog_seconds
            ), .ts]) | last
          )
        | map(select(
            .num_deleted_rows + .num_upserted_rows + .num_output_bytes +
            .backlog_bytes + .backlog_records + .backlog_files + .backlog_seconds > 0
          ))
      );

    def stats_for($uid):
      (flow_rows | map(select(.update_id == $uid))) as $flows
      | {
          flows: ($flows | map({
            flow,
            num_deleted_rows,
            num_upserted_rows,
            num_output_bytes,
            backlog_bytes,
            backlog_records,
            backlog_files,
            backlog_seconds
          })),
          total: {
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
              cause: ($u.cause // null)
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
  _updates_json="$(fetch_updates_json "${_pid}")"
  _events_json="$(fetch_metric_events_json "${_pid}")"
  _one="$(build_pipeline_report "${_name}" "${_pid}" "${_state}" "${_updates_json}" "${_events_json}")"
  jq -s '.[0] + [.[1]]' "${_TMP_REPORT}" <(echo "${_one}") >"${_TMP_REPORT}.n" \
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

    _nf="$(jq --argjson i "${_i}" --argjson j "${_j}" \
      '.[$i].updates[$j].flows | length' "${_TMP_REPORT}")"
    if [[ "${_nf}" -eq 0 ]]; then
      echo "  (no flow_progress metrics in recent events)"
    else
      # TSV -> column -t so adjacent zeros cannot render as "00" from tab stops
      jq -r --argjson i "${_i}" --argjson j "${_j}" '
        .[$i].updates[$j] |
        (
          ["flow", "num_deleted_rows", "num_upserted_rows", "num_output_bytes",
           "backlog_bytes", "backlog_records", "backlog_files", "backlog_seconds"],
          (.flows[] | [
            .flow,
            .num_deleted_rows,
            .num_upserted_rows,
            .num_output_bytes,
            .backlog_bytes,
            .backlog_records,
            .backlog_files,
            .backlog_seconds
          ]),
          ["TOTAL",
           .total.num_deleted_rows,
           .total.num_upserted_rows,
           .total.num_output_bytes,
           .total.backlog_bytes,
           .total.backlog_records,
           .total.backlog_files,
           .total.backlog_seconds]
        ) | @tsv
      ' "${_TMP_REPORT}" | column -t | sed 's/^/  /'
    fi
    echo
  done
done

kill -INT $$
