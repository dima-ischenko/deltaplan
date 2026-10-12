#!/bin/sh
# Load the suite into an Oracle container and run it.
# The host does not need sqlplus. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${ORACLE_CONTAINER:-dpl-oracle}"
connect="${ORACLE_CONNECT:-test/test_pass@//localhost:1521/FREEPDB1}"

docker exec "$container" mkdir -p /tmp/dpl/lib/oracle /tmp/dpl/tests/oracle /tmp/dpl/demo/oracle
docker cp lib/oracle/. "$container:/tmp/dpl/lib/oracle"
docker cp tests/oracle/. "$container:/tmp/dpl/tests/oracle"
docker cp demo/oracle/. "$container:/tmp/dpl/demo/oracle"
# @@path/file.sql is resolved from the working directory, so deploy runs from lib/oracle.
docker exec -w /tmp/dpl/lib/oracle "$container" \
    sqlplus -S "$connect" @rollback.sql
docker exec -w /tmp/dpl/lib/oracle "$container" \
    sqlplus -S "$connect" @deploy.sql
docker exec -w /tmp/dpl/tests/oracle "$container" \
    sqlplus -S "$connect" @run.sql
