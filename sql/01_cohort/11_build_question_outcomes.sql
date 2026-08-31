-- Cohort 2/2: what actually happened to each question, and WHEN.
--
-- Purpose:  The question table records whether a question was *ever* answered or
--           accepted, with no time limit. That is not comparable across a cohort:
--           a question from January had 20 months of exposure, one from August
--           had one. This table adds the timing, so every outcome can be measured
--           inside an identical 30-day window.
-- Source:   posts_answers (narrow columns only — never `body`), votes
-- Output:   so_analysis.question_outcomes — one row per question in the cohort
-- Cost:     see results/run_log.md
--
-- Timing resolution: `votes.creation_date` is date-only (verified in
-- 00_profiling/03), so everything here is computed in whole calendar days.
-- Mixing it with the question's full timestamp would produce negative durations
-- for the ~43% of acceptances that happen on the day the question was asked.

CREATE OR REPLACE TABLE `so_analysis.question_outcomes` AS

WITH params AS (
  SELECT
    MAX(c.maturation_days) AS maturation_days
  FROM `so_analysis.question_cohort` AS c
),

cohort AS (
  SELECT
    c.question_id,
    c.asked_on,
    c.accepted_answer_id,
    c.owner_user_id AS asker_user_id
  FROM `so_analysis.question_cohort` AS c
),

-- Answers can never predate their question, so bounding by the cohort's first
-- day is safe and keeps the scan honest about what it needs.
answers AS (
  SELECT
    a.parent_id AS question_id,
    a.id AS answer_id,
    DATE(a.creation_date) AS answered_on,
    a.score,
    a.owner_user_id AS answerer_user_id
  FROM `bigquery-public-data.stackoverflow.posts_answers` AS a
  WHERE a.creation_date >= '2021-01-01'
),

answers_per_question AS (
  SELECT
    a.question_id,
    COUNT(*) AS n_answers,
    MIN(a.answered_on) AS first_answer_on,
    -- First answer that the community actually endorsed, as opposed to merely
    -- the first answer to arrive. The gap between these two is the difference
    -- between "somebody replied" and "somebody knew".
    MIN(IF(a.score > 0, a.answered_on, NULL)) AS first_positive_answer_on,
    MAX(a.score) AS max_answer_score
  FROM answers AS a
  GROUP BY a.question_id
),

-- vote_type_id = 1 is AcceptedByOriginator. Verified in 00_profiling/03.
acceptance_events AS (
  SELECT
    v.post_id AS answer_id,
    DATE(MIN(v.creation_date)) AS accepted_on
  FROM `bigquery-public-data.stackoverflow.votes` AS v
  WHERE v.vote_type_id = 1
  GROUP BY v.post_id
),

accepted_answer_detail AS (
  SELECT
    a.answer_id,
    a.answerer_user_id,
    a.score AS accepted_answer_score
  FROM answers AS a
)

SELECT
  c.question_id,
  c.asked_on,

  apq.n_answers,
  apq.first_answer_on,
  apq.first_positive_answer_on,
  apq.max_answer_score,
  ae.accepted_on,

  -- Self-acceptance is a different phenomenon from the community solving your
  -- problem: it means the asker worked it out and wrote it up themselves.
  aad.answerer_user_id IS NOT NULL
    AND aad.answerer_user_id = c.asker_user_id AS was_self_accepted,

  -- The asker's pick and the crowd's pick disagree more often than people expect.
  aad.accepted_answer_score < apq.max_answer_score AS accepted_was_not_top_scored,

  -- ---- The three funnel stages, measured in an identical window ----
  DATE_DIFF(apq.first_answer_on, c.asked_on, DAY) <= (SELECT maturation_days FROM params)
    AS answered_in_window,
  DATE_DIFF(apq.first_positive_answer_on, c.asked_on, DAY) <= (SELECT maturation_days FROM params)
    AS positively_answered_in_window,
  DATE_DIFF(ae.accepted_on, c.asked_on, DAY) <= (SELECT maturation_days FROM params)
    AS accepted_in_window,

  -- Lifetime equivalents, kept so the README can quantify how much the window
  -- costs us and show that the ranking survives either choice.
  apq.first_answer_on IS NOT NULL AS answered_ever,
  ae.accepted_on IS NOT NULL AS accepted_ever
FROM cohort AS c
LEFT JOIN answers_per_question AS apq
  ON apq.question_id = c.question_id
LEFT JOIN acceptance_events AS ae
  ON ae.answer_id = c.accepted_answer_id
LEFT JOIN accepted_answer_detail AS aad
  ON aad.answer_id = c.accepted_answer_id
