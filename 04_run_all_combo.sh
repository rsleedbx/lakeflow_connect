#!/user/bin/env bash

for INGEST_COMPUTE in serverless classic; do
    for CDC_QBC in qbc_fc qbc_fcon cdc icdc; do 
        echo $INGEST_COMPUTE $CDC_QBC; 
        source ./03_lakeflow_connect_demo.sh 
    done
done