"""Minimal SQL migration runner.

* V<NNN>__<name>.sql  versioned: applied once, in numeric order. Editing one
  after it was applied is an error, so a deployed schema cannot silently drift.
* R__<name>.sql       repeatable: re-applied whenever its checksum changes.
  Applied after all versioned migrations.

Each migration runs in its own transaction together with its bookkeeping row.
The caller is responsible for holding the advisory lock.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from importlib import resources

VERSIONED_RE = re.compile(r"^V(\d+)__[\w-]+\.sql$")
REPEATABLE_RE = re.compile(r"^R__[\w-]+\.sql$")


class MigrationError(RuntimeError):
    pass


@dataclass(frozen=True)
class Migration:
    name: str
    sql: str
    repeatable: bool

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.sql.encode("utf-8")).hexdigest()


def load_migrations(package: str = "kiro_ingest.migrations") -> list[Migration]:
    versioned: list[tuple[int, Migration]] = []
    repeatable: list[Migration] = []
    for entry in resources.files(package).iterdir():
        name = entry.name
        if not name.endswith(".sql"):
            continue
        sql = entry.read_text(encoding="utf-8")
        if m := VERSIONED_RE.match(name):
            versioned.append((int(m.group(1)), Migration(name, sql, repeatable=False)))
        elif REPEATABLE_RE.match(name):
            repeatable.append(Migration(name, sql, repeatable=True))
        else:
            raise MigrationError(f"unrecognised migration file name: {name}")

    numbers = [n for n, _ in versioned]
    if len(numbers) != len(set(numbers)):
        raise MigrationError("duplicate versioned migration number")
    versioned.sort(key=lambda item: item[0])
    repeatable.sort(key=lambda mig: mig.name)
    return [mig for _, mig in versioned] + repeatable


def apply_migrations(conn, migrations: list[Migration] | None = None) -> list[str]:
    """Apply pending migrations. Returns the names that were applied."""
    migrations = load_migrations() if migrations is None else migrations

    with conn.transaction():
        conn.execute(
            """CREATE TABLE IF NOT EXISTS schema_migrations (
                   name       text PRIMARY KEY,
                   checksum   text NOT NULL,
                   applied_at timestamptz NOT NULL DEFAULT now()
               )"""
        )
    applied = dict(conn.execute("SELECT name, checksum FROM schema_migrations").fetchall())

    done: list[str] = []
    for mig in migrations:
        previous = applied.get(mig.name)
        if previous == mig.checksum:
            continue
        if previous is not None and not mig.repeatable:
            raise MigrationError(
                f"{mig.name} was changed after it was applied; add a new migration instead"
            )
        with conn.transaction():
            conn.execute(mig.sql)
            conn.execute(
                """INSERT INTO schema_migrations (name, checksum) VALUES (%s, %s)
                   ON CONFLICT (name) DO UPDATE
                   SET checksum = EXCLUDED.checksum, applied_at = now()""",
                (mig.name, mig.checksum),
            )
        done.append(mig.name)
    return done
