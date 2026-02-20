cost diff of various trigger interval

min
3
5
15
30
60
120

to run the experiment,

create database
load the data
only the first pipeline creates CDC, the rest do not

```
export DELETE_DB_AFTER_SLEEP='480m'
export STOP_AFTER_SLEEP='300m'
export DELETE_PIPELINES_AFTER_SLEEP='300m'
. ./00_lakeflow_connect_env.sh
. ./sqlserver/01_azure_sqlserver.sh 
. ./sqlserver/02_sqlserver_configure.sh 


for interval in 3 5 15 30 60 120; do
  echo "INGESTION_PIPELINE_MIN_TRIGGER=$interval ingestion pipeline trigger"
  export INGESTION_PIPELINE_MIN_TRIGGER=$interval

  if [[ "$interval" == "3" ]]; then
    echo "DML_INTERVAL_SEC=1 starting sql_dml_generator"
    export DML_INTERVAL_SEC='1'  
  else
    echo "DML_INTERVAL_SEC=0 removing sql_dml_generator"
    export DML_INTERVAL_SEC='0'
  fi
  . ./03_lakeflow_connect_demo.sh 
done
```