import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import psycopg2
import pytest
from sqlalchemy import create_engine

from harness import Mart

ROOT = Path(__file__).resolve().parents[2]
ADMIN_DSN = os.environ.get(
    "DELTAPLAN_ADMIN_DSN",
    "postgresql://test_user:test_pass@localhost:5432/postgres",
)
DSN = os.environ.get(
    "DELTAPLAN_DSN",
    "postgresql://test_user:test_pass@localhost:5432/consistency_db",
)


def _ensure_database():
    conn = psycopg2.connect(ADMIN_DSN)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("select 1 from pg_database where datname = 'consistency_db'")
    if cur.fetchone() is None:
        cur.execute("create database consistency_db")
    cur.close()
    conn.close()


@pytest.fixture(scope="session")
def sa_engine():
    _ensure_database()
    subprocess.check_call(
        [
            "psql",
            DSN,
            "-v",
            "ON_ERROR_STOP=1",
            "-q",
            "-f",
            str(ROOT / "postgres" / "deltaplan.sql"),
        ]
    )
    engine = create_engine(DSN)
    yield engine
    engine.dispose()


@pytest.fixture
def mart(sa_engine):
    conn = psycopg2.connect(DSN)
    conn.autocommit = False
    box = Mart(conn, sa_engine)
    box.reset()
    yield box
    conn.close()
