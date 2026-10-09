#!/bin/sh
# Load the suite into an Oracle container and run it.
# The host does not need sqlplus. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${ORACLE_CONTAINER:-deltaplan-oracle}"
connect="${ORACLE_CONNECT:-test/test_pass@//localhost:1521/FREEPDB1}"

docker exec "$container" mkdir -p /tmp/deltaplan/oracle /tmp/deltaplan/tests/oracle
docker cp oracle/. "$container:/tmp/deltaplan/oracle"
docker cp tests/oracle/. "$container:/tmp/deltaplan/tests/oracle"
docker exec -w /tmp/deltaplan/tests/oracle "$container" \
    sqlplus -S "$connect" @run.sql
