#!/bin/sh
# Load the suite into the Postgres container and run it.
# The host does not need psql. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${PG_CONTAINER:-postgres}"
user="${PGUSER:-test_user}"
password="${PGPASSWORD:-test_pass}"
database="${PGDATABASE:-test_db}"

docker exec "$container" mkdir -p /tmp/dwa/lib/postgres /tmp/dwa/tests/postgres /tmp/dwa/demo/postgres
docker cp lib/postgres/. "$container:/tmp/dwa/lib/postgres"
docker cp tests/postgres/. "$container:/tmp/dwa/tests/postgres"
docker cp demo/postgres/. "$container:/tmp/dwa/demo/postgres"
# \i lib/postgres/... is resolved from the working directory.
docker exec -w /tmp/dwa -e PGPASSWORD="$password" "$container" \
    psql -U "$user" -d "$database" -v ON_ERROR_STOP=1 \
    -f tests/postgres/run.sql
