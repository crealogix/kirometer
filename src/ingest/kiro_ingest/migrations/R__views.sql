-- R__views: every view and function, rebuilt as a unit.
--
-- Repeatable migration: re-applied whenever the checksum of this file changes.
-- Everything is dropped and recreated, so column changes never hit the
-- CREATE OR REPLACE VIEW restrictions. Grants on the views are re-applied by
-- the ingest code after every run, because DROP VIEW removes them.

DROP VIEW IF EXISTS
    v_data_freshness,
    v_alert_tier_downgrade,
    v_tier_recommendation,
    v_alert_overage_forecast,
    v_alert_tier_upgrade,
    v_usage_monthly,
    v_usage_model_daily,
    v_usage_daily
CASCADE;

-- SECURITY DEFINER: functions run with the caller's privileges by default,
-- even inside a view. This one runs as its owner, so readers of the views do
-- not need access to the plans table. search_path is pinned so the function
-- cannot be redirected to objects a caller creates.
CREATE OR REPLACE FUNCTION plan_cost(p_tier text, p_credits numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p.monthly_price_usd
         + greatest(0::numeric, p_credits - p.included_credits) * p.addon_rate_usd
    FROM public.plans p WHERE p.tier = p_tier
$$;

-- ---------------------------------------------------------------------------
-- Dashboard views. user_label falls back to a short id prefix when the report
-- carries no email.
-- ---------------------------------------------------------------------------
CREATE VIEW v_usage_daily AS
SELECT d.usage_date,
       d.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(d.user_id, 8)) AS user_label,
       d.client_type,
       d.subscription_tier,
       d.credits_used,
       d.total_messages,
       d.chat_conversations,
       d.overage_enabled,
       d.overage_cap,
       d.overage_credits_used,
       d.usage_limit,
       d.account_id
FROM usage_daily d
JOIN users u USING (user_id);

CREATE VIEW v_usage_model_daily AS
SELECT m.usage_date,
       m.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(m.user_id, 8)) AS user_label,
       m.client_type,
       d.subscription_tier,
       m.model,
       m.messages,
       -- Credits are reported per user/day/client, never per model. Split them
       -- by message share so model cost is comparable (an estimate).
       CASE WHEN d.total_messages > 0
            THEN d.credits_used * m.messages / d.total_messages
            ELSE 0
       END AS credits_attributed,
       m.account_id
FROM usage_model_daily m
JOIN usage_daily d USING (account_id, usage_date, user_id, client_type)
JOIN users u USING (user_id);

-- ---------------------------------------------------------------------------
-- Calendar-month rollup per user. Credits reset per calendar month, so every
-- utilisation and alert metric is scoped to the month.
-- ---------------------------------------------------------------------------
CREATE VIEW v_usage_monthly AS
WITH per_user AS (
    SELECT d.account_id,
           date_trunc('month', d.usage_date)::date                         AS month,
           d.user_id,
           COALESCE(NULLIF(u.email, ''), 'unknown-' || left(d.user_id, 8)) AS user_label,
           -- A mid-month plan change leaves several tiers in a month; the
           -- newest one is the current subscription.
           (array_agg(d.subscription_tier ORDER BY d.usage_date DESC))[1]  AS subscription_tier,
           sum(d.credits_used)                                             AS credits_mtd,
           sum(d.total_messages)                                           AS messages_mtd,
           sum(d.overage_credits_used)                                     AS overage_credits_mtd,
           max(d.overage_cap)                                              AS overage_cap,
           max(d.usage_date)                                               AS last_usage_date,
           count(DISTINCT d.usage_date)                                    AS active_days
    FROM usage_daily d
    JOIN users u USING (user_id)
    GROUP BY 1, 2, 3, 4
)
SELECT pu.*,
       p.included_credits,
       p.monthly_price_usd,
       p.next_tier,
       round(pu.credits_mtd / NULLIF(p.included_credits, 0) * 100, 1) AS utilization_pct,
       plan_cost(pu.subscription_tier, pu.credits_mtd)                AS cost_current_tier,
       CASE WHEN p.next_tier IS NOT NULL
            THEN plan_cost(p.next_tier, pu.credits_mtd) END           AS cost_next_tier
FROM per_user pu
LEFT JOIN plans p ON p.tier = pu.subscription_tier;

