-- Prompt 1, step 1: the volume floor, derived rather than chosen.
--
-- Purpose:  The median tag in this cohort has a handful of questions; ranking
--           on raw rates hands the top of the list to tags with three questions
--           and a lucky streak (02_tag_approval/22 shows exactly that). The
--           floor is the smallest sample that pins a tag's rate to within the
--           target precision at 95% confidence, given the cohort's own base
--           rate, which is the standard sample size for a proportion:
--             n >= z^2 * p * (1 - p) / m^2
--           It is computed once here and read by every query that ranks, so the
--           sensitivity check can vary it without anyone editing a literal, and
--           a refreshed dataset gets a floor that matches its own base rate.
-- Source:   so_analysis.question_outcomes, so_analysis.params
-- Output:   so_analysis.ranking_params (exactly one row)
-- Cost:     see results/run_log.md

CREATE OR REPLACE TABLE `so_analysis.ranking_params` AS

WITH base_rate AS (
  SELECT
    SAFE_DIVIDE(COUNTIF(o.accepted_in_window), COUNT(*)) AS p
  FROM `so_analysis.question_outcomes` AS o
  WHERE o.cohort_region = 'current_year'
)

SELECT
  b.p AS base_acceptance_rate,
  p.z,
  p.target_precision,
  p.loose_precision,
  CAST(CEIL(POW(p.z, 2) * b.p * (1 - b.p) / POW(p.target_precision, 2)) AS INT64) AS min_questions,
  CAST(CEIL(POW(p.z, 2) * b.p * (1 - b.p) / POW(p.loose_precision, 2)) AS INT64) AS min_questions_loose,
  p.high_floor AS min_questions_high
FROM base_rate AS b
CROSS JOIN `so_analysis.params` AS p
