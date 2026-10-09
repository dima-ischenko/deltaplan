#!/bin/sh
# Make pgTAP available in the database. Prefer CREATE EXTENSION.
# If the image has no extension files, load the upstream plpgsql script
# into public.
set -eu

container="$1"
user="$2"
password="$3"
database="$4"
cache="$5"
version="${PGTAP_VERSION:-v1.3.3}"

psql_in() {
    docker exec -e PGPASSWORD="$password" "$container" \
        psql -U "$user" -d "$database" -v ON_ERROR_STOP=1 "$@"
}

mkdir -p "$cache"
sql_in="$cache/pgtap-${version}.sql.in"
sql_out="$cache/pgtap.sql"

has_plan=$(psql_in -Atqc "select count(*) from pg_proc where proname = 'no_plan'") || true
if [ "$has_plan" != "0" ] && [ -n "$has_plan" ]; then
    echo "pgTAP already installed"
    exit 0
fi

has_ext=$(psql_in -Atqc \
    "select count(*) from pg_available_extensions where name = 'pgtap'") || true
if [ "$has_ext" = "1" ]; then
    psql_in -c "create extension if not exists pgtap"
    echo "pgTAP extension installed"
    exit 0
fi

if [ ! -f "$sql_in" ]; then
    curl -fsSL -o "$sql_in" \
        "https://raw.githubusercontent.com/theory/pgtap/${version}/sql/pgtap.sql.in"
fi
sed -e 's/__OS__/linux/g' -e 's/__VERSION__/1.3/g' "$sql_in" > "$sql_out"

docker exec "$container" mkdir -p /tmp/deltaplan/tests/postgres
docker cp "$sql_out" "$container:/tmp/deltaplan/tests/postgres/pgtap.sql"
psql_in -f /tmp/deltaplan/tests/postgres/pgtap.sql
echo "pgTAP loaded from upstream SQL"
