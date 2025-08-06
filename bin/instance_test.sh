#!/usr/bin/env bash

# for aws
for type in m5.large m5.xlarge m5.2xlarge m5.4xlarge; do
    GATEWAY_DRIVER_NODE="$type"
    echo $GATEWAY_DRIVER_NODE
    . ./03_lakeflow_connect_demo.sh
done

# for gcp
for type in e2-highmem-2 e2-highmem-4 e2-highmem-8 e2-highmem-16; do
    GATEWAY_DRIVER_NODE="$type"
    echo $GATEWAY_DRIVER_NODE
    . ./03_lakeflow_connect_demo.sh
done

# for azure
for type in Standard_E2ds_v6 Standard_E4d_v4 Standard_E8d_v4 Standard_E16d_v4; do
    GATEWAY_DRIVER_NODE="$type"
    echo $GATEWAY_DRIVER_NODE
    . ./03_lakeflow_connect_demo.sh
done
