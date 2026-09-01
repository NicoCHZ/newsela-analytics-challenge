-- Prompt 1, step 6: every tag that clears the floor, with everything measured
-- about it.
--
-- Purpose:  The rankings query shows fifteen tags at each end. This is the
--           whole eligible population, so a reader can check where any tag
--           sits and see the moderation and supply measures behind it, rather
--           than taking the two short lists on trust.
-- Source:   so_analysis.tag_funnel, so_analysis.ranking_params
-- Grain:    one row per eligible tag in the current cohort
-- Cost:     see results/run_log.md

WITH eligible AS (
  SELECT
    t.tag,
    t.n_questions,
    t.acceptance_rate,
    t.acceptance_wilson_lower,
    t.acceptance_wilson_upper,
    t.answer_rate,
    t.positive_answer_rate,
    t.acceptance_given_answered,
    t.acceptance_per_answer,
    t.self_accepted_share,
    t.closed_share,
    t.duplicate_share,
    t.median_days_to_first_answer,
    t.answers_per_question,
    t.distinct_answerers_per_100_questions,
    t.window_capture_ratio,
    t.first_tag_share,
    t.acceptance_rate_as_first_tag,
    t.acceptance_rate_as_later_tag,
    t.acceptance_rate_lifetime
  FROM `so_analysis.tag_funnel` AS t
  CROSS JOIN `so_analysis.ranking_params` AS r
  WHERE t.cohort_region = 'current_year'
    AND t.n_questions >= r.min_questions
)

SELECT
  ROW_NUMBER() OVER (ORDER BY e.acceptance_wilson_lower DESC, e.tag) AS rank_from_top,
  ROW_NUMBER() OVER (ORDER BY e.acceptance_wilson_upper ASC, e.tag) AS rank_from_bottom,
  e.tag,
  e.n_questions,
  ROUND(e.acceptance_rate, 4) AS acceptance_rate,
  ROUND(e.acceptance_wilson_lower, 4) AS acceptance_ci_low,
  ROUND(e.acceptance_wilson_upper, 4) AS acceptance_ci_high,
  ROUND(e.answer_rate, 4) AS answer_rate,
  ROUND(e.positive_answer_rate, 4) AS positive_answer_rate,
  ROUND(e.acceptance_given_answered, 4) AS acceptance_given_answered,
  ROUND(e.acceptance_per_answer, 4) AS acceptance_per_answer,
  ROUND(e.self_accepted_share, 4) AS self_accepted_share,
  ROUND(e.closed_share, 4) AS closed_in_window_share,
  ROUND(e.duplicate_share, 4) AS duplicate_share,
  e.median_days_to_first_answer,
  ROUND(e.answers_per_question, 2) AS answers_per_question,
  ROUND(e.distinct_answerers_per_100_questions, 1) AS distinct_answerers_per_100_questions,
  ROUND(e.window_capture_ratio, 4) AS window_capture_ratio,
  ROUND(e.first_tag_share, 4) AS first_tag_share,
  ROUND(e.acceptance_rate_as_first_tag, 4) AS acceptance_rate_as_first_tag,
  ROUND(e.acceptance_rate_as_later_tag, 4) AS acceptance_rate_as_later_tag,
  ROUND(e.acceptance_rate_lifetime, 4) AS acceptance_rate_lifetime
FROM eligible AS e
ORDER BY rank_from_top
