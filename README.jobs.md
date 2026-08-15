How to tear down demo resources

Use the manual delete script (dry-run by default):

```bash
./06_manual_delete.sh
./06_manual_delete.sh --apply
./06_manual_delete.sh --id 6a7f8a18 --apply
```

Order on `--apply`: load generator → jobs → pipelines → Postgres slots/pubs → UC schemas.

There is no deferred `nohup sleep … delete` background job from `03` anymore.
