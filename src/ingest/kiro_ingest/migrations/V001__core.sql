-- V001: core schema for Kiro credit usage.
--
-- Consolidates the incremental local scripts into one clean schema. The
-- account dimension is part of every key from the start, so two Kiro
-- subscriptions reporting the same person on the same day can never
-- overwrite each other.
--
-- Versioned migration: applied exactly once, never edited afterwards. Changes
-- go into a new V002__... file. Views and functions live in R__views.sql.

-- ---------------------------------------------------------------------------
-- Users. UserId is the identity; User_Email is an attribute that is sometimes
-- empty in the source reports, so it can never be a key.
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    user_id    text PRIMARY KEY,
    email      text,
    first_seen date NOT NULL,
    last_seen  date NOT NULL
);

-- ---------------------------------------------------------------------------
-- One row per account, user, day and client. Natural key verified unique
-- across all source data, which makes re-imports idempotent.
-- ---------------------------------------------------------------------------
CREATE TABLE usage_daily (
    account_id           text           NOT NULL,
    usage_date           date           NOT NULL,
    user_id              text           NOT NULL REFERENCES users (user_id),
    -- Normalised from KIRO_CLI / KIRO_IDE / PLUGIN.
    client_type          text           NOT NULL CHECK (client_type IN ('cli', 'ide', 'plugin')),
    subscription_tier    text,
    credits_used         numeric(18, 6) NOT NULL DEFAULT 0,
    total_messages       integer        NOT NULL DEFAULT 0,
    chat_conversations   integer        NOT NULL DEFAULT 0,
    overage_enabled      boolean,
    overage_cap          numeric(18, 6),
    overage_credits_used numeric(18, 6) NOT NULL DEFAULT 0,
    -- Not present in older report versions, hence nullable.
    usage_limit          numeric(18, 6),
    new_user             boolean,
    profile_id           text,
    source_file          text           NOT NULL,
    imported_at          timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, usage_date, user_id, client_type)
);

CREATE INDEX idx_usage_daily_date ON usage_daily (usage_date);
CREATE INDEX idx_usage_daily_user ON usage_daily (user_id);

-- ---------------------------------------------------------------------------
-- Per-model message counts, stored long rather than wide: the CSVs only carry
-- columns for models used that day and new models appear every few weeks.
-- ---------------------------------------------------------------------------
CREATE TABLE usage_model_daily (
    account_id  text    NOT NULL,
    usage_date  date    NOT NULL,
    user_id     text    NOT NULL,
    client_type text    NOT NULL,
    model       text    NOT NULL,
    messages    integer NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, usage_date, user_id, client_type, model),
    FOREIGN KEY (account_id, usage_date, user_id, client_type)
        REFERENCES usage_daily (account_id, usage_date, user_id, client_type)
        ON DELETE CASCADE
);

CREATE INDEX idx_usage_model_daily_model ON usage_model_daily (model);

-- ---------------------------------------------------------------------------
-- Every report file that was imported, with its ETag. Lets each run skip
-- unchanged files, gives an audit trail of what was loaded and when, and
-- measures data freshness independently of whether anyone used Kiro that day.
-- ---------------------------------------------------------------------------
CREATE TABLE ingest_files (
    s3_key      text        PRIMARY KEY,
    etag        text        NOT NULL,
    account_id  text        NOT NULL,
    report_date date        NOT NULL,
    row_count   integer     NOT NULL,
    imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_ingest_files_account_date ON ingest_files (account_id, report_date);

-- ---------------------------------------------------------------------------
-- Plan catalogue: Kiro list prices. A table rather than CASE expressions so
-- prices can change without touching the views.
-- ---------------------------------------------------------------------------
CREATE TABLE plans (
    tier                        text           PRIMARY KEY,
    monthly_price_usd           numeric(10, 2) NOT NULL,
    included_credits            integer        NOT NULL,
    addon_rate_usd              numeric(10, 4) NOT NULL,
    next_tier                   text           REFERENCES plans (tier),
    sort_order                  integer        NOT NULL UNIQUE,
    overshoot_threshold_credits numeric(12, 2)
);

INSERT INTO plans (tier, monthly_price_usd, included_credits, addon_rate_usd, next_tier, sort_order) VALUES
    ('POWER',    200.00, 10000, 0.04, NULL,       4),
    ('PRO_MAX',  100.00,  5000, 0.04, 'POWER',    3),
    ('PRO_PLUS',  40.00,  2000, 0.04, 'PRO_MAX',  2),
    ('PRO',       20.00,  1000, 0.04, 'PRO_PLUS', 1);

-- Forecast threshold per tier: the overshoot at which the next capacity
-- increment becomes cheaper than paying add-on credits.
--   with a next tier:  (price_next - price_current) / addon_rate  -> 500 / 1500 / 2500
--   top tier:          price / addon_rate (a second seat)          -> 5000
UPDATE plans p
SET overshoot_threshold_credits = round((n.monthly_price_usd - p.monthly_price_usd) / p.addon_rate_usd, 2)
FROM plans n
WHERE n.tier = p.next_tier;

UPDATE plans
SET overshoot_threshold_credits = round(monthly_price_usd / addon_rate_usd, 2)
WHERE next_tier IS NULL;

ALTER TABLE plans ALTER COLUMN overshoot_threshold_credits SET NOT NULL;
