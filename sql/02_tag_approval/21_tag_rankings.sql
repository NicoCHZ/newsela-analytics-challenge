-- Prompt 1, step 2: the answer. Highest and lowest approval tags.
--
-- Purpose:  Rank tags, and show why the obvious way of doing it does not work.
-- Source:   so_analysis.tag_funnel
-- Grain:    one row per (ranking, tag)
-- Cost:     see results/run_log.md
--
-- Two ranking decisions, both of which change the answer completely:
--
-- 1. THE VOLUME FLOOR is derived, not chosen. The median tag in this cohort has
--    five questions; ranking on raw rates hands the top of the list to tags with
--    a handful of questions and a lucky streak. The floor below is the smallest
--    sample that pins a tag's rate to within +/-3 percentage points at 95%
--    confidence, given the cohort's own base rate. 3 points is the resolution
--    at which I would be willing to tell someone two tags differ.
--
-- 2. RANK BY THE INTERVAL BOUND, NOT THE POINT ESTIMATE, and flip which bound
--    at each end: the highest list is ordered by the rate I am confident a tag
--    is at LEAST at, the lowest list by the rate I am confident it is at MOST
--    at. Using the point estimate at both ends would quietly reward small
--    samples in both directions.
--
-- The `naive_*` rankings are included on purpose. They are what this analysis
-- would have concluded without either decision, and the contrast is the honest
-- way to show how much the methodology is doing.

WITH params AS (
  SELECT
    '2022_ytd' AS cohort,
    0.03 AS target_precision  -- +/- 3 percentage points
),

base_rate AS (
  SELECT SAFE_DIVIDE(SUM(t.n_accepted), SUM(t.n_questions)) AS p
  FROM `so_analysis.tag_funnel` AS t
  INNER JOIN params AS pm ON t.cohort = pm.cohort
),

volume_floor AS (
  -- n >= z^2 * p(1-p) / m^2 : the standard sample size for a proportion.
  SELECT CAST(CEIL(
    POW(1.96, 2) * br.p * (1 - br.p) / POW(pm.target_precision, 2)
  ) AS INT64) AS min_questions
  FROM base_rate AS br
  CROSS JOIN params AS pm
),

eligible AS (
  SELECT t.*
  FROM `so_analysis.tag_funnel` AS t
  INNER JOIN params AS pm ON t.cohort = pm.cohort
  CROSS JOIN volume_floor AS vf
  WHERE t.n_questions >= vf.min_questions
),

ranked AS (
  SELECT 'highest_approval' AS ranking, e.*,
    ROW_NUMBER() OVER (ORDER BY e.acceptance_wilson_lower DESC) AS rank
  FROM eligible AS e
  UNION ALL
  SELECT 'lowest_approval', e.*,
    ROW_NUMBER() OVER (ORDER BY e.acceptance_wilson_upper ASC)
  FROM eligible AS e
  UNION ALL
  -- What the same question looks like with no floor and no interval.
  SELECT 'naive_highest', t.*,
    ROW_NUMBER() OVER (ORDER BY t.acceptance_rate DESC, t.n_questions DESC)
  FROM `so_analysis.tag_funnel` AS t
  INNER JOIN params AS pm ON t.cohort = pm.cohort
  UNION ALL
  SELECT 'naive_lowest', t.*,
    ROW_NUMBER() OVER (ORDER BY t.acceptance_rate ASC, t.n_questions DESC)
  FROM `so_analysis.tag_funnel` AS t
  INNER JOIN params AS pm ON t.cohort = pm.cohort
)

SELECT
  r.ranking,
  r.rank,
  r.tag,
  r.n_questions,
  ROUND(r.acceptance_rate, 4) AS acceptance_rate,
  ROUND(r.acceptance_wilson_lower, 4) AS acceptance_ci_low,
  ROUND(r.acceptance_wilson_upper, 4) AS acceptance_ci_high,
  -- The funnel behind the headline number.
  ROUND(r.answer_rate, 4) AS answer_rate,
  ROUND(r.positive_answer_rate, 4) AS positive_answer_rate,
  ROUND(r.acceptance_given_answered, 4) AS acceptance_given_answered
FROM ranked AS r
WHERE r.rank <= 15
ORDER BY r.ranking, r.rank
