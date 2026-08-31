-- Profiling 3/3: When does acceptance actually happen, and can I trust the clock?
--
-- Purpose:  Two things I need to settle before choosing an observation window.
--           (a) Is `votes.vote_type_id = 1` really "accepted by the asker"?
--               I am not willing to build the censoring correction on an
--               undocumented magic number without checking it.
--           (b) How long does acceptance take? The maturation window has to be
--               justified by the latency distribution, not picked by feel.
-- Source:   posts_questions, votes
-- Grain:    one row (a summary)
-- Cost:     see results/run_log.md
--
-- FINDING (a): every accepted question in 2022 matched a type-1 vote on its
--   accepted answer. The mapping holds.
-- FINDING (b): `votes.creation_date` is date-only — 100% of type-1 vote
--   timestamps sit at exactly midnight. Comparing it to a question's
--   full-precision timestamp makes ~44% of same-day acceptances look like they
--   happened *before* the question was asked. All latency math below is
--   therefore done in whole calendar days, which is the real resolution of the
--   data. This is the kind of silent precision mismatch that produces negative
--   durations in production dashboards.

WITH accepted_questions AS (
  SELECT
    q.accepted_answer_id,
    DATE(q.creation_date) AS asked_on
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
  -- 2019 is a fully matured cohort: three years of exposure before the snapshot,
  -- so its latency distribution is not itself censored.
  WHERE q.accepted_answer_id IS NOT NULL
    AND q.creation_date >= '2019-01-01'
    AND q.creation_date < '2020-01-01'
),

acceptance_events AS (
  SELECT
    v.post_id,
    DATE(MIN(v.creation_date)) AS accepted_on
  FROM `bigquery-public-data.stackoverflow.votes` AS v
  WHERE v.vote_type_id = 1  -- AcceptedByOriginator; verified above
  GROUP BY v.post_id
),

latency AS (
  SELECT DATE_DIFF(ae.accepted_on, aq.asked_on, DAY) AS days_to_accept
  FROM accepted_questions AS aq
  INNER JOIN acceptance_events AS ae
    ON ae.post_id = aq.accepted_answer_id
)

SELECT
  COUNT(*) AS accepted_questions,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 0), COUNT(*)), 4) AS within_same_day,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 1), COUNT(*)), 4) AS within_1_day,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 7), COUNT(*)), 4) AS within_7_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 30), COUNT(*)), 4) AS within_30_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 90), COUNT(*)), 4) AS within_90_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 365), COUNT(*)), 4) AS within_365_days
FROM latency AS l
