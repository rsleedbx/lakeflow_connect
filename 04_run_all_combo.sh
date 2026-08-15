#!/usr/bin/env bash

# Prefer SOURCE_TYPE (demo); fall back to CONNECTION_TYPE from DB setup.
_engine="${SOURCE_TYPE:-${CONNECTION_TYPE:-}}"
_engine="${_engine^^}"
_previous_gateway_compute=""

for _gateway_compute in serverless classic; do
    export COMPUTE_GATEWAY="${_gateway_compute}"
    for _ingest_compute in serverless classic; do
        export COMPUTE_INGEST="${_ingest_compute}"

        for CDC_QBC in qbc_fc qbc_fcon cdc icdc; do
            # qbc does not have gateway, so skip the 2nd loop of _gateway_compute
            if [[ $CDC_QBC == "qbc_fc" || $CDC_QBC == "qbc_fcon" ]] && [[ $_previous_gateway_compute != '' ]]; then
                continue
            fi
            # Postgres CDC ingest requires serverless (classic fails create).
            if [[ "${COMPUTE_INGEST}" == "classic" && "${_engine}" == "POSTGRESQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: ${COMPUTE_INGEST} ${_compute} ${CDC_QBC} (Postgres CDC Ingest requires serverless)"
                continue
            fi
            if [[ "${COMPUTE_GATEWAY}" == "serverless" && "${_engine}" == "POSTGRESQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: ${COMPUTE_GATEWAY} ${COMPUTE_GATEWAY} ${CDC_QBC} (Postgres CDC gateway requires classic)"
                continue
            fi        
            export CDC_QBC
            echo "${COMPUTE_GATEWAY} ${COMPUTE_INGEST} ${CDC_QBC}"
            source ./03_lakeflow_connect_demo.sh
        done
    done
    _previous_gateway_compute=$COMPUTE_GATEWAY
done
