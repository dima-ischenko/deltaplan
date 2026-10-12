#!/bin/sh
# Load the suite into the Postgres container and run it.
# The host does not need psql. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${PG_CONTAINER:-postgres}"
user="${PGUSER:-test_user}"
password="${PGPASSWORD:-test_pass}"
database="${PGDATABASE:-test_db}"

docker exec "$container" mkdir -p /tmp/dpl/lib/postgres /tmp/dpl/tests/postgres
docker cp lib/postgres/. "$container:/tmp/dpl/lib/postgres"
docker cp tests/postgres/dpl_test.sql "$container:/tmp/dpl/tests/postgres/dpl_test.sql"
docker cp tests/postgres/run.sql "$container:/tmp/dpl/tests/postgres/run.sql"
docker exec -e PGPASSWORD="$password" "$container" \
    psql -U "$user" -d "$database" -v ON_ERROR_STOP=1 \
    -f /tmp/dpl/tests/postgres/run.sql
