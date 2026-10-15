# kirometer

Unofficial usage dashboards and subscription alerts for [Kiro](https://kiro.dev),
running entirely in your own AWS account. Not affiliated with or endorsed by
Amazon Web Services.

Kiro writes a daily usage report per user to S3: credits used, messages per
model, client type, subscription tier and overage. This project imports those
reports into PostgreSQL and shows them in Amazon Managed Grafana, so whoever
manages the subscriptions can see per person:

- how much of their plan they have used this month,
- whether a different plan would be cheaper,
- whether they are on track to overshoot their included credits.

The data is an indicator, not a verdict. People are out of office, try other
tools or have one-off busy months. The alerts are meant to start a
conversation, not to switch plans automatically.

## What you get

**A dashboard** with credits per user over time, split by client (CLI, IDE,
plugin), model and subscription tier, plus a per-user summary with usage of
the plan limit in percent.

**Four alert rules**, evaluated against the current calendar month (Kiro
credits reset monthly):

| Alert | Fires when |
|---|---|
| Next tier would be cheaper | This month's credits already passed the break-even point to the next tier |
| Forecast month-end overshoot | The last 7 days' average, projected to month end, passes the tier's break-even threshold |
| Downgrade candidate | A cheaper tier would have covered both the previous full month and this month's projection |
| Usage data is stale | The newest imported report is more than two days old |

The thresholds are derived from the price list, not chosen by hand. A tier's
threshold is the overshoot at which add-on credits cost as much as the next
plan: `(next price - current price) / add-on rate`. With the default prices
that is 500 credits on PRO, 1,500 on PRO_PLUS and 2,500 on PRO_MAX. POWER has
no higher tier, so its threshold, 5,000 credits, is the point where a second
POWER seat would be cheaper.

Usage alerts are e-mailed once a month on the 28th at 07:00 UTC (the 28th
exists in every month). Pipeline alerts go to a separate address as soon as
they happen.

## How it works

```
Kiro --daily--> S3 bucket --06:30 UTC--> Lambda --> RDS PostgreSQL <-- Managed Grafana --> SNS --> e-mail
```

- A scheduled Lambda imports only new or changed report files. Everything is
  idempotent, so re-running it never duplicates data.
- The Lambda can read only the `user_report/` folder. If Kiro prompt logging
  is enabled, the prompt logs in the same bucket are out of its reach, both by
  IAM policy and in code.
- Database and Grafana sit in private subnets, connections use verified TLS,
  and Grafana reads the data through a role that can only see reporting views.
- Everything is OpenTofu: three small stacks, configured by one file per
  deployment.

## Quick start

Requirements: an AWS account with IAM Identity Center, a VPC with private
subnets in two Availability Zones, the S3 bucket Kiro writes its reports to,
OpenTofu >= 1.13, AWS CLI v2, Python 3.12+ and `make`.

```bash
python3 -m venv .venv && .venv/bin/pip install -r src/ingest/requirements-dev.txt
make test build validate                     # local checks, no AWS access

cp config/example.tfvars config/team-a.tfvars  # fill in; git-ignored
make ENV=team-a bootstrap                    # state bucket + encryption keys
make ENV=team-a platform-plan platform-apply # AWS resources
make ENV=team-a ingest                       # first import
make ENV=team-a grafana-plan grafana-apply   # data source, dashboard, alerts
```

[`infra/README.md`](infra/README.md) has the full configuration reference,
deployment steps, day-to-day operations and security notes.

## Costs

The main running costs are a small RDS instance, Managed Grafana user
licences and, without a NAT gateway, two VPC interface endpoints. Lambda,
EventBridge, SNS and S3 usage are negligible at this data volume. Use the
[AWS Pricing Calculator](https://calculator.aws/) for your region and number
of Grafana users.

## Privacy

The dashboard and alerts show named people's consumption. Limit Grafana access
and alert recipients to the people responsible for subscriptions, and check
with your works council or data protection officer where that applies.

## Contributing

Issues and pull requests are welcome. Run `make test validate` before opening
a pull request. Never commit anything from `config/` except
`config/example.tfvars`.

## License

[MIT](LICENSE)
