#!/usr/bin/env bash

firewall_set() {
    printf -v DB_FIREWALL_CIDRS_CSV '%s,' "${DB_FIREWALL_CIDRS[@]}"
    DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"  # remove trailing ,
    if ! GCLOUD sql instances patch "${DB_HOST}" --authorized-networks="${DB_FIREWALL_CIDRS_CSV}"; then
        cat /tmp/gcloud_stderr.$$
        return 1
    fi
}

gcloud compute firewall-rules create ${WHOAMI}-fwr-22-1433 \
    --allow tcp:22,tcp:1433 \
    --source-ranges "${DB_FIREWALL_CIDRS_CSV}" \
    --target-tags ${WHOAMI}-fwr-22-1433 \
    --network default
