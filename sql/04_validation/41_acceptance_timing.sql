-- When does acceptance actually happen, and does the votes table agree with
-- the question table about who was accepted?
--
-- Purpose:  Two things the analysis window rests on.
--           (a) Is `vote_type_id = 1` really "accepted by the asker"? If every
--               accepted question has exactly such a vote on its accepted
--               answer, the mapping holds. This used to be a comment saying
--               "verified"; now it is a number.
--           (b) How long does acceptance take? The maturation window in
--               so_analysis.params has to be justified by the latency
--               distribution, not picked by feel. The distribution is measured
--               on a fully matured cohort (the calendar year three years before
--               the snapshot), so it is not itself censored.
-- Source:   posts_questions (two narrow columns, one year), so_analysis
--           post_vote_dates, question_cohort, question_outcomes, params
-- Grain:    one row (a summary)
-- Cost:     see results/run_log.md
--
-- Latency is in whole calendar days because the vote dates are date-only.

WITH params AS (
  SELECT
    p.snapshot_date,
    p.maturation_days,
    DATE_TRUNC(DATE_SUB(p.snapshot_date, INTERVAL 3 YEAR), YEAR) AS matured_year_start
  FROM `so_analysis.params` AS p
),

matured_accepted AS (
  SELECT
    q.accepted_answer_id,
    DATE(q.creation_date) AS asked_on
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
  CROSS JOIN params AS p
  WHERE q.accepted_answer_id IS NOT NULL
    AND DATE(q.creation_date) >= p.matured_year_start
    AND DATE(q.creation_date) < DATE_ADD(p.matured_year_start, INTERVAL 1 YEAR)
),

latency AS (
  SELECT
    ma.asked_on,
    v.accepted_on,
    DATE_DIFF(v.accepted_on, ma.asked_on, DAY) AS days_to_accept
  FROM matured_accepted AS ma
  LEFT JOIN `so_analysis.post_vote_dates` AS v
    ON v.post_id = ma.accepted_answer_id
),

current_cohort AS (
  SELECT
    COUNTIF(c.was_ever_accepted) AS accepted_questions,
    COUNTIF(c.was_ever_accepted AND o.accepted_on IS NOT NULL) AS matched_to_a_vote
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  WHERE c.cohort_region = 'current_year'
)

SELECT
  EXTRACT(YEAR FROM (SELECT p.matured_year_start FROM params AS p)) AS matured_cohort_year,
  COUNT(*) AS matured_accepted_questions,
  ROUND(SAFE_DIVIDE(COUNTIF(l.accepted_on IS NOT NULL), COUNT(*)), 4) AS matured_share_with_acceptance_vote,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 0), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_same_day,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 1), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_1_day,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 7), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_7_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 30), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_30_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 90), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_90_days,
  ROUND(SAFE_DIVIDE(COUNTIF(l.days_to_accept <= 365), COUNTIF(l.accepted_on IS NOT NULL)), 4) AS within_365_days,
  (SELECT p.maturation_days FROM params AS p) AS chosen_window_days,
  (SELECT cc.accepted_questions FROM current_cohort AS cc) AS current_cohort_accepted_questions,
  ROUND((SELECT SAFE_DIVIDE(cc.matched_to_a_vote, cc.accepted_questions) FROM current_cohort AS cc), 4)
    AS current_cohort_share_with_acceptance_vote
FROM latency AS l
