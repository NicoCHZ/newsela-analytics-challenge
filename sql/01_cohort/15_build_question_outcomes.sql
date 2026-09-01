-- Cohort 6/7: what actually happened to each question, and WHEN.
--
-- Purpose:  The question table records whether a question was *ever* answered
--           or accepted, with no time limit. That is not comparable across a
--           cohort: a question from January had eight months of exposure, one
--           from August had one. This table adds the timing, so every outcome
--           can be measured inside an identical window, and adds what
--           moderation did to the question in that same window.
-- Source:   so_analysis.question_cohort, answers, post_vote_dates,
--           question_moderation, params — no public table is read here
-- Output:   so_analysis.question_outcomes — one row per question in the cohort
-- Cost:     see results/run_log.md (megabytes)
--
-- Timing resolution: vote dates are date-only (13_build_post_vote_dates), so
-- everything here is computed in whole calendar days. Mixing a midnight vote
-- stamp with the question's full timestamp would make every same-day
-- acceptance — 43% of them — look like it happened before the question.
--
-- Every window flag is COALESCEd to FALSE so that "no answer" and "not within
-- the window" behave identically in COUNTIF and in comparisons downstream.

CREATE OR REPLACE TABLE `so_analysis.question_outcomes` AS

WITH cohort AS (
  SELECT
    c.question_id,
    c.asked_on,
    c.cohort_region,
    c.accepted_answer_id,
    c.owner_user_id AS asker_user_id,
    DATE_ADD(c.asked_on, INTERVAL p.maturation_days DAY) AS window_end
  FROM `so_analysis.question_cohort` AS c
  CROSS JOIN `so_analysis.params` AS p
),

cohort_answers AS (
  SELECT
    a.question_id,
    a.answer_id,
    a.answerer_user_id,
    a.answered_on,
    a.lifetime_score,
    v.first_upvote_on
  FROM `so_analysis.answers` AS a
  INNER JOIN cohort AS c
    ON c.question_id = a.question_id
  LEFT JOIN `so_analysis.post_vote_dates` AS v
    ON v.post_id = a.answer_id
),

answers_per_question AS (
  SELECT
    c.question_id,
    COUNTIF(a.answer_id IS NOT NULL) AS n_answers,
    COUNTIF(a.answered_on <= c.window_end) AS n_answers_in_window,
    COUNT(DISTINCT a.answerer_user_id) AS n_distinct_answerers,
    MIN(a.answered_on) AS first_answer_on,
    -- The first day on which any answer to this question had been upvoted:
    -- "somebody knew", as opposed to "somebody replied". Dated, so it can be
    -- measured inside the window like everything else.
    MIN(a.first_upvote_on) AS first_upvoted_answer_on,
    MAX(a.lifetime_score) AS max_answer_score
  FROM cohort AS c
  LEFT JOIN cohort_answers AS a
    ON a.question_id = c.question_id
  GROUP BY c.question_id
),

accepted_answer AS (
  SELECT
    c.question_id,
    v.accepted_on,
    a.answerer_user_id AS accepted_answerer_user_id,
    a.lifetime_score AS accepted_answer_score
  FROM cohort AS c
  LEFT JOIN `so_analysis.post_vote_dates` AS v
    ON v.post_id = c.accepted_answer_id
  LEFT JOIN `so_analysis.answers` AS a
    ON a.answer_id = c.accepted_answer_id
  WHERE c.accepted_answer_id IS NOT NULL
)

SELECT
  c.question_id,
  c.asked_on,
  c.cohort_region,
  c.window_end,

  apq.n_answers,
  apq.n_answers_in_window,
  apq.n_distinct_answerers,
  apq.first_answer_on,
  DATE_DIFF(apq.first_answer_on, c.asked_on, DAY) AS days_to_first_answer,
  apq.first_upvoted_answer_on,
  apq.max_answer_score,
  aa.accepted_on,
  m.first_closed_on AS closed_on,
  m.last_reopened_on AS reopened_on,
  m.duplicate_linked_on,

  -- Self-acceptance is a different phenomenon from the community solving your
  -- problem: it means the asker worked it out and wrote it up themselves.
  COALESCE(aa.accepted_answerer_user_id = c.asker_user_id, FALSE) AS was_self_accepted,
  -- The asker's pick and the crowd's pick disagree more often than people expect.
  COALESCE(aa.accepted_answer_score < apq.max_answer_score, FALSE) AS accepted_was_not_top_scored,

  -- ---- The funnel stages, all measured inside the same window ----
  COALESCE(apq.first_answer_on <= c.window_end, FALSE) AS answered_in_window,
  COALESCE(apq.first_upvoted_answer_on <= c.window_end, FALSE) AS positively_answered_in_window,
  COALESCE(aa.accepted_on <= c.window_end, FALSE) AS accepted_in_window,
  COALESCE(m.first_closed_on <= c.window_end, FALSE) AS closed_in_window,
  m.duplicate_linked_on IS NOT NULL AS is_duplicate,
  COALESCE(aa.accepted_on <= c.window_end AND aa.accepted_answerer_user_id = c.asker_user_id, FALSE)
    AS self_accepted_in_window,
  COALESCE(aa.accepted_on <= c.window_end, FALSE) AND NOT COALESCE(m.first_closed_on <= c.window_end, FALSE)
    AS accepted_open_in_window,

  -- Lifetime equivalents, kept so the README can quantify how much the window
  -- costs and show how the ranking behaves under either choice.
  apq.first_answer_on IS NOT NULL AS answered_ever,
  aa.accepted_on IS NOT NULL AS accepted_ever
FROM cohort AS c
LEFT JOIN answers_per_question AS apq
  ON apq.question_id = c.question_id
LEFT JOIN accepted_answer AS aa
  ON aa.question_id = c.question_id
LEFT JOIN `so_analysis.question_moderation` AS m
  ON m.question_id = c.question_id
