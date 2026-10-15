"""Parsing of Kiro user_report object keys and CSV content.

Pure functions only: no I/O, so everything here is unit-testable without S3
or a database.

Only user_report files are ever accepted. The bucket also holds prompt and
completion logs (GenerateAssistantResponse, GenerateCompletions); those keys
never match USER_REPORT_KEY_RE and are rejected before any download.
"""
from __future__ import annotations

import csv
import io
import posixpath
import re
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal, InvalidOperation

CLIENT_TYPES = {"KIRO_CLI": "cli", "KIRO_IDE": "ide", "PLUGIN": "plugin"}

# The same model reported under two spellings in different files.
MODEL_ALIASES = {"claude_sonnet_4_20250514_v1_0": "claude_sonnet_4"}

NON_MODEL_COLUMNS = frozenset({
    "Date", "UserId", "Client_Type", "Chat_Conversations", "Credits_Used",
    "Overage_Cap", "Overage_Credits_Used", "Overage_Enabled", "ProfileId",
    "Subscription_Tier", "Total_Messages", "New_User", "User_Email",
    "Usage_Limit",
})

# <any prefix>AWSLogs/<account>/KiroLogs/user_report/<region>/<yyyy>/<mm>/<dd>/<hh>/<file>.csv
# Matching on the suffix tolerates prefix anomalies such as kiro-logs/kiro-logs/.
USER_REPORT_KEY_RE = re.compile(
    r"(?:^|/)AWSLogs/(?P<account>\d{12})/KiroLogs/user_report/"
    r"(?P<region>[a-z0-9-]+)/(?P<y>\d{4})/(?P<m>\d{2})/(?P<d>\d{2})/(?P<h>\d{2})/"
    r"(?P<file>[^/]+\.csv)$"
)


class ReportFormatError(ValueError):
    """A user_report file could not be parsed."""


@dataclass(frozen=True)
class ReportKey:
    key: str
    account_id: str
    region: str
    report_date: date
    filename: str


def parse_key(key: str) -> ReportKey | None:
    """Return the parsed key, or None if it is not a user_report CSV."""
    m = USER_REPORT_KEY_RE.search(key)
    if not m:
        return None
    try:
        report_date = date(int(m["y"]), int(m["m"]), int(m["d"]))
    except ValueError:
        return None
    return ReportKey(key, m["account"], m["region"], report_date, posixpath.basename(key))


def norm_model(column: str) -> str:
    name = column[: -len("_messages")] if column.endswith("_messages") else column
    name = name.lower()
    return MODEL_ALIASES.get(name, name)


def _dec(value: str | None) -> Decimal:
    value = (value or "").strip()
    try:
        return Decimal(value) if value else Decimal(0)
    except InvalidOperation as exc:
        raise ReportFormatError(f"not a number: {value!r}") from exc


def _opt_dec(value: str | None) -> Decimal | None:
    value = (value or "").strip()
    return _dec(value) if value else None


def _int(value: str | None) -> int:
    value = (value or "").strip()
    if not value:
        return 0
    try:
        return int(value)
    except ValueError:
        # Counters are integers, but tolerate "12.0".
        return int(_dec(value))


def _opt_bool(value: str | None) -> bool | None:
    v = (value or "").strip().lower()
    if v in ("true", "t", "1", "yes"):
        return True
    if v in ("false", "f", "0", "no"):
        return False
    return None


@dataclass
class Batch:
    """Accumulated, de-duplicated content of one or more report files."""

    facts: dict[tuple, dict] = field(default_factory=dict)
    models: dict[tuple, dict[str, int]] = field(default_factory=dict)
    users: dict[str, dict] = field(default_factory=dict)
    file_rows: dict[str, int] = field(default_factory=dict)
    duplicate_keys: int = 0
    unknown_clients: set[str] = field(default_factory=set)

    def add_report(self, report_key: ReportKey, text: str) -> int:
        """Parse one CSV into the batch. Returns the number of rows accepted."""
        reader = csv.DictReader(io.StringIO(text))
        if reader.fieldnames is None:
            # Empty file: a day without any usage.
            self.file_rows[report_key.key] = 0
            return 0
        missing = {"Date", "UserId", "Client_Type", "Credits_Used"} - set(reader.fieldnames)
        if missing:
            raise ReportFormatError(f"{report_key.filename}: missing columns {sorted(missing)}")

        accepted = 0
        for raw in reader:
            client_raw = (raw.get("Client_Type") or "").strip()
            client = CLIENT_TYPES.get(client_raw)
            if client is None:
                self.unknown_clients.add(client_raw)
                continue
            user_id = (raw.get("UserId") or "").strip()
            if not user_id:
                continue
            try:
                usage_date = date.fromisoformat((raw.get("Date") or "").strip())
            except ValueError as exc:
                raise ReportFormatError(f"{report_key.filename}: bad Date {raw.get('Date')!r}") from exc

            key = (report_key.account_id, usage_date, user_id, client)
            if key in self.facts:
                # Same report present twice (e.g. two prefixes); last one wins.
                self.duplicate_keys += 1
            self.facts[key] = {
                "account_id": report_key.account_id,
                "usage_date": usage_date,
                "user_id": user_id,
                "client_type": client,
                "subscription_tier": (raw.get("Subscription_Tier") or "").strip() or None,
                "credits_used": _dec(raw.get("Credits_Used")),
                "total_messages": _int(raw.get("Total_Messages")),
                "chat_conversations": _int(raw.get("Chat_Conversations")),
                "overage_enabled": _opt_bool(raw.get("Overage_Enabled")),
                "overage_cap": _opt_dec(raw.get("Overage_Cap")),
                "overage_credits_used": _dec(raw.get("Overage_Credits_Used")),
                "usage_limit": _opt_dec(raw.get("Usage_Limit")),
                "new_user": _opt_bool(raw.get("New_User")),
                "profile_id": (raw.get("ProfileId") or "").strip() or None,
                "source_file": report_key.filename,
            }

            per_model: dict[str, int] = {}
            for column, value in raw.items():
                if not column or column in NON_MODEL_COLUMNS or not column.endswith("_messages"):
                    continue
                count = _int(value)
                if count:
                    model = norm_model(column)
                    per_model[model] = per_model.get(model, 0) + count
            self.models[key] = per_model

            email = (raw.get("User_Email") or "").strip() or None
            entry = self.users.get(user_id)
            if entry is None:
                self.users[user_id] = {"email": email, "first_seen": usage_date, "last_seen": usage_date}
            else:
                entry["first_seen"] = min(entry["first_seen"], usage_date)
                entry["last_seen"] = max(entry["last_seen"], usage_date)
                if email and not entry["email"]:
                    entry["email"] = email
            accepted += 1

        self.file_rows[report_key.key] = accepted
        return accepted

    def reconcile_mismatches(self) -> int:
        """Rows where the per-model counts do not add up to Total_Messages.

        A non-zero value means the report format changed in a way the parser
        does not understand, so it is surfaced as an error.
        """
        return sum(
            1 for key, fact in self.facts.items()
            if sum(self.models.get(key, {}).values()) != fact["total_messages"]
        )
