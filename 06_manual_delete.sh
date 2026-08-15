#!/usr/bin/env bash
# Delete Databricks demo objects matching ${WHOAMI}_<8-hex-id>_${ENGINE}_… from 03 naming,
# matching Postgres per-pipeline slots/publications for those ids (${WHOAMI}_<hex8> / _pub),
# and the load generator (PID file /tmp/lfc_load_generator_${WHOAMI}.pid).
#
# Usage:
#   ./06_manual_delete.sh              # dry-run (default): list only
#   ./06_manual_delete.sh --apply      # kill load gen, then jobs, pipelines, PG slots/pubs, schemas
#   ./06_manual_delete.sh --id 6a7f8a18
#   ./06_manual_delete.sh --id 6a7f8a18 --apply
#
# Match: ^${WHOAMI}_[0-9a-f]{8}_${ENGINE}(_|$)  (ENGINE from SOURCE_TYPE / CONNECTION_TYPE)
# Scope: load generator, pipelines, jobs, UC schemas in TARGET_CATALOG, Postgres slots/pubs when POSTGRESQL.
# Out of scope: connections, foreign catalogs, ELOG_SCHEMA=${WHOAMI}, Azure resources.

set -u

_APPLY=0
_ID=""
_LFC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) _APPLY=1; shift ;;
    --id)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9a-fA-F]{8}$ ]]; then
        echo "ERROR: --id requires 8 hex digits" >&2
        kill -INT $$
      fi
      _ID="$(echo "$2" | tr 'A-F' 'a-f')"
      shift 2
      ;;
    -h|--help) usage; kill -INT $$ ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage >&2
      kill -INT $$
      ;;
  esac
done

# shellcheck source=00_lakeflow_connect_env.sh
source "${_LFC_REPO_ROOT}/00_lakeflow_connect_env.sh" || kill -INT $$

if ! DB_EXIT_ON_ERROR="" DBX auth describe; then
  echo "Databricks auth for profile '${DATABRICKS_CONFIG_PROFILE}' is not usable; running auth login..."
  databricks auth login --profile "${DATABRICKS_CONFIG_PROFILE}" || { echo "ERROR: auth login failed" >&2; kill -INT $$; }
  DB_EXIT_ON_ERROR="PRINT_EXIT" DBX auth describe
fi
DATABRICKS_HOST_NAME="$(jq -r '.details.host // empty' /tmp/dbx_stdout.$$)"
DATABRICKS_HOST_NAME="${DATABRICKS_HOST_NAME%/}"
if [[ -z "$DATABRICKS_HOST_NAME" || "$DATABRICKS_HOST_NAME" == "null" ]]; then
  echo "ERROR: could not resolve Databricks host from auth describe" >&2
  kill -INT $$
fi
export DATABRICKS_HOST_NAME

if [[ -z "${TARGET_CATALOG:-}" ]]; then
  TARGET_CATALOG="$(resolve_default_uc_catalog)"
fi
export TARGET_CATALOG

_ENGINE="${SOURCE_TYPE:-${CONNECTION_TYPE:-}}"
_ENGINE="${_ENGINE^^}"
if [[ -z "${_ENGINE}" ]]; then
  echo "ERROR: SOURCE_TYPE or CONNECTION_TYPE must be set (e.g. MYSQL, POSTGRESQL, SQLSERVER)" >&2
  kill -INT $$
fi

if [[ -n "${_ID}" ]]; then
  _PREFIX="${WHOAMI}_${_ID}_${_ENGINE}"
  _NAME_RE="^${WHOAMI}_${_ID}_${_ENGINE}(_|$)"
else
  _PREFIX="${WHOAMI}_"
  _NAME_RE="^${WHOAMI}_[0-9a-f]{8}_${_ENGINE}(_|$)"
fi

echo "Profile       : ${DATABRICKS_CONFIG_PROFILE}"
echo "WHOAMI        : ${WHOAMI}"
echo "TARGET_CATALOG: ${TARGET_CATALOG}"
echo "Engine        : ${_ENGINE}"
echo "Name pattern  : ${_NAME_RE}"
echo "Mode          : $([[ ${_APPLY} -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo

