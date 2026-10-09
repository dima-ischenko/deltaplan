#!/bin/sh
# Load the suite into an Oracle container and run it with utPLSQL.
# The host does not need sqlplus. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${ORACLE_CONTAINER:-deltaplan-oracle}"
connect="${ORACLE_CONNECT:-test/test_pass@//localhost:1521/FREEPDB1}"
cache="${DELTAPLAN_CACHE:-tests/.cache}"

chmod +x tests/oracle/install_utplsql.sh
tests/oracle/install_utplsql.sh "$container" "$connect" "$cache"

docker exec "$container" mkdir -p /tmp/deltaplan/oracle /tmp/deltaplan/tests/oracle
docker cp oracle/. "$container:/tmp/deltaplan/oracle"
docker cp tests/oracle/. "$container:/tmp/deltaplan/tests/oracle"

out=$(mktemp)
trap 'rm -f "$out"' EXIT
set +e
docker exec -w /tmp/deltaplan/tests/oracle "$container" \
    sqlplus -S "$connect" @run.sql | tee "$out"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi
if ! grep -Eq '[0-9]+ tests, 0 failed, 0 errored' "$out"; then
    echo "utPLSQL reported failures" >&2
    exit 1
fi
