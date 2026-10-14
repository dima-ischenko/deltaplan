#!/bin/sh
# Load the suite into an Oracle container and run it.
# The host does not need sqlplus. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${ORACLE_CONTAINER:-dpl-oracle}"
connect="${ORACLE_CONNECT:-test/test_pass@//localhost:1521/FREEPDB1}"
ora_user="${connect%%/*}"
ora_net="${connect#*@}"
ora_pdb="${ora_net##*/}"

docker exec "$container" mkdir -p /tmp/dpl/lib/oracle /tmp/dpl/tests/oracle /tmp/dpl/demo/oracle
docker cp lib/oracle/. "$container:/tmp/dpl/lib/oracle"
docker cp tests/oracle/. "$container:/tmp/dpl/tests/oracle"
docker cp demo/oracle/. "$container:/tmp/dpl/demo/oracle"
# DBMS_LOCK grant: SYSTEM has no privilege; / as sysdba is local OS auth.
if [ -n "${ORACLE_SYS_CONNECT:-}" ]; then
    docker exec -w /tmp/dpl "$container" \
        sqlplus -S "$ORACLE_SYS_CONNECT" @lib/oracle/grant_lock.sql "$ora_user"
else
    printf 'alter session set container = %s;\n@lib/oracle/grant_lock.sql %s\n' \
        "$ora_pdb" "$ora_user" |
        docker exec -i -w /tmp/dpl "$container" sqlplus -S / as sysdba
fi
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @lib/oracle/rollback.sql
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @lib/oracle/deploy.sql
docker exec -w /tmp/dpl "$container" \
    sqlplus -S "$connect" @tests/oracle/run.sql
