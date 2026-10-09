#!/bin/sh
# sqlplus has to start in this directory: @@ paths are relative to the process, not the script.
set -eu
cd "$(dirname "$0")"
exec sqlplus -S "${ORACLE_CONNECT:-test/test_pass@//localhost:1521/test_db}" @run.sql
