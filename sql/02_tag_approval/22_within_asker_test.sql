-- Prompt 1c: testing the "it's the people, not the questions" hypothesis.
--
-- Purpose:  Hypothesis B says the tag gap is really a gap between asker
--           populations: some tags attract people who never return to mark an
--           answer. The way to test that without an experiment is to hold the
--           person constant and let only the topic vary.
--
--           I restrict to askers who posted in BOTH a high-approval and a
--           low-approval tag during the cohort window, and compare their own
--           acceptance rate across the two. If the gap survives inside the same
--           person, the difference lives in the questions (Hypothesis A). If it
--           collapses, it lives in the people (Hypothesis B).
--
-- Source:   so_analysis.question_cohort, so_analysis.question_outcomes,
--           so_analysis.tag_funnel
-- Grain:    one row (a summary of three comparisons)
-- Cost:     see results/run_log.md
--
-- Reading the three numbers:
--   full_population_gap      - the raw between-tag difference; what Prompt 1 reports.
--   dual_askers_unpaired_gap - the same difference among only the people who
--                              appear on both sides. Moving from the first number
--                              to this one is a SELECTION effect: people who ask
--                              across both worlds are not typical askers.
--   within_asker_paired_gap  - the average difference INSIDE each person. Moving
--                              from the second number to this one is the part
--                              genuinely attributable to who is asking.
--
-- Caveat, stated up front: people who post in both a high- and a low-approval
-- tag are more experienced and more polyglot by construction. This identifies
-- the effect among them, not among everyone, and it cannot be extrapolated to
-- one-time askers — who are exactly the population Hypothesis B is about. This
-- is a directional test, not a verdict.

WITH params AS (
  SELECT '2022_ytd' AS cohort, 886 AS min_questions, 50 AS group_size
),

eligible_tags AS (
  SELECT t.tag, t.acceptance_wilson_lower, t.acceptance_wilson_upper
  FROM `so_analysis.tag_funnel` AS t
  INNER JOIN params AS p ON t.cohort = p.cohort
  WHERE t.n_questions >= (SELECT min_questions FROM params)
),

tag_groups AS (
  SELECT tag, 'high' AS tag_group
  FROM eligible_tags
  ORDER BY acceptance_wilson_lower DESC
  LIMIT 50
),

tag_groups_low AS (
  SELECT tag, 'low' AS tag_group
  FROM eligible_tags
  ORDER BY acceptance_wilson_upper ASC
  LIMIT 50
),

grouped_tags AS (
  SELECT tag, tag_group FROM tag_groups
  UNION ALL
  SELECT tag, tag_group FROM tag_groups_low
),

-- A question is assigned to a group only if it touches that group and not the
-- other. Questions carrying both a high and a low tag are genuinely ambiguous
-- and are dropped rather than arbitrarily assigned.
question_group AS (
  SELECT
    c.question_id,
    c.owner_user_id,
    o.accepted_in_window,
    LOGICAL_OR(g.tag_group = 'high') AS touches_high,
    LOGICAL_OR(g.tag_group = 'low') AS touches_low
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  INNER JOIN grouped_tags AS g
    ON g.tag = tag
  WHERE c.asked_on >= '2022-01-01'
    AND c.owner_user_id IS NOT NULL  -- anonymous askers cannot be paired
  GROUP BY c.question_id, c.owner_user_id, o.accepted_in_window
),

classified AS (
  SELECT
    qg.owner_user_id,
    IF(qg.touches_high, 'high', 'low') AS tag_group,
    qg.accepted_in_window
  FROM question_group AS qg
  WHERE qg.touches_high != qg.touches_low  -- exactly one of the two
),

-- Comparison 1: the whole population.
full_population AS (
  SELECT
    SAFE_DIVIDE(COUNTIF(c.tag_group = 'high' AND c.accepted_in_window), COUNTIF(c.tag_group = 'high'))
      - SAFE_DIVIDE(COUNTIF(c.tag_group = 'low' AND c.accepted_in_window), COUNTIF(c.tag_group = 'low'))
      AS gap,
    COUNT(*) AS n_questions
  FROM classified AS c
),

-- Askers who appear on both sides.
dual_askers AS (
  SELECT
    c.owner_user_id,
    COUNTIF(c.tag_group = 'high') AS n_high,
    COUNTIF(c.tag_group = 'low') AS n_low,
    SAFE_DIVIDE(COUNTIF(c.tag_group = 'high' AND c.accepted_in_window), COUNTIF(c.tag_group = 'high')) AS rate_high,
    SAFE_DIVIDE(COUNTIF(c.tag_group = 'low' AND c.accepted_in_window), COUNTIF(c.tag_group = 'low')) AS rate_low
  FROM classified AS c
  GROUP BY c.owner_user_id
  HAVING COUNTIF(c.tag_group = 'high') > 0 AND COUNTIF(c.tag_group = 'low') > 0
),

-- Comparison 2: same difference, restricted to those people, but NOT paired.
dual_unpaired AS (
  SELECT
    SAFE_DIVIDE(SUM(d.rate_high * d.n_high), SUM(d.n_high))
      - SAFE_DIVIDE(SUM(d.rate_low * d.n_low), SUM(d.n_low)) AS gap
  FROM dual_askers AS d
)

-- Comparison 3: the paired within-asker difference.
SELECT
  (SELECT n_questions FROM full_population) AS questions_in_comparison,
  (SELECT COUNT(*) FROM dual_askers) AS dual_askers,
  ROUND((SELECT gap FROM full_population), 4) AS full_population_gap,
  ROUND((SELECT gap FROM dual_unpaired), 4) AS dual_askers_unpaired_gap,
  ROUND(AVG(d.rate_high - d.rate_low), 4) AS within_asker_paired_gap,
  ROUND(STDDEV_SAMP(d.rate_high - d.rate_low) / SQRT(COUNT(*)), 4) AS within_asker_standard_error
FROM dual_askers AS d