_FAILS=0
_TMP_PIPELINES="$(mktemp)"
_TMP_JOBS="$(mktemp)"
_TMP_SCHEMAS="$(mktemp)"
_TMP_PG_SLOTS="$(mktemp)"
_TMP_PG_PUBS="$(mktemp)"
trap 'rm -f "${_TMP_PIPELINES}" "${_TMP_JOBS}" "${_TMP_SCHEMAS}" "${_TMP_PG_SLOTS}" "${_TMP_PG_PUBS}"' EXIT

# ---------------------------------------------------------------------------
# Discover pipelines
# ---------------------------------------------------------------------------
_filter="name like '${WHOAMI}_%'"
if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX pipelines list-pipelines --filter "${_filter}"; then
  echo "[]" >"${_TMP_PIPELINES}"
else
  jq --arg re "${_NAME_RE}" '[.[]? | select(.name | test($re))]' /tmp/dbx_stdout.$$ >"${_TMP_PIPELINES}"
fi

# ---------------------------------------------------------------------------
# Discover jobs: exact-name lookups from IG pipeline names + *_cleanup
# (no workspace-wide jobs list — empty candidates means no jobs)
# ---------------------------------------------------------------------------
_jobs_all='[]'
_job_name_candidates="$(
  {
    jq -r '.[]? | select(.name | test("_IG$")) | .name' "${_TMP_PIPELINES}"
    jq -r --arg who "${WHOAMI}" '
      .[]? | .name
      | capture("^(?<p>" + $who + "_[0-9a-f]{8})") | .p + "_cleanup"
    ' "${_TMP_PIPELINES}"
  } | sort -u
)"
# If --id and no pipelines yet, still try cleanup + wildcard via list filter on WHOAMI_
if [[ -n "${_ID}" ]]; then
  _job_name_candidates="$(printf '%s\n%s_cleanup\n' "${_job_name_candidates}" "${WHOAMI}_${_ID}" | sed '/^$/d' | sort -u)"
fi

