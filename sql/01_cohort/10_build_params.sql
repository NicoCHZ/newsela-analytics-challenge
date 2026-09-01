-- Cohort 1/7: every constant the analysis uses, in one row, derived from the
-- data wherever it can be.
--
-- Purpose:  Downstream queries CROSS JOIN this table instead of repeating
--           literals, so a refreshed source moves every boundary at once and
--           no number is buried in the middle of a query.
-- Source:   bigquery-public-data.stackoverflow.posts_questions (creation_date only)
-- Output:   so_analysis.params — exactly one row
-- Cost:     see results/run_log.md (one narrow column)
--
-- Derived from the data:
--   snapshot_date     the newest question in the data: the dataset's own "today".
--   cohort_end        snapshot minus the maturation window, so every question in
--                     the cohort has had the same minimum observable exposure.
--   cohort_start      1 January of cohort_end's year — "the current year" as the
--                     data defines it.
--   comparison_start  one year earlier. The previous year is kept for comparisons.
--   purge_boundary    snapshot minus 365 days. Stack Overflow automatically
--                     deletes unanswered questions with a non-positive score once
--                     they are a year old, and the public dump excludes deleted
--                     posts, so questions asked before this date are a survivor
--                     population. See 00_profiling/02 and the README.
-- Chosen, and justified where they are used:
--   maturation_days   30 — captures ~89% of eventual acceptances (04_validation/41).
--   settle_days       90 — how old a prior question must be before its outcome
--                     counts in an asker's track record (~93% of acceptances by then).
--   z                 1.96 — 95% intervals.
--   target_precision  ±3 points — the resolution at which I would tell someone
--                     two tags differ; it sets the volume floor (02_tag_approval/20).
--   loose_precision   ±5 points — the looser floor used in the sensitivity check.
--   high_floor        2,000 questions — the stricter floor used in the same check.
--   min_per_side      100 — the smallest group compared inside a single tag.
--   group_size        50 — tags per side in the within-asker test.

CREATE OR REPLACE TABLE `so_analysis.params` AS

WITH newest AS (
  SELECT
    DATE(MAX(q.creation_date)) AS snapshot_date
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
),

chosen AS (
  SELECT
    30 AS maturation_days,
    90 AS settle_days,
    1.96 AS z,
    0.03 AS target_precision,
    0.05 AS loose_precision,
    2000 AS high_floor,
    100 AS min_per_side,
    50 AS group_size
),

derived AS (
  SELECT
    n.snapshot_date,
    DATE_SUB(n.snapshot_date, INTERVAL c.maturation_days DAY) AS cohort_end,
    DATE_TRUNC(DATE_SUB(n.snapshot_date, INTERVAL c.maturation_days DAY), YEAR) AS cohort_start,
    DATE_SUB(n.snapshot_date, INTERVAL 365 DAY) AS purge_boundary,
    c.maturation_days,
    c.settle_days,
    c.z,
    c.target_precision,
    c.loose_precision,
    c.high_floor,
    c.min_per_side,
    c.group_size
  FROM newest AS n
  CROSS JOIN chosen AS c
)

SELECT
  d.snapshot_date,
  d.cohort_start,
  d.cohort_end,
  DATE_SUB(d.cohort_start, INTERVAL 1 YEAR) AS comparison_start,
  d.purge_boundary,
  d.maturation_days,
  d.settle_days,
  d.z,
  d.target_precision,
  d.loose_precision,
  d.high_floor,
  d.min_per_side,
  d.group_size
FROM derived AS d
