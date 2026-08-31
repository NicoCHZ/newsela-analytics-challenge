-- Prompt 1, step 1: build the per-tag funnel.
--
-- Purpose:  For every tag, measure the three stages a question passes through:
--             asked → answered → answered well → accepted
--           A single "approval rate" collapses these into one number and hides
--           which stage a tag is actually failing at. Keeping them apart is what
--           lets Prompt 1a's two hypotheses be told apart at all.
-- Source:   so_analysis.question_cohort, so_analysis.question_outcomes
-- Output:   so_analysis.tag_funnel — one row per (cohort, tag)
-- Cost:     see results/run_log.md (reads only the narrow cohort tables)
--
-- Two things this table deliberately does NOT do:
--   * It does not apply a volume floor. The floor is a presentation decision and
--     belongs in the query that ranks, not in the table that measures — that way
--     the sensitivity analysis can vary it without a rebuild.
--   * It does not claim tags are independent. A question carries up to five tags
--     and is counted once under each, so these are MARGINAL rates. The number of
--     tag rows will exceed the number of questions, by design. See `n_questions`
--     against the cohort total in the README.

CREATE OR REPLACE TABLE `so_analysis.tag_funnel` AS

WITH question_tags AS (
  SELECT
    -- Two cohorts: the most recent (partial) year in the data, and the last
    -- complete calendar year as a maturity control.
    IF(c.asked_on >= '2022-01-01', '2022_ytd', '2021_full') AS cohort,
    tag,
    c.question_id,
    o.answered_in_window,
    o.positively_answered_in_window,
    o.accepted_in_window,
    o.accepted_ever,
    o.answered_ever,
    o.was_self_accepted
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  -- SPLIT on a trailing delimiter yields an empty element; drop it explicitly
  -- rather than letting it become a phantom tag.
  WHERE tag != ''
),

aggregated AS (
  SELECT
    qt.cohort,
    qt.tag,
    COUNT(*) AS n_questions,
    COUNTIF(qt.answered_in_window) AS n_answered,
    COUNTIF(qt.positively_answered_in_window) AS n_positively_answered,
    COUNTIF(qt.accepted_in_window) AS n_accepted,
    COUNTIF(qt.accepted_ever) AS n_accepted_ever,
    COUNTIF(qt.answered_ever) AS n_answered_ever,
    COUNTIF(qt.was_self_accepted) AS n_self_accepted
  FROM question_tags AS qt
  GROUP BY qt.cohort, qt.tag
)

SELECT
  a.cohort,
  a.tag,
  a.n_questions,
  a.n_answered,
  a.n_positively_answered,
  a.n_accepted,

  -- Stage rates, all measured inside the same 30-day window.
  SAFE_DIVIDE(a.n_answered, a.n_questions) AS answer_rate,
  SAFE_DIVIDE(a.n_positively_answered, a.n_questions) AS positive_answer_rate,
  SAFE_DIVIDE(a.n_accepted, a.n_questions) AS acceptance_rate,

  -- The conversion that separates the two hypotheses: given that somebody
  -- answered, did the asker come back and mark it?
  SAFE_DIVIDE(a.n_accepted, a.n_answered) AS acceptance_given_answered,

  SAFE_DIVIDE(a.n_self_accepted, NULLIF(a.n_accepted_ever, 0)) AS self_accepted_share,

  -- Lifetime versions, for the "does the window change the answer?" check.
  SAFE_DIVIDE(a.n_accepted_ever, a.n_questions) AS acceptance_rate_lifetime,
  SAFE_DIVIDE(a.n_answered_ever, a.n_questions) AS answer_rate_lifetime,

  -- Wilson score interval on the acceptance rate.
  -- Ranking on a raw proportion lets a tag with 30 questions outrank one with
  -- 30,000 on luck alone. The interval bound makes a tag earn its position:
  -- small samples get pulled toward the middle automatically, with no arbitrary
  -- cutoff doing the work.
  SAFE_DIVIDE(
    SAFE_DIVIDE(a.n_accepted, a.n_questions) + POW(1.96, 2) / (2 * a.n_questions)
      - 1.96 * SQRT(
          SAFE_DIVIDE(SAFE_DIVIDE(a.n_accepted, a.n_questions)
            * (1 - SAFE_DIVIDE(a.n_accepted, a.n_questions)), a.n_questions)
          + SAFE_DIVIDE(POW(1.96, 2), 4 * POW(a.n_questions, 2))
        ),
    1 + SAFE_DIVIDE(POW(1.96, 2), a.n_questions)
  ) AS acceptance_wilson_lower,

  SAFE_DIVIDE(
    SAFE_DIVIDE(a.n_accepted, a.n_questions) + POW(1.96, 2) / (2 * a.n_questions)
      + 1.96 * SQRT(
          SAFE_DIVIDE(SAFE_DIVIDE(a.n_accepted, a.n_questions)
            * (1 - SAFE_DIVIDE(a.n_accepted, a.n_questions)), a.n_questions)
          + SAFE_DIVIDE(POW(1.96, 2), 4 * POW(a.n_questions, 2))
        ),
    1 + SAFE_DIVIDE(POW(1.96, 2), a.n_questions)
  ) AS acceptance_wilson_upper
FROM aggregated AS a
