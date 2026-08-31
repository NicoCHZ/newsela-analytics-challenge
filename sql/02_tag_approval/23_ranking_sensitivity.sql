-- Prompt 1, step 3: how much of the answer is the methodology?
--
-- Purpose:  Every ranking in 21_tag_rankings.sql rests on four choices I made:
--           which year counts as "current", whether outcomes are measured in a
--           fixed window or over the tag's whole life, how many questions a tag
--           needs to qualify, and whether to rank on the observed rate or on a
--           confidence bound. Each is defensible. None is forced.
--
--           This query re-runs the ranking with one choice changed at a time and
--           reports how many of the primary top ten and bottom ten survive. If a
--           tag only appears when the settings are exactly right, it is a
--           property of my analysis, not of Stack Overflow.
-- Source:   so_analysis.tag_funnel
-- Grain:    one row per variant
-- Cost:     see results/run_log.md

WITH spec AS (
  SELECT * FROM UNNEST([
    STRUCT('primary - 2022 | 30-day window | floor 886 | Wilson' AS variant,
           '2022_ytd' AS cohort, 886 AS min_questions, 'window' AS metric, TRUE AS use_wilson, 0 AS ord),
    STRUCT('lifetime outcomes instead of a 30-day window',
           '2022_ytd', 886, 'lifetime', TRUE, 1),
    STRUCT('2021 (last complete calendar year) instead of 2022',
           '2021_full', 886, 'window', TRUE, 2),
    STRUCT('volume floor 322 (5pp precision) instead of 886',
           '2022_ytd', 322, 'window', TRUE, 3),
    STRUCT('volume floor 2000 instead of 886',
           '2022_ytd', 2000, 'window', TRUE, 4),
    STRUCT('rank on the observed rate instead of a confidence bound',
           '2022_ytd', 886, 'window', FALSE, 5)
  ])
),

scored AS (
  SELECT
    s.variant,
    s.ord,
    s.use_wilson,
    t.tag,
    t.n_questions,
    IF(s.metric = 'window', t.acceptance_rate, t.acceptance_rate_lifetime) AS rate
  FROM spec AS s
  INNER JOIN `so_analysis.tag_funnel` AS t
    ON t.cohort = s.cohort
  WHERE t.n_questions >= s.min_questions
),

-- Wilson bounds recomputed here so the lifetime variant gets bounds on ITS rate
-- rather than borrowing the windowed ones.
bounded AS (
  SELECT
    sc.*,
    SAFE_DIVIDE(
      sc.rate + POW(1.96, 2) / (2 * sc.n_questions)
        - 1.96 * SQRT(SAFE_DIVIDE(sc.rate * (1 - sc.rate), sc.n_questions)
                      + SAFE_DIVIDE(POW(1.96, 2), 4 * POW(sc.n_questions, 2))),
      1 + SAFE_DIVIDE(POW(1.96, 2), sc.n_questions)) AS wilson_lower,
    SAFE_DIVIDE(
      sc.rate + POW(1.96, 2) / (2 * sc.n_questions)
        + 1.96 * SQRT(SAFE_DIVIDE(sc.rate * (1 - sc.rate), sc.n_questions)
                      + SAFE_DIVIDE(POW(1.96, 2), 4 * POW(sc.n_questions, 2))),
      1 + SAFE_DIVIDE(POW(1.96, 2), sc.n_questions)) AS wilson_upper
  FROM scored AS sc
),

ranked AS (
  SELECT
    b.variant, b.ord, b.tag,
    ROW_NUMBER() OVER (PARTITION BY b.variant
      ORDER BY IF(b.use_wilson, b.wilson_lower, b.rate) DESC) AS rank_high,
    ROW_NUMBER() OVER (PARTITION BY b.variant
      ORDER BY IF(b.use_wilson, b.wilson_upper, b.rate) ASC) AS rank_low
  FROM bounded AS b
),

primary_sets AS (
  SELECT
    ARRAY_AGG(IF(r.rank_high <= 10, r.tag, NULL) IGNORE NULLS) AS top10,
    ARRAY_AGG(IF(r.rank_low <= 10, r.tag, NULL) IGNORE NULLS) AS bottom10
  FROM ranked AS r
  WHERE r.ord = 0
)

SELECT
  r.variant,
  COUNTIF(r.rank_high <= 10 AND r.tag IN UNNEST(p.top10)) AS top10_tags_retained,
  COUNTIF(r.rank_low <= 10 AND r.tag IN UNNEST(p.bottom10)) AS bottom10_tags_retained,
  STRING_AGG(IF(r.rank_high <= 10 AND r.tag NOT IN UNNEST(p.top10), r.tag, NULL), ' ')
    AS new_entrants_at_the_top,
  STRING_AGG(IF(r.rank_low <= 10 AND r.tag NOT IN UNNEST(p.bottom10), r.tag, NULL), ' ')
    AS new_entrants_at_the_bottom
FROM ranked AS r
CROSS JOIN primary_sets AS p
GROUP BY r.variant, r.ord
ORDER BY r.ord
