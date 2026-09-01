-- Cohort 7/7: every baseline figure quoted in the README.
--
-- Purpose:  The README claims each of its numbers is reproducible. The tag and
--           attribute tables cover most of them; this covers the rest — cohort
--           size and boundaries, the funnel baselines, how often moderation
--           intervenes, and the figures used to argue that acceptance is one
--           person's judgement rather than the community's.
-- Source:   so_analysis.question_cohort, question_outcomes, params
-- Grain:    one row
-- Cost:     see results/run_log.md

WITH joined AS (
  SELECT
    c.asked_on,
    o.answered_in_window,
    o.positively_answered_in_window,
    o.accepted_in_window,
    o.closed_in_window,
    o.is_duplicate,
    o.accepted_ever,
    o.n_answers,
    o.days_to_first_answer,
    o.was_self_accepted,
    o.accepted_was_not_top_scored
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  WHERE c.cohort_region = 'current_year'
)

SELECT
  COUNT(*) AS questions_in_cohort,
  MIN(j.asked_on) AS cohort_start,
  MAX(j.asked_on) AS cohort_end,
  (SELECT p.snapshot_date FROM `so_analysis.params` AS p) AS snapshot_date,
  (SELECT p.maturation_days FROM `so_analysis.params` AS p) AS window_days,

  ROUND(SAFE_DIVIDE(COUNTIF(j.answered_in_window), COUNT(*)), 4) AS answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.positively_answered_in_window), COUNT(*)), 4) AS positive_answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.accepted_in_window), COUNT(*)), 4) AS acceptance_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.accepted_in_window), COUNTIF(j.answered_in_window)), 4) AS acceptance_given_answered,
  ROUND(SAFE_DIVIDE(COUNTIF(j.answered_in_window AND j.days_to_first_answer <= 1), COUNT(*)), 4) AS answered_within_a_day_rate,
  APPROX_QUANTILES(IF(j.answered_in_window, j.days_to_first_answer, NULL), 2)[OFFSET(1)] AS median_days_to_first_answer,

  -- Moderation inside the same window.
  ROUND(SAFE_DIVIDE(COUNTIF(j.closed_in_window), COUNT(*)), 4) AS closed_in_window_share,
  ROUND(SAFE_DIVIDE(COUNTIF(j.is_duplicate), COUNT(*)), 4) AS duplicate_share,

  -- Acceptance is the asker's call, not the community's. These numbers are how
  -- much that distinction is worth in practice.
  ROUND(SAFE_DIVIDE(COUNTIF(j.was_self_accepted), COUNTIF(j.accepted_ever)), 4) AS self_accepted_share,
  -- Restricted to questions that actually had a choice to make: with one answer
  -- the accepted one is trivially also the top-scored one.
  ROUND(SAFE_DIVIDE(
    COUNTIF(j.accepted_ever AND j.n_answers > 1 AND j.accepted_was_not_top_scored),
    COUNTIF(j.accepted_ever AND j.n_answers > 1)), 4) AS accepted_not_top_scored_share,
  -- The closest thing to "the asker never came back": an answer the community
  -- had already upvoted inside the window, and no acceptance, ever.
  ROUND(SAFE_DIVIDE(
    COUNTIF(j.positively_answered_in_window AND NOT j.accepted_ever),
    COUNTIF(j.positively_answered_in_window)), 4) AS upvoted_answer_never_accepted_share
FROM joined AS j
