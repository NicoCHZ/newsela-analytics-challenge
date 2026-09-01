-- Prompt 1, step 4: how much of the answer is the methodology?
--
-- Purpose:  Every ranking in 22_tag_rankings.sql rests on choices I made: which
--           slice of time counts as "current", whether outcomes are measured in
--           a fixed window or over the question's whole life, how many
--           questions a tag needs to qualify, whether to rank on the observed
--           rate or on a confidence bound, and, above all, what "approved
--           answer" means. Each is defensible. None is forced.
--
--           This query re-runs the ranking with one choice changed at a time.
-- Source:   so_analysis.tag_funnel, so_analysis.ranking_params
-- Grain:    one row per variant
-- Cost:     see results/run_log.md
--
-- HOW STABILITY IS MEASURED, and why "how many of the top ten survive" is not
-- enough on its own. Raising the floor to 2,000 questions removes six of the
-- primary top ten BY DEFINITION (they have fewer than 2,000 questions), and a
-- count of survivors would report that as instability when nothing about the
-- ranking moved. So every variant reports:
--   * how many of the primary top/bottom ten are still ELIGIBLE under the
--     variant, and how many of those are retained; retained is to be read
--     against eligible, not against ten;
--   * the rank correlation between the variant and the primary ranking over
--     the tags eligible under both (Spearman, computed as the correlation of
--     ranks within that intersection);
--   * the new entrants, so the reader can judge whether they are the same kind
--     of tag as the ones they displaced.
--
-- The two previous-year variants are not a like-for-like time check. The
-- months of the previous year that were more than 365 days old at the snapshot
-- have already had their unanswered, non-positive-score questions deleted by
-- the site (see 00_profiling/02); they are a survivor population, and their row
-- is here to show what that does to a ranking. The October-December months are
-- the clean out-of-window comparison.

WITH params AS (
  SELECT
    r.min_questions,
    r.min_questions_loose,
    r.min_questions_high,
    r.z
  FROM `so_analysis.ranking_params` AS r
),

spec AS (
  SELECT
    s.ord,
    s.variant,
    s.region,
    s.floor,
    s.metric,
    s.use_wilson
  FROM params AS p
  CROSS JOIN UNNEST([
    STRUCT(0 AS ord, 'primary: current year, 30-day window, derived floor, Wilson bound' AS variant,
           'current_year' AS region, p.min_questions AS floor, 'accepted' AS metric, TRUE AS use_wilson),
    STRUCT(1, 'lifetime outcomes instead of the 30-day window',
           'current_year', p.min_questions, 'accepted_lifetime', TRUE),
    STRUCT(2, 'previous year, months not yet purged by the site (Oct-Dec)',
           'prior_year_unpurged', p.min_questions, 'accepted', TRUE),
    STRUCT(3, 'previous year, months already purged (Jan-Sep): a survivor population',
           'prior_year_purged', p.min_questions, 'accepted', TRUE),
    STRUCT(4, 'looser floor: 5-point precision instead of 3',
           'current_year', p.min_questions_loose, 'accepted', TRUE),
    STRUCT(5, 'stricter floor: 2,000 questions',
           'current_year', p.min_questions_high, 'accepted', TRUE),
    STRUCT(6, 'rank on the observed rate instead of a confidence bound',
           'current_year', p.min_questions, 'accepted', FALSE),
    STRUCT(7, '"approved" = an answer the community upvoted within the window',
           'current_year', p.min_questions, 'upvoted', TRUE),
    STRUCT(8, '"rate of approved answers" per answer written, not per question',
           'current_year', p.min_questions, 'per_answer', TRUE),
    STRUCT(9, 'excluding answers the asker wrote themselves',
           'current_year', p.min_questions, 'not_self', TRUE),
    STRUCT(10, 'excluding questions closed within the window',
           'current_year', p.min_questions, 'open_only', TRUE)
  ]) AS s
),

scored AS (
  SELECT
    s.ord,
    s.variant,
    s.use_wilson,
    t.tag,
    CASE s.metric
      WHEN 'accepted' THEN t.n_accepted
      WHEN 'accepted_lifetime' THEN t.n_accepted_ever
      WHEN 'upvoted' THEN t.n_positively_answered
      WHEN 'per_answer' THEN t.n_accepted
      WHEN 'not_self' THEN t.n_accepted - t.n_self_accepted
      WHEN 'open_only' THEN t.n_accepted_open
    END AS k,
    CASE s.metric
      WHEN 'per_answer' THEN t.n_answers_in_window
      WHEN 'open_only' THEN t.n_questions - t.n_closed
      ELSE t.n_questions
    END AS n
  FROM spec AS s
  INNER JOIN `so_analysis.tag_funnel` AS t
    ON t.cohort_region = s.region
  WHERE t.n_questions >= s.floor
),