while IFS= read -r _jname; do
  [[ -z "${_jname}" ]] && continue
  if ! DB_EXIT_ON_ERROR="" DBX jobs list --name "${_jname}" --limit 25; then
    continue
  fi
  _jobs_all="$(jq -s --arg re "${_NAME_RE}" '
      .[0] + [.[1][]? | select((.settings.name // .name // "") | test($re))]
    ' <(echo "${_jobs_all}") /tmp/dbx_stdout.$$)"
done <<<"${_job_name_candidates}"

echo "${_jobs_all}" | jq 'unique_by(.job_id)' >"${_TMP_JOBS}"

# ---------------------------------------------------------------------------
# Discover schemas: candidates from pipeline/job name prefixes (${WHOAMI}_hex8)
# ---------------------------------------------------------------------------
_schema_names="$(
  {
    jq -r --arg who "${WHOAMI}" '
      .[]? | .name
      | capture("^(?<p>" + $who + "_[0-9a-f]{8})") | .p
    ' "${_TMP_PIPELINES}"
    jq -r --arg who "${WHOAMI}" '
      .[]? | (.settings.name // .name // "")
      | capture("^(?<p>" + $who + "_[0-9a-f]{8})") | .p
    ' "${_TMP_JOBS}"
  } | sort -u
)"

# Narrow by --id if set
if [[ -n "${_ID}" ]]; then
  _schema_names="$(echo "${_schema_names}" | grep -E "^${WHOAMI}_${_ID}$" || true)"
elif [[ -z "${_schema_names}" ]]; then
  # No pipelines/jobs: still probe schemas list page (filtered) is expensive; skip.
  :
fi

: >"${_TMP_SCHEMAS}"
while IFS= read -r _sname; do
  [[ -z "${_sname}" ]] && continue
  if DB_EXIT_ON_ERROR="" DBX schemas get "${TARGET_CATALOG}.${_sname}"; then
    jq -n --arg name "${_sname}" --arg full "${TARGET_CATALOG}.${_sname}" \
      '{name: $name, full_name: $full}' >>"${_TMP_SCHEMAS}"
  fi
done <<<"${_schema_names}"
# Normalize to JSON array
if [[ ! -s "${_TMP_SCHEMAS}" ]]; then
  echo '[]' >"${_TMP_SCHEMAS}"
else
  jq -s '.' "${_TMP_SCHEMAS}" >"${_TMP_SCHEMAS}.arr" && mv "${_TMP_SCHEMAS}.arr" "${_TMP_SCHEMAS}"
fi

# ---------------------------------------------------------------------------
# Discover Postgres per-pipeline slots / publications (ids from filtered pipelines)
# ---------------------------------------------------------------------------
echo '[]' >"${_TMP_PG_SLOTS}"
echo '[]' >"${_TMP_PG_PUBS}"
_pg_skip_reason=""

# Hex8 ids from engine-filtered pipelines/jobs (schemas use same prefix)
_allowed_ids="$(
  {
    jq -r --arg who "${WHOAMI}" '
      .[]? | .name
      | capture("^(?<p>" + $who + "_(?<id>[0-9a-f]{8}))_") | .id
    ' "${_TMP_PIPELINES}"
    jq -r --arg who "${WHOAMI}" '
      .[]? | (.settings.name // .name // "")
      | capture("^(?<p>" + $who + "_(?<id>[0-9a-f]{8}))_") | .id
    ' "${_TMP_JOBS}"
  } | sort -u
)"
if [[ -n "${_ID}" ]]; then
  _allowed_ids="$(printf '%s\n%s\n' "${_allowed_ids}" "${_ID}" | sed '/^$/d' | sort -u)"
fi

if [[ "${_ENGINE}" != "POSTGRESQL" ]]; then
  _pg_skip_reason="engine is not POSTGRESQL"
elif [[ -z "${DB_HOST_FQDN:-${DB_HOST:-}}" || -z "${DBA_USERNAME:-}" || -z "${DBA_PASSWORD:-}" ]]; then
  _pg_skip_reason="Postgres credentials not available"
elif [[ -z "${_allowed_ids}" ]]; then
  _pg_skip_reason="no matching pipeline/job ids for PG slot scope"
else
  # Fresh process may never have sourced 01_*; map SQLCLI → PSQL (defined in 00).
  SQLCLI() { PSQL "${@}"; }
  export -f SQLCLI
  SQLCLI_DBA() { DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" PSQL "${@}"; }
  export -f SQLCLI_DBA

  if ! declare -F db_drop_pipeline_slot_pub >/dev/null; then
    # shellcheck source=postgres/02_postgres_configure.sh
    PG_CONFIGURE_MAIN=0 source "${_LFC_REPO_ROOT}/postgres/02_postgres_configure.sh" || true
  fi

  # Query WHOAMI_* slots/pubs, then keep only allowed nine_char_ids
  _slot_re="^${WHOAMI}_[0-9a-f]{8}$"
  _pub_re="^${WHOAMI}_[0-9a-f]{8}_pub$"

  if DB_EXIT_ON_ERROR="PRINT_RETURN" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
    DB_CATALOG="${DB_CATALOG:-postgres}" SQLCLI -c \
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name ~ '${_slot_re}' ORDER BY 1" </dev/null
  then
    jq -R -s --arg who "${WHOAMI}" --arg ids "$(echo "${_allowed_ids}" | tr '\n' ' ')" '
      ($ids | split(" ") | map(select(length>0))) as $allow
      | [split("\n")[] | select(length>0)
         | capture("^(?<slot>" + $who + "_(?<id>[0-9a-f]{8}))$")
         | select(.id as $i | $allow | index($i) != null)
         | {slot_name: .slot, nine_char_id: .id}]
    ' /tmp/psql_stdout.$$ >"${_TMP_PG_SLOTS}"
  else
    _pg_skip_reason="could not query pg_replication_slots"
  fi

  if [[ -z "${_pg_skip_reason}" ]]; then
    if DB_EXIT_ON_ERROR="PRINT_RETURN" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
      DB_CATALOG="${DB_CATALOG:-postgres}" SQLCLI -c \
      "SELECT pubname FROM pg_publication WHERE pubname ~ '${_pub_re}' ORDER BY 1" </dev/null
    then
      jq -R -s --arg who "${WHOAMI}" --arg ids "$(echo "${_allowed_ids}" | tr '\n' ' ')" '
        ($ids | split(" ") | map(select(length>0))) as $allow
        | [split("\n")[] | select(length>0)
           | capture("^(?<pub>" + $who + "_(?<id>[0-9a-f]{8})_pub)$")
           | select(.id as $i | $allow | index($i) != null)
           | {publication_name: .pub, nine_char_id: .id}]
      ' /tmp/psql_stdout.$$ >"${_TMP_PG_PUBS}"
    else
      _pg_skip_reason="could not query pg_publication"
      echo '[]' >"${_TMP_PG_PUBS}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Discover load generator (env PID or /tmp/lfc_load_generator_${WHOAMI}.pid)
# ---------------------------------------------------------------------------
_LG_PID=""
_LG_PID_FILE="/tmp/lfc_load_generator_${WHOAMI}.pid"
if [[ -n "${LOAD_GENERATOR_PID:-}" ]] && kill -0 "${LOAD_GENERATOR_PID}" 2>/dev/null; then
  _LG_PID="${LOAD_GENERATOR_PID}"
elif [[ -f "${_LG_PID_FILE}" ]]; then
  _cand="$(tr -d '[:space:]' <"${_LG_PID_FILE}" || true)"
  if [[ -n "${_cand}" ]] && kill -0 "${_cand}" 2>/dev/null; then
    _LG_PID="${_cand}"
  fi
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
_np="$(jq 'length' "${_TMP_PIPELINES}")"
_nj="$(jq 'length' "${_TMP_JOBS}")"
_ns="$(jq 'length' "${_TMP_SCHEMAS}")"
_nslot="$(jq 'length' "${_TMP_PG_SLOTS}")"
_npub="$(jq 'length' "${_TMP_PG_PUBS}")"

echo "Load generator:"
if [[ -n "${_LG_PID}" ]]; then
  echo "  pid  ${_LG_PID}  (file ${_LG_PID_FILE})"
else
  echo "  (none)"
fi
echo
echo "Pipelines (${_np}):"
if [[ "${_np}" -eq 0 ]]; then
  echo "  (none)"
else
  jq -r --arg url "${DATABRICKS_HOST_NAME}" \
    '.[] | "  pipeline\t\(.name)\t\(.pipeline_id)\t\(.state // "")\t\($url)/pipelines/\(.pipeline_id)"' \
    "${_TMP_PIPELINES}"
fi
echo
echo "Jobs (${_nj}):"
if [[ "${_nj}" -eq 0 ]]; then
  echo "  (none)"
else
  jq -r --arg url "${DATABRICKS_HOST_NAME}" \
    '.[] | "  job\t\(.settings.name // .name)\t\(.job_id)\t\($url)/jobs/\(.job_id)"' \
    "${_TMP_JOBS}"
fi
echo
echo "Schemas (${_ns}):"
if [[ "${_ns}" -eq 0 ]]; then
  echo "  (none)"
else
  jq -r --arg url "${DATABRICKS_HOST_NAME}" --arg cat "${TARGET_CATALOG}" \
    '.[] | "  schema\t\(.full_name)\t\($url)/explore/data/\($cat)/\(.name)"' \
    "${_TMP_SCHEMAS}"
fi
echo
echo "Postgres slots (${_nslot}):"
if [[ -n "${_pg_skip_reason}" ]]; then
  echo "  (skipped: ${_pg_skip_reason})"
elif [[ "${_nslot}" -eq 0 ]]; then
  echo "  (none)"
else
  jq -r '.[] | "  slot\t\(.slot_name)\t\(.nine_char_id)"' "${_TMP_PG_SLOTS}"
fi
echo
echo "Postgres publications (${_npub}):"
if [[ -n "${_pg_skip_reason}" ]]; then
  echo "  (skipped: ${_pg_skip_reason})"
elif [[ "${_npub}" -eq 0 ]]; then
  echo "  (none)"
else
  jq -r '.[] | "  publication\t\(.publication_name)\t\(.nine_char_id)"' "${_TMP_PG_PUBS}"
fi
echo

if [[ "${_APPLY}" -eq 0 ]]; then
  echo "Dry-run only. Re-run with --apply to delete the objects listed above."
  kill -INT $$
fi

if [[ -z "${_LG_PID}" && "${_np}" -eq 0 && "${_nj}" -eq 0 && "${_ns}" -eq 0 && "${_nslot}" -eq 0 && "${_npub}" -eq 0 ]]; then
  echo "Nothing to delete."
  kill -INT $$
fi

echo "Applying deletes (load gen → jobs → pipelines → PG slots/pubs → schemas)..."
echo

# 0) Kill load generator first (stop DML before tearing down pipelines/slots)
if [[ -n "${_LG_PID}" ]]; then
  echo "load generator kill -9 ${_LG_PID}"
  if ! kill -9 "${_LG_PID}" 2>/dev/null; then
    echo "  WARN: load generator kill failed (continuing)" >&2
    _FAILS=$((_FAILS + 1))
  fi
  rm -f "${_LG_PID_FILE}"
elif [[ -f "${_LG_PID_FILE}" ]]; then
  rm -f "${_LG_PID_FILE}"
fi

# 1) Delete jobs
while IFS=$'\t' read -r _jid _jname; do
  [[ -z "${_jid}" ]] && continue
  echo "jobs delete ${_jname} (${_jid})"
  if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX jobs delete "${_jid}"; then
    echo "  WARN: jobs delete failed (continuing)" >&2
    _FAILS=$((_FAILS + 1))
  fi
done < <(jq -r '.[] | [.job_id, (.settings.name // .name)] | @tsv' "${_TMP_JOBS}")

# 2) Delete pipelines (no stop; cascade=true required for INGESTION_GATEWAY / MANAGED_INGESTION)
while IFS=$'\t' read -r _pid _pname; do
  [[ -z "${_pid}" ]] && continue
  echo "pipelines delete (cascade=true) ${_pname} (${_pid})"
  if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX api delete "/api/2.0/pipelines/${_pid}?cascade=true"; then
    echo "  WARN: pipelines delete failed (continuing)" >&2
    _FAILS=$((_FAILS + 1))
  fi
done < <(jq -r '.[] | [.pipeline_id, .name] | @tsv' "${_TMP_PIPELINES}")

# 3) Drop Postgres slots then publications (union of nine_char_ids from both lists)
if [[ -z "${_pg_skip_reason}" && ( "${_nslot}" -gt 0 || "${_npub}" -gt 0 ) ]]; then
  if ! declare -F db_drop_pipeline_slot_pub >/dev/null; then
    echo "  WARN: db_drop_pipeline_slot_pub not loaded; skipping PG drops" >&2
    _FAILS=$((_FAILS + 1))
  else
    _pg_ids="$(jq -r -s '
      [.[0][]?.nine_char_id, .[1][]?.nine_char_id] | unique | .[]
    ' "${_TMP_PG_SLOTS}" "${_TMP_PG_PUBS}")"
    while IFS= read -r _nid; do
      [[ -z "${_nid}" ]] && continue
      echo "pg drop slot/pub ${WHOAMI}_${_nid} / ${WHOAMI}_${_nid}_pub"
      if ! db_drop_pipeline_slot_pub "${_nid}"; then
        echo "  WARN: pg drop failed for ${_nid} (continuing)" >&2
        _FAILS=$((_FAILS + 1))
      fi
    done <<<"${_pg_ids}"
  fi
fi

# 4) Delete schemas
while IFS=$'\t' read -r _full; do
  [[ -z "${_full}" ]] && continue
  echo "schemas delete --force ${_full}"
  if ! DB_EXIT_ON_ERROR="PRINT_RETURN" DBX schemas delete --force "${_full}"; then
    echo "  WARN: schemas delete failed (continuing)" >&2
    _FAILS=$((_FAILS + 1))
  fi
done < <(jq -r '.[] | .full_name' "${_TMP_SCHEMAS}")

echo
if [[ "${_FAILS}" -gt 0 ]]; then
  echo "Finished with ${_FAILS} failure(s)." >&2
  kill -INT $$
fi
echo "Done."
kill -INT $$
