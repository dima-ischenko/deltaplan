#!/bin/sh
# Load the suite into an Oracle container and run it.
# The host does not need sqlplus. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${ORACLE_CONTAINER:-dpl-oracle}"
connect="${ORACLE_CONNECT:-test/test_pass@//localhost:1521/FREEPDB1}"
ora_user="${connect%%/*}"
ora_net="${connect#*@}"
sys_connect="${ORACLE_SYS_CONNECT:-system/${ORACLE_SYS_PASSWORD:-oracle}@$ora_net}"

docker exec "$container" mkdir -p /tmp/dpl/lib/oracle /tmp/dpl/tests/oracle /tmp/dpl/demo/oracle
docker cp lib/oracle/. "$container:/tmp/dpl/lib/oracle"
docker cp tests/oracle/. "$container:/tmp/dpl/tests/oracle"
docker cp demo/oracle/. "$container:/tmp/dpl/demo/oracle"
# @lib/oracle/... is resolved from the working directory.
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$sys_connect" @lib/oracle/grant_lock.sql "$ora_user"
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @lib/oracle/rollback.sql
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @lib/oracle/deploy.sql
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @tests/oracle/run.sql
