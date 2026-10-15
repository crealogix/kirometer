from datetime import date

import pytest

from kiro_ingest.source import S3Source, months_back, user_report_prefix

from conftest import ACCOUNT, report_key


def test_months_back_crosses_year_boundary():
    assert months_back(date(2026, 1, 15), 3) == [(2026, 1), (2025, 12), (2025, 11)]
    with pytest.raises(ValueError):
        months_back(date(2026, 1, 15), 0)


def test_user_report_prefix():
    assert user_report_prefix("kiro-logs/", ACCOUNT, "eu-central-1", 2026, 9) == (
        f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/user_report/eu-central-1/2026/09/"
    )


class FakeS3:
    """Records every prefix listed and every key read."""

    def __init__(self, keys):
        self.keys = keys
        self.listed_prefixes = []
        self.read_keys = []

    def get_paginator(self, name):
        assert name == "list_objects_v2"
        fake = self

        class Paginator:
            def paginate(self, Bucket, Prefix):
                fake.listed_prefixes.append(Prefix)
                yield {"Contents": [{"Key": k, "ETag": '"etag-1"'} for k in fake.keys if k.startswith(Prefix)]}

        return Paginator()

    def get_object(self, Bucket, Key):
        self.read_keys.append(Key)

        class Body:
            def read(self):
                return "\ufeffDate,UserId\n".encode("utf-8")

        return {"Body": Body()}


def test_lists_only_exact_user_report_prefixes():
    good = report_key("2026-10-13")
    s3 = FakeS3([good, good.replace("user_report", "GenerateAssistantResponse")])
    src = S3Source(s3, "bucket", ["kiro-logs/", "kiro-logs/kiro-logs/"], ACCOUNT, ["eu-central-1"])

    objs = list(src.list([(2026, 10), (2026, 9)]))

    assert [o.report.key for o in objs] == [good]
    assert objs[0].etag == "etag-1"
    assert all("/KiroLogs/user_report/" in p for p in s3.listed_prefixes)
    assert len(s3.listed_prefixes) == 4  # 2 prefixes x 1 region x 2 months


def test_read_strips_bom_and_refuses_other_keys():
    s3 = FakeS3([])
    src = S3Source(s3, "bucket", ["kiro-logs/"], ACCOUNT, ["eu-central-1"])
    assert src.read_text(report_key("2026-10-13")).startswith("Date,")
    with pytest.raises(ValueError):
        src.read_text(f"kiro-logs/AWSLogs/{ACCOUNT}/KiroLogs/GenerateAssistantResponse/x.json.gz")
    assert s3.read_keys == [report_key("2026-10-13")]
