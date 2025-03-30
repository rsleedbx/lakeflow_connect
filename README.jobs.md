How to control `jobs` that clean up resources created

- show jobs
```
jobs
```

```
jobs
[6]-  Running                 nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && databricks schemas delete --force "$TARGET_CATALOG.$TARGET_SCHEMA" >> ~/nohup.out 2>&1 &
[7]+  Running                 nohup sleep "${DELETE_PIPELINES_AFTER_SLEEP}" && databricks schemas delete --force "$STAGING_CATALOG.$STAGING_SCHEMA" >> ~/nohup.out 2>&1 &
```

- cancel jobs
```
kill %6
```