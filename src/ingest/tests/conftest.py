import os
import uuid

import psycopg
import pytest

ACCOUNT = "111122223333"

HEADER = (
    "Date,UserId,Client_Type,Chat_Conversations,Credits_Used,Overage_Cap,"
    "Overage_Credits_Used,Overage_Enabled,ProfileId,Subscription_Tier,Total_Messages,"
    "New_User,User_Email,Usage_Limit"
)


def report_csv(rows: list[dict], model_columns: list[str]) -> str:
    """Build a user_report CSV. Each row dict may carry per-model counts."""
    lines = [HEADER + "".join(f",{c}" for c in model_columns)]
    for r in rows:
        base = [
            r["date"], f'"{r["user"]}"', r.get("client", "KIRO_CLI"), str(r.get("conv", 1)),
            str(r["credits"]), "2500.0", str(r.get("overage", 0.0)), r.get("ov_enabled", "false"),
            '"arn:aws:codewhisperer:eu-central-1:111122223333:profile/TEST"', r.get("tier", "PRO"),
            str(sum(r.get("models", {}).values())), "false", f'"{r.get("email", "")}"',
            str(r.get("limit", 1000)),
        ]
        base += [str(r.get("models", {}).get(c, 0)) for c in model_columns]
        lines.append(",".join(base))
    return "\n".join(lines) + "\n"


def report_key(day: str, client: str = "KIRO_CLI", prefix: str = "kiro-logs/") -> str:
    y, m, d = day.split("-")
    return (f"{prefix}AWSLogs/{ACCOUNT}/KiroLogs/user_report/eu-central-1/{y}/{m}/{d}/00/"
            f"{client}_{ACCOUNT}_user_report_{y}{m}{d}0000.csv")


def _admin_connect(dbname: str | None = None):
    kwargs = {"connect_timeout": 3, "autocommit": True}
    if dbname:
        kwargs["dbname"] = dbname
    return psycopg.connect(**kwargs)


@pytest.fixture(scope="session")
def pg_available():
    if not os.environ.get("PGHOST"):
        pytest.skip("integration tests need PG* environment variables")
    try:
        with _admin_connect():
            pass
    except psycopg.OperationalError as exc:
        pytest.skip(f"PostgreSQL not reachable: {exc}")


@pytest.fixture
def fresh_db(pg_available):
    """An empty database, dropped afterwards."""
    name = f"kiro_test_{uuid.uuid4().hex[:10]}"
    with _admin_connect() as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    conn = _admin_connect(name)
    try:
        yield conn
    finally:
        conn.close()
        with _admin_connect() as admin:
            admin.execute(f'DROP DATABASE "{name}" WITH (FORCE)')


@pytest.fixture
def reader_role(pg_available):
    """A unique role name, dropped afterwards (roles are cluster-wide)."""
    name = f"kiro_reader_test_{uuid.uuid4().hex[:8]}"
    yield name
    with _admin_connect() as admin:
        if admin.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (name,)).fetchone():
            # Grants live in the per-test database, which is dropped first.
            admin.execute(f'DROP ROLE "{name}"')


@pytest.fixture
def rds_like_db(pg_available):
    """A database owned by a non-superuser with CREATEROLE, like RDS's master user.

    Yields (connection as that user, role name it should create). Everything
    is dropped afterwards.
    """
    suffix = uuid.uuid4().hex[:8]
    owner, reader, db = f"kiro_rdsmaster_{suffix}", f"kiro_reader_rds_{suffix}", f"kiro_rds_{suffix}"
    password = uuid.uuid4().hex
    with _admin_connect() as admin:
        admin.execute(f"CREATE ROLE \"{owner}\" LOGIN CREATEROLE CREATEDB NOSUPERUSER PASSWORD '{password}'")
        admin.execute(f'CREATE DATABASE "{db}" OWNER "{owner}"')
    info = _admin_connect().info
    conn = psycopg.connect(host=info.host, port=info.port, dbname=db, user=owner,
                           password=password, autocommit=True, connect_timeout=3)
    try:
        assert conn.execute("SELECT rolsuper FROM pg_roles WHERE rolname = current_user").fetchone()[0] is False
        yield conn, reader
    finally:
        conn.close()
        with _admin_connect() as admin:
            admin.execute(f'DROP DATABASE "{db}" WITH (FORCE)')
            for role in (reader, owner):
                if admin.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (role,)).fetchone():
                    admin.execute(f'DROP ROLE "{role}"')
