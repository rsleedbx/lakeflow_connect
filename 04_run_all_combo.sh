#!/user/bin/env bash

for _compute in serverless classic; do
    GATEWAY_COMPUTE=${_compute}
    INGEST_COMPUTE=${_compute}
    for CDC_QBC in qbc_fc qbc_fcon cdc icdc; do 
        echo $GATEWAY_COMPUTE $INGEST_COMPUTE $CDC_QBC; 
        source ./03_lakeflow_connect_demo.sh 
    done
done