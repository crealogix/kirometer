"""Where report files come from: S3 in production, a local directory in dev.

The S3 source only ever lists exact user_report prefixes per account, region
and month, so it never enumerates the prompt logs in the same bucket. This
matches the IAM policy, which allows nothing else.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Iterable, Protocol

from .parse import ReportKey, parse_key


@dataclass(frozen=True)
class SourceObject:
    report: ReportKey
    etag: str


class Source(Protocol):
    def list(self, months: list[tuple[int, int]]) -> Iterable[SourceObject]: ...
    def read_text(self, key: str) -> str: ...


def months_back(today: date, count: int) -> list[tuple[int, int]]:
    """The current month and the count-1 months before it, newest first."""
    if count < 1:
        raise ValueError("count must be >= 1")
    out, y, m = [], today.year, today.month
    for _ in range(count):
        out.append((y, m))
        y, m = (y - 1, 12) if m == 1 else (y, m - 1)
    return out


def user_report_prefix(prefix: str, account_id: str, region: str, year: int, month: int) -> str:
    return f"{prefix}AWSLogs/{account_id}/KiroLogs/user_report/{region}/{year:04d}/{month:02d}/"


class S3Source:
    def __init__(self, s3, bucket: str, prefixes: list[str], account_id: str, regions: list[str]):
        self.s3 = s3
        self.bucket = bucket
        self.prefixes = prefixes
        self.account_id = account_id
        self.regions = regions

    def list(self, months: list[tuple[int, int]]) -> Iterable[SourceObject]:
        paginator = self.s3.get_paginator("list_objects_v2")
        for prefix in self.prefixes:
            for region in self.regions:
                for year, month in months:
                    list_prefix = user_report_prefix(prefix, self.account_id, region, year, month)
                    for page in paginator.paginate(Bucket=self.bucket, Prefix=list_prefix):
                        for obj in page.get("Contents", []):
                            report = parse_key(obj["Key"])
                            if report is None or report.account_id != self.account_id:
                                continue
                            yield SourceObject(report, obj["ETag"].strip('"'))

    def read_text(self, key: str) -> str:
        if parse_key(key) is None:
            raise ValueError("refusing to read a non user_report object")
        body = self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        return body.decode("utf-8-sig")


class LocalSource:
    """A directory laid out like the bucket, e.g. an `aws s3 sync` download."""

    def __init__(self, root: Path, account_id: str):
        self.root = Path(root)
        self.account_id = account_id

    def list(self, months: list[tuple[int, int]]) -> Iterable[SourceObject]:
        wanted = set(months)
        for path in sorted(self.root.rglob("*.csv")):
            key = path.relative_to(self.root).as_posix()
            report = parse_key(key)
            if report is None or report.account_id != self.account_id:
                continue
            if (report.report_date.year, report.report_date.month) not in wanted:
                continue
            stat = path.stat()
            yield SourceObject(report, f"local-{stat.st_size}-{int(stat.st_mtime)}")

    def read_text(self, key: str) -> str:
        if parse_key(key) is None:
            raise ValueError("refusing to read a non user_report file")
        return (self.root / key).read_text(encoding="utf-8-sig")