-- ---------------------------------------------------------------------------
-- ALERT 1: the next higher tier would already have been cheaper this month.
-- ---------------------------------------------------------------------------
CREATE VIEW v_alert_tier_upgrade AS
SELECT account_id,
       month,
       user_label,
       subscription_tier,
       next_tier,
       round(credits_mtd, 1)                        AS credits_mtd,
       included_credits,
       round(cost_current_tier, 2)                  AS cost_current_tier,
       round(cost_next_tier, 2)                     AS cost_next_tier,
       round(cost_current_tier - cost_next_tier, 2) AS monthly_saving_usd
FROM v_usage_monthly
WHERE next_tier IS NOT NULL
  AND cost_next_tier < cost_current_tier
  AND month = date_trunc('month', (SELECT max(usage_date) FROM usage_daily))::date;

-- ---------------------------------------------------------------------------
-- ALERT 2: the 7-day moving average projects a month-end overshoot past the
-- tier's break-even threshold. Fires on overshoot_vs_threshold > 0.
-- ---------------------------------------------------------------------------
CREATE VIEW v_alert_overage_forecast AS
WITH bounds AS (
    SELECT max(usage_date)                                                           AS as_of,
           date_trunc('month', max(usage_date))::date                                AS month,
           (date_trunc('month', max(usage_date)) + interval '1 month - 1 day')::date AS month_end
    FROM usage_daily
),
window_avg AS (
    SELECT d.account_id,
           d.user_id,
           -- Divided by the window length, not by active days, so idle days
           -- pull the average down.
           sum(d.credits_used) / 7.0 AS avg_daily_7d
    FROM usage_daily d
    CROSS JOIN bounds b
    WHERE d.usage_date > b.as_of - interval '7 days'
      AND d.usage_date <= b.as_of
    GROUP BY 1, 2
),
projected AS (
    SELECT m.account_id,
           m.month,
           m.user_label,
           m.subscription_tier,
           m.next_tier,
           b.as_of,
           m.credits_mtd,
           m.included_credits,
           COALESCE(w.avg_daily_7d, 0)                                            AS avg_daily_7d,
           (b.month_end - b.as_of)                                                AS days_remaining,
           m.credits_mtd + COALESCE(w.avg_daily_7d, 0) * (b.month_end - b.as_of) AS projected_month_end,
           p.overshoot_threshold_credits,
           p.addon_rate_usd
    FROM v_usage_monthly m
    CROSS JOIN bounds b
    LEFT JOIN window_avg w
           ON w.account_id = m.account_id AND w.user_id = m.user_id
    JOIN plans p ON p.tier = m.subscription_tier
    WHERE m.month = b.month
)
SELECT account_id,
       month,
       user_label,
       subscription_tier,
       next_tier,
       as_of,
       round(credits_mtd, 1)                                             AS credits_mtd,
       included_credits,
       round(avg_daily_7d, 1)                                            AS avg_daily_7d,
       days_remaining,
       round(projected_month_end, 1)                                     AS projected_month_end,
       round(projected_month_end - included_credits, 1)                  AS projected_overshoot,
       overshoot_threshold_credits                                       AS threshold_credits,
       round(projected_month_end - included_credits
             - overshoot_threshold_credits, 1)                           AS overshoot_vs_threshold,
       round(greatest(0::numeric, projected_month_end - included_credits)
             * addon_rate_usd, 2)                                        AS projected_addon_usd
FROM projected;

