-- Prompt 1, step 5: the figures the README quotes about the tag universe and
-- about how the headline metric splits into its two stages.
--
-- Purpose:  Two kinds of number that the ranking query does not produce:
--           (a) how many tags there are, how many clear the floor, and how much
--               of the cohort they cover, the context for every "top ten";
--           (b) how much of the spread in acceptance across tags comes from
--               whether anyone answers at all, versus whether the asker comes
--               back to accept once answered.
-- Source:   so_analysis.tag_funnel, so_analysis.ranking_params
-- Grain:    one row
-- Cost:     see results/run_log.md
--
-- The decomposition. For every tag,
--   acceptance_rate = answer_rate * acceptance_given_answered
-- exactly, so in logarithms the variance across tags splits into the two
-- stages plus twice their covariance. The covariance term is divided evenly
-- between the two stages, which is the standard convention and the one that
-- makes the two shares add to one. Because the stages are positively
-- correlated (tags that get answered also get accepted), neither share should
-- be read as "independent" of the other; the correlation is reported alongside.

WITH params AS (
  SELECT
    r.min_questions
  FROM `so_analysis.ranking_params` AS r
),

current_tags AS (
  SELECT
    t.tag,
    t.n_questions,
    t.answer_rate,
    t.acceptance_rate,
    t.acceptance_given_answered,
    t.n_questions >= p.min_questions AS is_eligible
  FROM `so_analysis.tag_funnel` AS t
  CROSS JOIN params AS p
  WHERE t.cohort_region = 'current_year'
),

universe AS (
  SELECT
    COUNT(*) AS tags_in_cohort,
    COUNTIF(ct.is_eligible) AS eligible_tags,
    SUM(ct.n_questions) AS tag_assignments,
    SAFE_DIVIDE(SUM(IF(ct.is_eligible, ct.n_questions, 0)), SUM(ct.n_questions)) AS share_of_tag_assignments_covered,
    APPROX_QUANTILES(ct.n_questions, 2)[OFFSET(1)] AS median_questions_per_tag
  FROM current_tags AS ct
),

logs AS (
  SELECT
    LN(ct.answer_rate) AS log_answer_rate,
    LN(ct.acceptance_given_answered) AS log_conversion,
    LN(ct.acceptance_rate) AS log_acceptance_rate
  FROM current_tags AS ct
  WHERE ct.is_eligible
    AND ct.acceptance_rate > 0
),

decomposition AS (
  SELECT
    COUNT(*) AS tags_decomposed,
    SAFE_DIVIDE(VAR_SAMP(l.log_answer_rate) + COVAR_SAMP(l.log_answer_rate, l.log_conversion),
                VAR_SAMP(l.log_acceptance_rate)) AS share_of_spread_from_answer_stage,
    SAFE_DIVIDE(VAR_SAMP(l.log_conversion) + COVAR_SAMP(l.log_answer_rate, l.log_conversion),
                VAR_SAMP(l.log_acceptance_rate)) AS share_of_spread_from_acceptance_stage,
    CORR(l.log_answer_rate, l.log_conversion) AS stage_correlation
  FROM logs AS l
)

SELECT
  u.tags_in_cohort,
  u.eligible_tags,
  (SELECT p.min_questions FROM params AS p) AS volume_floor,
  u.tag_assignments,
  ROUND(u.share_of_tag_assignments_covered, 4) AS share_of_tag_assignments_covered,
  u.median_questions_per_tag,
  d.tags_decomposed,
  ROUND(d.share_of_spread_from_answer_stage, 4) AS share_of_spread_from_answer_stage,
  ROUND(d.share_of_spread_from_acceptance_stage, 4) AS share_of_spread_from_acceptance_stage,
  ROUND(d.stage_correlation, 4) AS stage_correlation
FROM universe AS u
CROSS JOIN decomposition AS d
