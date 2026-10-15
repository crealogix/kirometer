"""Local runner for development.

  python -m kiro_ingest.cli --account-id 123456789012 --data-dir ./downloaded-reports
  python -m kiro_ingest.cli --account-id 123456789012 --bucket <bucket> \\
      --prefix kiro/ --region eu-central-1 --profile <aws-profile>

Database connection from the standard PG* environment variables.
"""
from __future__ import annotations

import argparse
import json
import os
from datetime import date
from pathlib import Path

import psycopg

from .core import RunConfig, run
from .source import LocalSource, S3Source


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--account-id", required=True)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--data-dir", type=Path)
    src.add_argument("--bucket")
    ap.add_argument("--prefix", action="append", default=[])
    ap.add_argument("--region", action="append", default=[])
    ap.add_argument("--profile")
    ap.add_argument("--lookback-months", type=int, default=2)
    ap.add_argument("--today", type=date.fromisoformat, help="pretend today is this date (YYYY-MM-DD)")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--reader-role")
    args = ap.parse_args()

    if args.data_dir:
        source = LocalSource(args.data_dir, args.account_id)
    else:
        import boto3
        s3 = boto3.Session(profile_name=args.profile).client("s3")
        source = S3Source(s3, args.bucket, args.prefix or ["kiro/"], args.account_id,
                          args.region or ["eu-central-1"])

    cfg = RunConfig(
        lookback_months=args.lookback_months,
        force=args.force,
        reader_role=args.reader_role,
        reader_password=os.environ.get("READER_PASSWORD") if args.reader_role else None,
        today=args.today,
    )
    with psycopg.connect(autocommit=True) as conn:
        print(json.dumps(run(conn, source, cfg), indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
