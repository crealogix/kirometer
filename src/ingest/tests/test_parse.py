from datetime import date
from decimal import Decimal

import pytest

from kiro_ingest.parse import Batch, ReportFormatError, norm_model, parse_key

from conftest import ACCOUNT, report_csv, report_key


class TestParseKey:
    def test_accepts_user_report(self):
        rk = parse_key(report_key("2026-10-13"))
        assert rk.account_id == ACCOUNT
        assert rk.region == "eu-central-1"
        assert rk.report_date == date(2026, 10, 13)
        assert rk.filename.endswith("_user_report_202610130000.csv")

    def test_accepts_double_prefix_anomaly(self):
        rk = parse_key(report_key("2026-09-28", prefix="kiro-logs/kiro-logs/"))
        assert rk is not None and rk.report_date == date(2026, 9, 28)

    @pytest.mark.parametrize("key", [
        # Prompt and completion logs must never be accepted.
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/GenerateAssistantResponse/eu-central-1/2026/10/13/16/"
        f"{ACCOUNT}_GenerateAssistantResponse_202610131610_abc.json.gz",
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/GenerateCompletions/eu-central-1/2026/10/13/16/x.csv",
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/by_user_analytic/eu-central-1/2026/10/13/00/x.csv",
        # Access-validation stubs written when the bucket was set up.
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/00000000-0000-4000-8000-000000000000",
        # Wrong extension, bad date, user_report path smuggled into a filename.
        report_key("2026-10-13").replace(".csv", ".json"),
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/user_report/eu-central-1/2026/02/30/00/x.csv",
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/GenerateAssistantResponse/AWSLogs_KiroLogs_user_report.csv",
    ])
    def test_rejects_everything_else(self, key):
        assert parse_key(key) is None


def test_norm_model():
    assert norm_model("claude_opus_5_messages") == "claude_opus_5"
    assert norm_model("CLAUDE_SONNET_4_20250514_V1_0_messages") == "claude_sonnet_4"


class TestBatch:
    def _add(self, batch, day, rows, models, client="KIRO_CLI"):
        rk = parse_key(report_key(day, client))
        return batch.add_report(rk, report_csv(rows, models))

    def test_parses_row_and_models(self):
        b = Batch()
        n = self._add(b, "2026-10-01", [{
            "date": "2026-10-01", "user": "u-1", "credits": "12.5", "tier": "PRO_PLUS",
            "email": "a@example.com", "limit": 2000,
            "models": {"auto_messages": 3, "claude_opus_5_messages": 2},
        }], ["auto_messages", "claude_opus_5_messages", "claude_haiku_4.5_messages"])
        assert n == 1
        fact = b.facts[(ACCOUNT, date(2026, 10, 1), "u-1", "cli")]
        assert fact["credits_used"] == Decimal("12.5")
        assert fact["subscription_tier"] == "PRO_PLUS"
        assert fact["total_messages"] == 5
        assert fact["usage_limit"] == Decimal("2000")
        assert fact["overage_enabled"] is False
        # Zero counts are not stored.
        assert b.models[(ACCOUNT, date(2026, 10, 1), "u-1", "cli")] == {"auto": 3, "claude_opus_5": 2}
        assert b.reconcile_mismatches() == 0

    def test_client_types_map_and_unknown_is_skipped(self):
        b = Batch()
        rows = [
            {"date": "2026-10-01", "user": "u-1", "credits": 1, "client": "KIRO_IDE"},
            {"date": "2026-10-01", "user": "u-2", "credits": 1, "client": "PLUGIN"},
            {"date": "2026-10-01", "user": "u-3", "credits": 1, "client": "SOMETHING_NEW"},
        ]
        assert self._add(b, "2026-10-01", rows, []) == 2
        assert {k[3] for k in b.facts} == {"ide", "plugin"}
        assert b.unknown_clients == {"SOMETHING_NEW"}

    def test_duplicate_key_last_wins(self):
        b = Batch()
        self._add(b, "2026-10-01", [{"date": "2026-10-01", "user": "u-1", "credits": 1}], [])
        self._add(b, "2026-10-01", [{"date": "2026-10-01", "user": "u-1", "credits": 7}], [])
        assert b.duplicate_keys == 1
        assert b.facts[(ACCOUNT, date(2026, 10, 1), "u-1", "cli")]["credits_used"] == Decimal(7)

    def test_email_filled_in_later_and_dates_tracked(self):
        b = Batch()
        self._add(b, "2026-10-02", [{"date": "2026-10-02", "user": "u-1", "credits": 1}], [])
        self._add(b, "2026-10-01", [{"date": "2026-10-01", "user": "u-1", "credits": 1,
                                     "email": "a@example.com"}], [])
        assert b.users["u-1"] == {"email": "a@example.com",
                                  "first_seen": date(2026, 10, 1), "last_seen": date(2026, 10, 2)}

    def test_empty_file_is_a_day_without_usage(self):
        b = Batch()
        rk = parse_key(report_key("2026-10-01"))
        assert b.add_report(rk, "") == 0
        assert b.file_rows[rk.key] == 0

    def test_missing_required_column_is_an_error(self):
        b = Batch()
        with pytest.raises(ReportFormatError):
            b.add_report(parse_key(report_key("2026-10-01")), "Date,UserId\n2026-10-01,u-1\n")

    def test_reconcile_mismatch_detected(self):
        b = Batch()
        rk = parse_key(report_key("2026-10-01"))
        text = report_csv([{"date": "2026-10-01", "user": "u-1", "credits": 1,
                            "models": {"auto_messages": 3}}], ["auto_messages"])
        # Claim 5 total messages while the model columns add up to 3.
        text = text.replace(",PRO,3,", ",PRO,5,")
        b.add_report(rk, text)
        assert b.reconcile_mismatches() == 1
