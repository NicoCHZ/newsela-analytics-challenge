-- Prompt 1c: testing the "it's the people, not the questions" hypothesis.
--
-- Purpose:  Hypothesis B says the tag gap is really a gap between asker
--           populations: some tags attract people who never return to mark an
--           answer. The way to test that without an experiment is to hold the
--           person constant and let only the topic vary: restrict to askers who
--           posted in BOTH a high-approval and a low-approval tag, and compare
--           each person's own acceptance rate across the two. If the gap
--           survives inside the same person, the difference lives in the
--           questions. If it collapses, it lives in the people.
-- Source:   so_analysis.question_cohort, question_outcomes, tag_funnel,
--           params, ranking_params
-- Grain:    one row (a summary of the comparisons)
-- Cost:     see results/run_log.md
--
-- Two design choices that the first version of this test got wrong:
--
--   * SPLIT THE DATA. The high and low tag groups are chosen on the questions
--     with an even id and the gap is measured on the odd ones. Choosing "the
--     fifty lowest tags" and then measuring how low they are on the same
--     questions rewards the choice for its own noise (regression to the mean).
--
--   * ONE ESTIMATOR, ONE WEIGHTING. The population gap counts questions. A
--     plain average of each person's own difference counts people, so someone
--     with twenty questions on one side and one on the other weighs the same as
--     anyone else, and the two numbers are not comparable. The within-asker
--     estimate below is the asker-fixed-effects estimator for a binary
--     regressor: each person's own difference, weighted by
--     n_high * n_low / (n_high + n_low), which is question-weighted and lines
--     up with the population gap. Its standard error treats each asker as one
--     independent cluster. The person-weighted mean is still reported, labelled.
--
-- Reading the numbers:
--   full_population_gap        the raw between-group difference on the evaluation
--                              half: what Prompt 1 reports.
--   dual_askers_unpaired_gap   the same difference among only the people who
--                              appear on both sides. Moving from the first number
--                              to this one is a SELECTION effect: people who ask
--                              across both worlds are not typical askers.
--   within_asker_gap           the difference INSIDE each person. Moving from the
--                              second number to this one is the part attributable
--                              to who is asking.
--   ..._answer_stage / ..._conversion_stage
--                              the same within-person comparison for each funnel
--                              stage: does the person get answered less in low
--                              tags, and do they accept less once answered?
--
-- Caveat, stated up front: people who post in both a high- and a low-approval
-- tag are more experienced and more polyglot by construction. This identifies
-- the effect among them, not among everyone, and it cannot be extrapolated to
-- one-time askers, who are exactly the population Hypothesis B is about. It
-- is a directional test, not a verdict.

WITH params AS (
  SELECT
    p.group_size,
    p.z,
    r.min_questions
  FROM `so_analysis.params` AS p
  CROSS JOIN `so_analysis.ranking_params` AS r
),

question_tags AS (
  SELECT
    c.question_id,
    c.owner_user_id,
    tag,
    MOD(c.question_id, 2) = 0 AS is_selection_half,
    o.answered_in_window,
    o.accepted_in_window
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  WHERE c.cohort_region = 'current_year'
    AND tag != ''
),

eligible_tags AS (
  SELECT
    t.tag
  FROM `so_analysis.tag_funnel` AS t
  CROSS JOIN params AS p
  WHERE t.cohort_region = 'current_year'
    AND t.n_questions >= p.min_questions
),

-- Tag groups chosen on the selection half only, with the same interval bounds
-- the main ranking uses.
selection_rates AS (
  SELECT
    qt.tag,
    COUNT(*) AS n,
    SAFE_DIVIDE(COUNTIF(qt.accepted_in_window), COUNT(*)) AS rate
  FROM question_tags AS qt
  INNER JOIN eligible_tags AS e
    ON e.tag = qt.tag
  WHERE qt.is_selection_half
  GROUP BY qt.tag
),