-- Bounds recomputed per variant, so each metric gets bounds on ITS rate.
bounded AS (
  SELECT
    sc.ord,
    sc.variant,
    sc.use_wilson,
    sc.tag,
    SAFE_DIVIDE(sc.k, sc.n) AS rate,
    SAFE_DIVIDE(
      SAFE_DIVIDE(sc.k, sc.n) + SAFE_DIVIDE(POW(p.z, 2), 2 * sc.n)
        - p.z * SQRT(SAFE_DIVIDE(SAFE_DIVIDE(sc.k, sc.n) * (1 - SAFE_DIVIDE(sc.k, sc.n)), sc.n)
                     + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(sc.n, 2))),
      1 + SAFE_DIVIDE(POW(p.z, 2), sc.n)) AS wilson_lower,
    SAFE_DIVIDE(
      SAFE_DIVIDE(sc.k, sc.n) + SAFE_DIVIDE(POW(p.z, 2), 2 * sc.n)
        + p.z * SQRT(SAFE_DIVIDE(SAFE_DIVIDE(sc.k, sc.n) * (1 - SAFE_DIVIDE(sc.k, sc.n)), sc.n)
                     + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(sc.n, 2))),
      1 + SAFE_DIVIDE(POW(p.z, 2), sc.n)) AS wilson_upper
  FROM scored AS sc
  CROSS JOIN params AS p
  WHERE sc.n > 0
),

ranked AS (
  SELECT
    b.ord,
    b.variant,
    b.tag,
    ROW_NUMBER() OVER (PARTITION BY b.ord ORDER BY IF(b.use_wilson, b.wilson_lower, b.rate) DESC, b.tag) AS rank_high,
    ROW_NUMBER() OVER (PARTITION BY b.ord ORDER BY IF(b.use_wilson, b.wilson_upper, b.rate) ASC, b.tag) AS rank_low
  FROM bounded AS b
),

primary_ranks AS (
  SELECT
    r.tag,
    r.rank_high AS primary_rank_high,
    r.rank_low AS primary_rank_low
  FROM ranked AS r
  WHERE r.ord = 0
),

-- Tags eligible under both the primary and the variant, re-ranked inside that
-- intersection so the two rank columns are comparable.
paired AS (
  SELECT
    r.ord,
    r.tag,
    r.rank_high,
    r.rank_low,
    pr.primary_rank_high,
    pr.primary_rank_low,
    ROW_NUMBER() OVER (PARTITION BY r.ord ORDER BY r.rank_high) AS variant_rank_in_intersection,
    ROW_NUMBER() OVER (PARTITION BY r.ord ORDER BY pr.primary_rank_high) AS primary_rank_in_intersection
  FROM ranked AS r
  INNER JOIN primary_ranks AS pr
    ON pr.tag = r.tag
),

per_variant AS (
  SELECT
    pd.ord,
    COUNT(*) AS tags_eligible_in_both,
    CORR(pd.variant_rank_in_intersection, pd.primary_rank_in_intersection) AS rank_correlation,
    COUNTIF(pd.primary_rank_high <= 10) AS top10_still_eligible,
    COUNTIF(pd.primary_rank_high <= 10 AND pd.rank_high <= 10) AS top10_retained,
    COUNTIF(pd.primary_rank_low <= 10) AS bottom10_still_eligible,
    COUNTIF(pd.primary_rank_low <= 10 AND pd.rank_low <= 10) AS bottom10_retained
  FROM paired AS pd
  GROUP BY pd.ord
),

entrants AS (
  SELECT
    r.ord,
    COUNT(*) AS eligible_tags,
    STRING_AGG(IF(r.rank_high <= 10 AND COALESCE(pr.primary_rank_high, 11) > 10, r.tag, NULL), ' ' ORDER BY r.rank_high)
      AS new_entrants_at_the_top,
    STRING_AGG(IF(r.rank_low <= 10 AND COALESCE(pr.primary_rank_low, 11) > 10, r.tag, NULL), ' ' ORDER BY r.rank_low)
      AS new_entrants_at_the_bottom
  FROM ranked AS r
  LEFT JOIN primary_ranks AS pr
    ON pr.tag = r.tag
  GROUP BY r.ord
)

SELECT
  s.variant,
  e.eligible_tags,
  pv.tags_eligible_in_both,
  ROUND(pv.rank_correlation, 3) AS rank_correlation_with_primary,
  pv.top10_still_eligible,
  pv.top10_retained,
  pv.bottom10_still_eligible,
  pv.bottom10_retained,
  e.new_entrants_at_the_top,
  e.new_entrants_at_the_bottom
FROM spec AS s
INNER JOIN per_variant AS pv
  ON pv.ord = s.ord
INNER JOIN entrants AS e
  ON e.ord = s.ord
ORDER BY s.ord
