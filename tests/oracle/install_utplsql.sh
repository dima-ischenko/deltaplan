#!/bin/sh
# Install utPLSQL into schema UT3 if it is not already valid.
# Runs as SYS inside the Oracle container. sqlplus / as sysdba does not
# need a password. The PDB name is the last part of ORACLE_CONNECT.
set -eu

container="$1"
connect="$2"
cache="$3"
version="${UTPLSQL_VERSION:-v3.1.14}"

pdb=$(printf '%s' "$connect" | awk -F/ '{print toupper($NF)}')
tag=${version#v}
archive="$cache/utPLSQL-${tag}.tar.gz"
src="$cache/utPLSQL-${tag}"

sqlplus_sys() {
    docker exec -i "$container" sqlplus -S / as sysdba
}

mkdir -p "$cache"
if [ ! -d "$src/source" ]; then
    curl -fsSL -o "$archive" \
        "https://github.com/utPLSQL/utPLSQL/archive/refs/tags/${version}.tar.gz"
    tar -xzf "$archive" -C "$cache"
fi

docker exec "$container" mkdir -p /tmp/deltaplan/utplsql
docker cp "$src/source/." "$container:/tmp/deltaplan/utplsql"

xdb=$(sqlplus_sys <<EOF
whenever sqlerror exit sql.sqlcode
set heading off feedback off pagesize 0 echo off verify off
alter session set container=${pdb};
select count(*) from dba_registry
 where comp_id = 'XDB' and status = 'VALID';
exit
EOF
)
xdb=$(printf '%s' "$xdb" | tr -d '[:space:]')
if [ "$xdb" != "1" ]; then
    echo "utPLSQL needs Oracle XML DB. This database does not have a valid XDB component." >&2
    echo "Use the compose stack (gvenzl/oracle-free), not Oracle Free lite:" >&2
    echo "  docker compose -f tests/docker/docker-compose.yml up --wait oracle" >&2
    echo "  ORACLE_CONTAINER=deltaplan-oracle ORACLE_CONNECT=test/test_pass@//localhost:1521/FREEPDB1 make test-oracle" >&2
    exit 1
fi

installed=$(sqlplus_sys <<EOF
whenever sqlerror exit sql.sqlcode
set heading off feedback off pagesize 0 echo off verify off
alter session set container=${pdb};
select count(*) from all_objects
 where owner = 'UT3'
   and object_name = 'UT'
   and object_type = 'PACKAGE BODY'
   and status = 'VALID';
exit
EOF
)
installed=$(printf '%s' "$installed" | tr -d '[:space:]')

if [ "$installed" = "1" ]; then
    echo "utPLSQL already installed"
    exit 0
fi

tablespace=$(sqlplus_sys <<EOF
whenever sqlerror exit sql.sqlcode
set heading off feedback off pagesize 0 echo off verify off
alter session set container=${pdb};
select property_value from database_properties
 where property_name = 'DEFAULT_PERMANENT_TABLESPACE';
exit
EOF
)
tablespace=$(printf '%s' "$tablespace" | tr -d '[:space:]')

docker exec -i -w /tmp/deltaplan/utplsql "$container" \
    sqlplus -S / as sysdba <<EOF
whenever sqlerror exit sql.sqlcode
alter session set container=${pdb};
@install_headless.sql ut3 ut3 ${tablespace}
EOF