bounded AS (
  SELECT
    s.tag,
    SAFE_DIVIDE(
      s.rate + SAFE_DIVIDE(POW(p.z, 2), 2 * s.n)
        - p.z * SQRT(SAFE_DIVIDE(s.rate * (1 - s.rate), s.n) + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(s.n, 2))),
      1 + SAFE_DIVIDE(POW(p.z, 2), s.n)) AS wilson_lower,
    SAFE_DIVIDE(
      s.rate + SAFE_DIVIDE(POW(p.z, 2), 2 * s.n)
        + p.z * SQRT(SAFE_DIVIDE(s.rate * (1 - s.rate), s.n) + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(s.n, 2))),
      1 + SAFE_DIVIDE(POW(p.z, 2), s.n)) AS wilson_upper
  FROM selection_rates AS s
  CROSS JOIN params AS p
),

tag_groups AS (
  SELECT
    b.tag,
    'high' AS tag_group
  FROM bounded AS b
  CROSS JOIN params AS p
  QUALIFY ROW_NUMBER() OVER (ORDER BY b.wilson_lower DESC, b.tag) <= p.group_size
  UNION ALL
  SELECT
    b.tag,
    'low' AS tag_group
  FROM bounded AS b
  CROSS JOIN params AS p
  QUALIFY ROW_NUMBER() OVER (ORDER BY b.wilson_upper ASC, b.tag) <= p.group_size
),

-- Evaluation half. A question is assigned to a group only if it touches that
-- group and not the other. Questions carrying both a high and a low tag are
-- ambiguous and are dropped rather than arbitrarily assigned.
question_group AS (
  SELECT
    qt.question_id,
    qt.owner_user_id,
    qt.answered_in_window,
    qt.accepted_in_window,
    LOGICAL_OR(g.tag_group = 'high') AS touches_high,
    LOGICAL_OR(g.tag_group = 'low') AS touches_low
  FROM question_tags AS qt
  INNER JOIN tag_groups AS g
    ON g.tag = qt.tag
  WHERE NOT qt.is_selection_half
    AND qt.owner_user_id IS NOT NULL  -- a deleted account cannot be paired with itself
  GROUP BY qt.question_id, qt.owner_user_id, qt.answered_in_window, qt.accepted_in_window
),

classified AS (
  SELECT
    qg.owner_user_id,
    qg.touches_high AS is_high,
    qg.answered_in_window,
    qg.accepted_in_window
  FROM question_group AS qg
  WHERE qg.touches_high != qg.touches_low  -- exactly one of the two
),

-- Comparison 1: the whole evaluation half, question-weighted.
full_population AS (
  SELECT
    COUNT(*) AS n_questions,
    SAFE_DIVIDE(COUNTIF(c.is_high AND c.accepted_in_window), COUNTIF(c.is_high))
      - SAFE_DIVIDE(COUNTIF(NOT c.is_high AND c.accepted_in_window), COUNTIF(NOT c.is_high)) AS gap
  FROM classified AS c
),

per_asker AS (
  SELECT
    c.owner_user_id,
    COUNTIF(c.is_high) AS n_high,
    COUNTIF(NOT c.is_high) AS n_low,
    COUNTIF(c.is_high AND c.accepted_in_window) AS k_high,
    COUNTIF(NOT c.is_high AND c.accepted_in_window) AS k_low,
    COUNTIF(c.is_high AND c.answered_in_window) AS a_high,
    COUNTIF(NOT c.is_high AND c.answered_in_window) AS a_low,
    COUNTIF(c.is_high AND c.answered_in_window AND c.accepted_in_window) AS ka_high,
    COUNTIF(NOT c.is_high AND c.answered_in_window AND c.accepted_in_window) AS ka_low
  FROM classified AS c
  GROUP BY c.owner_user_id
),

