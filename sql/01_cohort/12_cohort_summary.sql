-- Cohort summary: every baseline figure quoted in the README.
--
-- Purpose:  The README claims each of its numbers is reproducible. The tag and
--           attribute tables cover most of them; this covers the rest — cohort
--           size, the three funnel baselines, and the two figures used to argue
--           that acceptance is one person's judgement rather than the community's.
-- Source:   so_analysis.question_cohort, so_analysis.question_outcomes
-- Grain:    one row
-- Cost:     see results/run_log.md

WITH joined AS (
  SELECT
    c.asked_on,
    c.snapshot_date,
    o.answered_in_window,
    o.positively_answered_in_window,
    o.accepted_in_window,
    o.accepted_ever,
    o.n_answers,
    o.was_self_accepted,
    o.accepted_was_not_top_scored
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  WHERE c.asked_on >= '2022-01-01'
)

SELECT
  COUNT(*) AS questions_in_cohort,
  MIN(j.asked_on) AS cohort_start,
  MAX(j.asked_on) AS cohort_end,
  MAX(j.snapshot_date) AS snapshot_date,

  ROUND(SAFE_DIVIDE(COUNTIF(j.answered_in_window), COUNT(*)), 4) AS answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.positively_answered_in_window), COUNT(*)), 4) AS positive_answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.accepted_in_window), COUNT(*)), 4) AS acceptance_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(j.accepted_in_window), COUNTIF(j.answered_in_window)), 4) AS acceptance_given_answered,

  -- Acceptance is the asker's call, not the community's. These two numbers are
  -- how much that distinction is worth in practice.
  ROUND(SAFE_DIVIDE(COUNTIF(j.was_self_accepted), COUNTIF(j.accepted_ever)), 4) AS self_accepted_share,
  -- Restricted to questions that actually had a choice to make: with one answer
  -- the accepted one is trivially also the top-scored one.
  ROUND(SAFE_DIVIDE(
    COUNTIF(j.accepted_ever AND j.n_answers > 1 AND j.accepted_was_not_top_scored),
    COUNTIF(j.accepted_ever AND j.n_answers > 1)), 4) AS accepted_not_top_scored_share
FROM joined AS j
