# Local defaults match a database that is already running.
# tests/docker/docker-compose.yml uses other host ports; override the variables then.

ORACLE_CONNECT ?= test/test_pass@//localhost:1521/test_db
export ORACLE_CONNECT

PG_CONTAINER ?= postgres
PGUSER ?= test_user
PGPASSWORD ?= test_pass
PGDATABASE ?= test_db
export PG_CONTAINER PGUSER PGPASSWORD PGDATABASE

.PHONY: test-oracle test-postgres test-consistency test

test: test-oracle test-postgres test-consistency

test-oracle:
	tests/oracle/run.sh

test-postgres:
	tests/postgres/run.sh

# xoverrr compares an incremental mart with a full refresh.
# DELTAPLAN_DSN overrides the database. The default is local PostgreSQL.
test-consistency:
	python3 -m venv .venv
	.venv/bin/pip install -q -r tests/consistency/requirements.txt
	.venv/bin/pytest -q tests/consistency
