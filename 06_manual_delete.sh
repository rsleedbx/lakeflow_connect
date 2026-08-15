#!/usr/bin/env bash
# Delete Databricks demo objects matching ${WHOAMI}_<8-hex-id> from 03 naming,
# and matching Postgres per-pipeline slots/publications (${WHOAMI}_<hex8> / _pub).
#
# Usage:
#   ./06_manual_delete.sh              # dry-run (default): list only
#   ./06_manual_delete.sh --apply      # delete jobs, pipelines, PG slots/pubs, schemas
#   ./06_manual_delete.sh --id 6a7f8a18
#   ./06_manual_delete.sh --id 6a7f8a18 --apply
#
# Match: ^${WHOAMI}_[0-9a-f]{8}(_|$)
# Scope: pipelines, jobs, UC schemas in TARGET_CATALOG, Postgres slots/pubs when configured.
# Out of scope: connections, foreign catalogs, ELOG_SCHEMA=${WHOAMI}, Azure resources.

set -u

_APPLY=0
_ID=""
_LFC_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
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

if [[ -n "${_ID}" ]]; then
  _PREFIX="${WHOAMI}_${_ID}"
  _NAME_RE="^${_PREFIX}(_|$)"
else
  _PREFIX="${WHOAMI}_"
  _NAME_RE="^${WHOAMI}_[0-9a-f]{8}(_|$)"
fi

_ENGINE="${SOURCE_TYPE:-${CONNECTION_TYPE:-}}"
_ENGINE="${_ENGINE^^}"

echo "Profile       : ${DATABRICKS_CONFIG_PROFILE}"
echo "WHOAMI        : ${WHOAMI}"
echo "TARGET_CATALOG: ${TARGET_CATALOG}"
echo "Name pattern  : ${_NAME_RE}"
echo "Engine        : ${_ENGINE:-unknown}"
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
# Discover Postgres per-pipeline slots / publications
# ---------------------------------------------------------------------------
echo '[]' >"${_TMP_PG_SLOTS}"
echo '[]' >"${_TMP_PG_PUBS}"
_pg_skip_reason=""

if [[ "${_ENGINE}" != "POSTGRESQL" ]]; then
  _pg_skip_reason="engine is not POSTGRESQL"
elif [[ -z "${DB_HOST_FQDN:-${DB_HOST:-}}" || -z "${DBA_USERNAME:-}" || -z "${DBA_PASSWORD:-}" ]]; then
  _pg_skip_reason="Postgres credentials not available"
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
  _slot_re="^${WHOAMI}_[0-9a-f]{8}$"
  _pub_re="^${WHOAMI}_[0-9a-f]{8}_pub$"
  if [[ -n "${_ID}" ]]; then
    _slot_re="^${WHOAMI}_${_ID}$"
    _pub_re="^${WHOAMI}_${_ID}_pub$"
  fi

  if DB_EXIT_ON_ERROR="PRINT_RETURN" DB_USERNAME="${DBA_USERNAME}" DB_PASSWORD="${DBA_PASSWORD}" \
    DB_CATALOG="${DB_CATALOG:-postgres}" SQLCLI -c \
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name ~ '${_slot_re}' ORDER BY 1" </dev/null
  then
    jq -R -s --arg who "${WHOAMI}" '
      [split("\n")[] | select(length>0)
       | capture("^(?<slot>" + $who + "_(?<id>[0-9a-f]{8}))$")
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
      jq -R -s --arg who "${WHOAMI}" '
        [split("\n")[] | select(length>0)
         | capture("^(?<pub>" + $who + "_(?<id>[0-9a-f]{8})_pub)$")
         | {publication_name: .pub, nine_char_id: .id}]
      ' /tmp/psql_stdout.$$ >"${_TMP_PG_PUBS}"
    else
      _pg_skip_reason="could not query pg_publication"
      echo '[]' >"${_TMP_PG_PUBS}"
    fi
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

if [[ "${_np}" -eq 0 && "${_nj}" -eq 0 && "${_ns}" -eq 0 && "${_nslot}" -eq 0 && "${_npub}" -eq 0 ]]; then
  echo "Nothing to delete."
  kill -INT $$
fi

echo "Applying deletes (jobs → pipelines → PG slots/pubs → schemas)..."
echo

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
