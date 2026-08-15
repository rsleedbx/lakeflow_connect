#!/usr/bin/env bash

# Prefer SOURCE_TYPE (demo); fall back to CONNECTION_TYPE from DB setup.
_engine="${SOURCE_TYPE:-${CONNECTION_TYPE:-}}"
_engine="${_engine^^}"

for _compute in serverless classic; do
    export COMPUTE_GATEWAY="${_compute}"
    export COMPUTE_INGEST="${_compute}"
    for CDC_QBC in qbc_fc qbc_fcon cdc icdc; do
        # Postgres CDC ingest requires serverless (classic fails create).
        if [[ "${_compute}" == "classic" && "${_engine}" == "POSTGRESQL" && "${CDC_QBC}" == "cdc" ]]; then
            echo "skip: ${_compute} ${_compute} ${CDC_QBC} (Postgres CDC requires serverless)"
            continue
        fi
        export CDC_QBC
        echo "${COMPUTE_GATEWAY} ${COMPUTE_INGEST} ${CDC_QBC}"
        source ./03_lakeflow_connect_demo.sh
    done
done
