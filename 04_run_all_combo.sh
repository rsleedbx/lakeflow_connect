#!/usr/bin/env bash

# Prefer SOURCE_TYPE (demo); fall back to CONNECTION_TYPE from DB setup.
_engine="${SOURCE_TYPE:-${CONNECTION_TYPE:-}}"
_engine="${_engine^^}"

_previous_gateway_compute=""
for _gateway_compute in serverless classic; do
    export COMPUTE_GATEWAY="${_gateway_compute}"

    _previous_ingest_compute=""
    for _ingest_compute in serverless classic; do
    export COMPUTE_INGEST="${_ingest_compute}"

        for CDC_QBC in qbc_fc qbc_fcon cdc icdc; do
            # qbc and icdc do not have gateway, so skip the 2nd loop of _gateway_compute
            if [[ $CDC_QBC == "qbc_fc" || $CDC_QBC == "qbc_fcon" || $CDC_QBC == "icdc" ]] && [[ $_previous_gateway_compute != '' ]]; then
                continue
            fi

            # these conditions fails to start the pipeline as of 8/15/26

            # Postgres CDC ingest requires serverless (classic fails create).
            if [[ "${COMPUTE_INGEST}" == "classic" && "${_engine}" == "POSTGRESQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (Postgres CDC ingest requires serverless)"
                continue
            fi
            if [[ "${COMPUTE_GATEWAY}" == "serverless" && "${_engine}" == "POSTGRESQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (Postgres CDC gateway requires classic)"
                continue
            fi
            # SQLSERVER managed ingest requires serverless: true.
            if [[ "${COMPUTE_INGEST}" == "classic" && "${_engine}" == "SQLSERVER" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (SQLSERVER ingest requires serverless)"
                continue
            fi

            # MYSQL managed ingest requires serverless: true.
            if [[ "${COMPUTE_INGEST}" == "classic" && "${_engine}" == "MYSQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (MYSQL ingest requires serverless)"
                continue
            fi

            # the following combos starts and fails at run time as of 8/15/26

            if [[ "${COMPUTE_GATEWAY}" == "serverless" && "${_engine}" == "MYSQL" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (MYSQL gateway fails on serverless)"
                continue
            fi
            if [[ "${COMPUTE_INGEST}" == "serverless" && "${_engine}" == "MYSQL" && "${CDC_QBC}" == "icdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (MYSQL ingest fails on serverless)"
                continue
            fi

            if [[ "${COMPUTE_GATEWAY}" == "serverless" && "${_engine}" == "SQLSERVER" && "${CDC_QBC}" == "cdc" ]]; then
                echo "skip: gateway=${COMPUTE_GATEWAY} ingest=${COMPUTE_INGEST} ${CDC_QBC} (MYSQL gateway fails on serverless)"
                continue
            fi

            export CDC_QBC
            echo "${COMPUTE_GATEWAY} ${COMPUTE_INGEST} ${CDC_QBC}"
            source ./03_lakeflow_connect_demo.sh
        done
        _previous_ingest_compute=$COMPUTE_INGEST
    done
    _previous_gateway_compute=$COMPUTE_GATEWAY
done