-- Askers who appear on both sides, with their own difference and its weight.
dual_askers AS (
  SELECT
    pa.owner_user_id,
    pa.n_high,
    pa.n_low,
    pa.k_high,
    pa.k_low,
    pa.a_high,
    pa.a_low,
    SAFE_DIVIDE(pa.n_high * pa.n_low, pa.n_high + pa.n_low) AS w,
    SAFE_DIVIDE(pa.k_high, pa.n_high) - SAFE_DIVIDE(pa.k_low, pa.n_low) AS d_accepted,
    SAFE_DIVIDE(pa.a_high, pa.n_high) - SAFE_DIVIDE(pa.a_low, pa.n_low) AS d_answered,
    -- Conversion stage: only defined for people answered on both sides.
    SAFE_DIVIDE(pa.a_high * pa.a_low, pa.a_high + pa.a_low) AS w_conversion,
    SAFE_DIVIDE(pa.ka_high, pa.a_high) - SAFE_DIVIDE(pa.ka_low, pa.a_low) AS d_conversion
  FROM per_asker AS pa
  WHERE pa.n_high > 0
    AND pa.n_low > 0
),

-- Comparison 2: the same people, but NOT paired: question-weighted rates.
dual_unpaired AS (
  SELECT
    COUNT(*) AS n_askers,
    SAFE_DIVIDE(SUM(d.k_high), SUM(d.n_high)) - SAFE_DIVIDE(SUM(d.k_low), SUM(d.n_low)) AS gap
  FROM dual_askers AS d
),

-- Comparison 3: within each person.
estimates AS (
  SELECT
    SAFE_DIVIDE(SUM(d.w * d.d_accepted), SUM(d.w)) AS fe_accepted,
    SAFE_DIVIDE(SUM(d.w * d.d_answered), SUM(d.w)) AS fe_answered,
    SAFE_DIVIDE(
      SUM(IF(d.a_high > 0 AND d.a_low > 0, d.w_conversion * d.d_conversion, 0)),
      SUM(IF(d.a_high > 0 AND d.a_low > 0, d.w_conversion, 0))) AS fe_conversion,
    COUNTIF(d.a_high > 0 AND d.a_low > 0) AS askers_answered_on_both_sides,
    AVG(d.d_accepted) AS person_weighted_gap,
    SAFE_DIVIDE(STDDEV_SAMP(d.d_accepted), SQRT(COUNT(*))) AS person_weighted_se,
    SAFE_DIVIDE(
      SUM(IF(d.n_high >= 2 AND d.n_low >= 2, d.w * d.d_accepted, 0)),
      SUM(IF(d.n_high >= 2 AND d.n_low >= 2, d.w, 0))) AS fe_accepted_two_each_side,
    COUNTIF(d.n_high >= 2 AND d.n_low >= 2) AS askers_with_two_each_side
  FROM dual_askers AS d
),

-- Cluster-robust standard error for the weighted estimate: each asker is one
-- independent cluster.
fe_error AS (
  SELECT
    SAFE_DIVIDE(SQRT(SUM(POW(d.w * (d.d_accepted - e.fe_accepted), 2))), SUM(d.w)) AS fe_accepted_se
  FROM dual_askers AS d
  CROSS JOIN estimates AS e
)

SELECT
  (SELECT fp.n_questions FROM full_population AS fp) AS questions_in_evaluation_half,
  (SELECT du.n_askers FROM dual_unpaired AS du) AS dual_askers,
  ROUND((SELECT fp.gap FROM full_population AS fp), 4) AS full_population_gap,
  ROUND((SELECT du.gap FROM dual_unpaired AS du), 4) AS dual_askers_unpaired_gap,
  ROUND(e.fe_accepted, 4) AS within_asker_gap,
  ROUND(fe.fe_accepted_se, 4) AS within_asker_gap_se,
  ROUND(e.person_weighted_gap, 4) AS within_asker_gap_person_weighted,
  ROUND(e.person_weighted_se, 4) AS within_asker_gap_person_weighted_se,
  ROUND(e.fe_answered, 4) AS within_asker_answer_stage_gap,
  ROUND(e.fe_conversion, 4) AS within_asker_conversion_stage_gap,
  e.askers_answered_on_both_sides,
  e.askers_with_two_each_side,
  ROUND(e.fe_accepted_two_each_side, 4) AS within_asker_gap_two_each_side
FROM estimates AS e
CROSS JOIN fe_error AS fe
