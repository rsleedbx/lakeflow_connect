#!/usr/bin/env bash

set -x >/dev/null
if ./test.sh; then
  echo $?
  { set +x; } >/dev/null 2>&1
  echo "fail"
else
  echo $?
  { set +x; } >/dev/null 2>&1
  echo "success"
fi