-- ---------------------------------------------------------------------------
-- Tier recommendation from the higher of the previous full month and the
-- current-month projection, so a one-off quiet or busy month never drives a
-- recommendation on its own.
-- ---------------------------------------------------------------------------
CREATE VIEW v_tier_recommendation AS
WITH bounds AS (
    SELECT max(usage_date)                                                           AS as_of,
           date_trunc('month', max(usage_date))::date                                AS month,
           (date_trunc('month', max(usage_date)) - interval '1 month')::date         AS prev_month,
           (date_trunc('month', max(usage_date)) + interval '1 month - 1 day')::date AS month_end
    FROM usage_daily
),
-- Only subscriptions that are still reporting; retired accounts are ignored.
active_accounts AS (
    SELECT DISTINCT d.account_id
    FROM usage_daily d CROSS JOIN bounds b
    WHERE d.usage_date >= b.month
),
-- The previous month only counts if the account reported for all of it.
coverage AS (
    SELECT account_id, min(usage_date) AS first_report
    FROM usage_daily
    GROUP BY 1
),
-- Everyone seen this month or last month. Kiro only reports active users, so
-- users with no usage this month are picked up from last month.
population AS (
    SELECT d.account_id,
           d.user_id,
           (array_agg(d.subscription_tier ORDER BY d.usage_date DESC))[1]           AS subscription_tier,
           COALESCE(sum(d.credits_used) FILTER (WHERE d.usage_date >= b.month), 0) AS credits_mtd,
           COALESCE(sum(d.credits_used) FILTER (
               WHERE d.usage_date >= b.prev_month AND d.usage_date < b.month), 0)    AS credits_prev_month,
           COALESCE(sum(d.credits_used) FILTER (
               WHERE d.usage_date > b.as_of - 7), 0) / 7.0                           AS avg_daily_7d
    FROM usage_daily d
    CROSS JOIN bounds b
    JOIN active_accounts a USING (account_id)
    WHERE d.usage_date >= b.prev_month
    GROUP BY 1, 2
),
scored AS (
    SELECT p.*,
           b.as_of,
           cv.first_report <= b.prev_month                         AS prev_month_complete,
           p.credits_mtd + p.avg_daily_7d * (b.month_end - b.as_of) AS projected_month_end
    FROM population p
    CROSS JOIN bounds b
    JOIN coverage cv USING (account_id)
),
basis AS (
    SELECT s.*,
           greatest(s.projected_month_end,
                    CASE WHEN s.prev_month_complete THEN s.credits_prev_month ELSE 0 END) AS credits_basis
    FROM scored s
)
SELECT b.account_id,
       b.user_id,
       COALESCE(NULLIF(u.email, ''), 'unknown-' || left(b.user_id, 8))    AS user_label,
       b.subscription_tier,
       b.as_of,
       round(b.credits_mtd, 1)                                            AS credits_mtd,
       round(b.avg_daily_7d, 1)                                           AS avg_daily_7d,
       round(b.projected_month_end, 1)                                    AS projected_month_end,
       CASE WHEN b.prev_month_complete THEN round(b.credits_prev_month, 1) END
                                                                          AS credits_prev_month,
       CASE WHEN b.prev_month_complete THEN 'previous month and projection'
            ELSE 'projection only' END                                    AS evidence,
       round(b.credits_basis, 1)                                          AS credits_basis,
       r.tier                                                             AS recommended_tier,
       cp.sort_order                                                      AS current_rank,
       r.sort_order                                                       AS recommended_rank,
       round(plan_cost(b.subscription_tier, b.credits_basis), 2)          AS cost_current_tier,
       round(r.cost, 2)                                                   AS cost_recommended_tier,
       round(plan_cost(b.subscription_tier, b.credits_basis) - r.cost, 2) AS monthly_saving_usd
FROM basis b
JOIN users u USING (user_id)
JOIN plans cp ON cp.tier = b.subscription_tier
CROSS JOIN LATERAL (
    SELECT p.tier, p.sort_order, plan_cost(p.tier, b.credits_basis) AS cost
    FROM plans p
    -- Cheapest plan wins; on a tie the lower tier wins.
    ORDER BY plan_cost(p.tier, b.credits_basis), p.sort_order
    LIMIT 1
) r;

-- ---------------------------------------------------------------------------
-- ALERT 3: a lower tier would have been cheaper on both months of evidence.
-- Without a complete previous month only the projection is used, and only
-- once 7 days of the month have been reported.
-- ---------------------------------------------------------------------------
CREATE VIEW v_alert_tier_downgrade AS
SELECT *
FROM v_tier_recommendation
WHERE recommended_rank < current_rank
  AND (evidence = 'previous month and projection' OR extract(day FROM as_of) >= 7);

-- ---------------------------------------------------------------------------
-- ALERT 4 input: how many days the newest imported report is behind today
-- (UTC). Kiro writes each day's report at 02:00 UTC the next day, so 1 is the
-- normal value. Based on imported files, not on usage rows, so a day nobody
-- used Kiro does not look like missing data.
-- ---------------------------------------------------------------------------
CREATE VIEW v_data_freshness AS
SELECT account_id,
       max(report_date)                                   AS latest_report_date,
       max(imported_at)                                   AS last_import_at,
       (now() AT TIME ZONE 'UTC')::date - max(report_date) AS days_behind
FROM ingest_files
GROUP BY account_id;
