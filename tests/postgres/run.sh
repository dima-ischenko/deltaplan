#!/bin/sh
# Load the suite into the Postgres container and run it with pgTAP.
# The host does not need psql. Override the container when using tests/docker.
set -eu
cd "$(dirname "$0")/../.."

container="${PG_CONTAINER:-postgres}"
user="${PGUSER:-test_user}"
password="${PGPASSWORD:-test_pass}"
database="${PGDATABASE:-test_db}"
cache="${DELTAPLAN_CACHE:-tests/.cache}"

chmod +x tests/postgres/install_pgtap.sh
tests/postgres/install_pgtap.sh "$container" "$user" "$password" "$database" "$cache"

docker exec "$container" mkdir -p /tmp/deltaplan/postgres /tmp/deltaplan/tests/postgres
docker cp postgres/. "$container:/tmp/deltaplan/postgres"
docker cp tests/postgres/deltaplan_test.sql "$container:/tmp/deltaplan/tests/postgres/deltaplan_test.sql"
docker cp tests/postgres/deltaplan_tap.sql "$container:/tmp/deltaplan/tests/postgres/deltaplan_tap.sql"
docker cp tests/postgres/run.sql "$container:/tmp/deltaplan/tests/postgres/run.sql"
docker exec -e PGPASSWORD="$password" "$container" \
    psql -U "$user" -d "$database" -v ON_ERROR_STOP=1 \
    -f /tmp/deltaplan/tests/postgres/run.sql
