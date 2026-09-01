-- Prompt 1, step 3: the answer. Highest and lowest approval tags.
--
-- Purpose:  Rank tags, and show why the obvious way of doing it does not work.
-- Source:   so_analysis.tag_funnel, so_analysis.ranking_params
-- Grain:    one row per (ranking, tag), fifteen per ranking
-- Cost:     see results/run_log.md
--
-- Two ranking decisions:
--
-- 1. THE VOLUME FLOOR is derived, not chosen; see 20_build_ranking_params.
--    Without it the top of the list belongs to tags with five questions.
--
-- 2. RANK BY THE INTERVAL BOUND, NOT THE POINT ESTIMATE, and flip which bound
--    at each end: the highest list is ordered by the rate I am confident a tag
--    is at LEAST at, the lowest list by the rate I am confident it is at MOST
--    at. With the floor in place this moves tags at the margin rather than
--    changing the lists (see 24_ranking_sensitivity); without it, it would be
--    doing all the work.
--
-- The `naive_*` rankings are included on purpose: they are what this analysis
-- would have concluded with neither decision.
--
-- Every ordering ends with the tag name so that ties resolve the same way on
-- every run and the committed CSV does not churn.

WITH scored AS (
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
    t.n_questions >= r.min_questions AS is_eligible
  FROM `so_analysis.tag_funnel` AS t
  CROSS JOIN `so_analysis.ranking_params` AS r
  WHERE t.cohort_region = 'current_year'
),

ranked AS (
  SELECT
    'highest_approval' AS ranking,
    s.tag,
    ROW_NUMBER() OVER (ORDER BY s.acceptance_wilson_lower DESC, s.tag) AS rank
  FROM scored AS s
  WHERE s.is_eligible
  UNION ALL
  SELECT
    'lowest_approval',
    s.tag,
    ROW_NUMBER() OVER (ORDER BY s.acceptance_wilson_upper ASC, s.tag)
  FROM scored AS s
  WHERE s.is_eligible
  UNION ALL
  -- What the same question looks like with no floor and no interval.
  SELECT
    'naive_highest',
    s.tag,
    ROW_NUMBER() OVER (ORDER BY s.acceptance_rate DESC, s.n_questions DESC, s.tag)
  FROM scored AS s
  UNION ALL
  SELECT
    'naive_lowest',
    s.tag,
    ROW_NUMBER() OVER (ORDER BY s.acceptance_rate ASC, s.n_questions DESC, s.tag)
  FROM scored AS s
)

SELECT
  r.ranking,
  r.rank,
  s.tag,
  s.n_questions,
  ROUND(s.acceptance_rate, 4) AS acceptance_rate,
  ROUND(s.acceptance_wilson_lower, 4) AS acceptance_ci_low,
  ROUND(s.acceptance_wilson_upper, 4) AS acceptance_ci_high,
  -- The funnel behind the headline number.
  ROUND(s.answer_rate, 4) AS answer_rate,
  ROUND(s.positive_answer_rate, 4) AS positive_answer_rate,
  ROUND(s.acceptance_given_answered, 4) AS acceptance_given_answered,
  ROUND(s.acceptance_per_answer, 4) AS acceptance_per_answer,
  ROUND(s.self_accepted_share, 4) AS self_accepted_share,
  -- Moderation and supply, the two things that could explain a stage.
  ROUND(s.closed_share, 4) AS closed_in_window_share,
  ROUND(s.duplicate_share, 4) AS duplicate_share,
  s.median_days_to_first_answer,
  ROUND(s.answers_per_question, 2) AS answers_per_question,
  ROUND(s.distinct_answerers_per_100_questions, 1) AS distinct_answerers_per_100_questions,
  ROUND(s.window_capture_ratio, 4) AS window_capture_ratio
FROM ranked AS r
INNER JOIN scored AS s
  ON s.tag = r.tag
WHERE r.rank <= 15
ORDER BY r.ranking, r.rank
