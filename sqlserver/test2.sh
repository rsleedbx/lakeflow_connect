#!/usr/bin/env bash

set -x
if ! az group show --resource-group "${WHOAMI}" >/tmp/az_stdout.$$ 2>/tmp/az_stderr.$$; then
  echo "fail"
fi
{ set +x; } 2>/dev/null

