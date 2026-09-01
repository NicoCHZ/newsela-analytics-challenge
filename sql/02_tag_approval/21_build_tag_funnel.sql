-- Prompt 1, step 2: build the per-tag funnel.
--
-- Purpose:  For every tag, measure the stages a question passes through:
--             asked -> answered -> answered well -> accepted
--           A single "approval rate" collapses these into one number and hides
--           which stage a tag is actually failing at. Alongside the stages, the
--           table records what the two things that could explain a stage look
--           like: moderation (closed, duplicate) and answerer supply (how fast
--           the first answer arrives, how many people answer at all).
-- Source:   so_analysis.question_cohort, question_outcomes, answers, params
-- Output:   so_analysis.tag_funnel: one row per (cohort_region, tag)
-- Cost:     see results/run_log.md (reads only the materialized tables)
--
-- Two things this table deliberately does NOT do:
--   * It does not apply a volume floor. The floor is a presentation decision and
--     belongs in the query that ranks, not in the table that measures. That way
--     the sensitivity analysis can vary it without a rebuild.
--   * It does not claim tags are independent. A question carries up to five tags
--     and is counted once under each, so these are MARGINAL rates. The number of
--     tag rows exceeds the number of questions, by design.
--
-- The first-tag columns support a specific hypothesis: that low-approval tags
-- are the generic ones people add in third or fourth position (browser, proxy,
-- server), not the subject of the question. Comparing a tag's acceptance rate
-- when it leads the tag list against when it trails it is the cheapest test.

CREATE OR REPLACE TABLE `so_analysis.tag_funnel` AS

WITH question_tags AS (
  SELECT
    c.cohort_region,
    tag,
    tag_offset = 0 AS is_first_tag,
    c.question_id,
    o.window_end,
    o.answered_in_window,
    o.positively_answered_in_window,
    o.accepted_in_window,
    o.self_accepted_in_window,
    o.accepted_open_in_window,
    o.closed_in_window,
    o.is_duplicate,
    o.n_answers_in_window,
    o.days_to_first_answer,
    o.accepted_ever,
    o.answered_ever
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag WITH OFFSET AS tag_offset
  -- SPLIT on a trailing delimiter yields an empty element; drop it explicitly
  -- rather than letting it become a phantom tag.
  WHERE tag != ''
),

-- Answerer supply: distinct people who answered this tag's questions inside
-- the window. This needs the answer rows, not the per-question counts.
answerers AS (
  SELECT
    qt.cohort_region,
    qt.tag,
    COUNT(DISTINCT a.answerer_user_id) AS n_distinct_answerers
  FROM question_tags AS qt
  INNER JOIN `so_analysis.answers` AS a
    ON a.question_id = qt.question_id
  WHERE a.answered_on <= qt.window_end
  GROUP BY qt.cohort_region, qt.tag
),

aggregated AS (
  SELECT
    qt.cohort_region,
    qt.tag,
    COUNT(*) AS n_questions,
    COUNTIF(qt.is_first_tag) AS n_as_first_tag,
    COUNTIF(qt.answered_in_window) AS n_answered,
    COUNTIF(qt.positively_answered_in_window) AS n_positively_answered,
    COUNTIF(qt.accepted_in_window) AS n_accepted,
    COUNTIF(qt.is_first_tag AND qt.accepted_in_window) AS n_accepted_as_first_tag,
    COUNTIF(qt.self_accepted_in_window) AS n_self_accepted,
    COUNTIF(qt.accepted_open_in_window) AS n_accepted_open,
    COUNTIF(qt.closed_in_window) AS n_closed,
    COUNTIF(qt.is_duplicate) AS n_duplicate,
    SUM(qt.n_answers_in_window) AS n_answers_in_window,
    COUNTIF(qt.answered_in_window AND qt.days_to_first_answer <= 1) AS n_answered_within_a_day,
    APPROX_QUANTILES(IF(qt.answered_in_window, qt.days_to_first_answer, NULL), 2)[OFFSET(1)]
      AS median_days_to_first_answer,
    COUNTIF(qt.accepted_ever) AS n_accepted_ever,
    COUNTIF(qt.answered_ever) AS n_answered_ever
  FROM question_tags AS qt
  GROUP BY qt.cohort_region, qt.tag
),

rated AS (
  SELECT
    a.cohort_region,
    a.tag,
    a.n_questions,
    a.n_as_first_tag,
    a.n_answered,
    a.n_positively_answered,
    a.n_accepted,
    a.n_accepted_as_first_tag,
    a.n_self_accepted,
    a.n_accepted_open,
    a.n_closed,
    a.n_duplicate,
    a.n_answers_in_window,
    a.n_answered_within_a_day,
    a.median_days_to_first_answer,
    a.n_accepted_ever,
    a.n_answered_ever,
    COALESCE(an.n_distinct_answerers, 0) AS n_distinct_answerers,

    -- Stage rates, all measured inside the same window.
    SAFE_DIVIDE(a.n_answered, a.n_questions) AS answer_rate,
    SAFE_DIVIDE(a.n_positively_answered, a.n_questions) AS positive_answer_rate,
    SAFE_DIVIDE(a.n_accepted, a.n_questions) AS acceptance_rate,
    -- The conversion that separates the hypotheses: given that somebody
    -- answered, did the asker come back and mark it?
    SAFE_DIVIDE(a.n_accepted, a.n_answered) AS acceptance_given_answered,
    -- The prompt's phrase read literally: accepted answers over answers written.
    SAFE_DIVIDE(a.n_accepted, a.n_answers_in_window) AS acceptance_per_answer,
    SAFE_DIVIDE(a.n_self_accepted, a.n_accepted) AS self_accepted_share,

    -- Moderation and supply.
    SAFE_DIVIDE(a.n_closed, a.n_questions) AS closed_share,
    SAFE_DIVIDE(a.n_duplicate, a.n_questions) AS duplicate_share,
    SAFE_DIVIDE(a.n_answers_in_window, a.n_questions) AS answers_per_question,
    SAFE_DIVIDE(a.n_answered_within_a_day, a.n_questions) AS answered_within_a_day_rate,
    SAFE_DIVIDE(COALESCE(an.n_distinct_answerers, 0) * 100, a.n_questions) AS distinct_answerers_per_100_questions,

    -- How much of the tag's eventual acceptance the window captures.
    SAFE_DIVIDE(a.n_accepted, a.n_accepted_ever) AS window_capture_ratio,

    -- Tag position.
    SAFE_DIVIDE(a.n_as_first_tag, a.n_questions) AS first_tag_share,
    SAFE_DIVIDE(a.n_accepted_as_first_tag, a.n_as_first_tag) AS acceptance_rate_as_first_tag,
    SAFE_DIVIDE(a.n_accepted - a.n_accepted_as_first_tag, a.n_questions - a.n_as_first_tag) AS acceptance_rate_as_later_tag,

    -- Lifetime versions, for the "does the window change the answer?" check.
    SAFE_DIVIDE(a.n_accepted_ever, a.n_questions) AS acceptance_rate_lifetime,
    SAFE_DIVIDE(a.n_answered_ever, a.n_questions) AS answer_rate_lifetime
  FROM aggregated AS a
  LEFT JOIN answerers AS an
    ON an.cohort_region = a.cohort_region
   AND an.tag = a.tag
)

SELECT
  r.cohort_region,
  r.tag,
  r.n_questions,
  r.n_as_first_tag,
  r.n_answered,
  r.n_positively_answered,
  r.n_accepted,
  r.n_accepted_as_first_tag,
  r.n_self_accepted,
  r.n_accepted_open,
  r.n_closed,
  r.n_duplicate,
  r.n_answers_in_window,
  r.n_answered_within_a_day,
  r.n_distinct_answerers,
  r.median_days_to_first_answer,
  r.n_accepted_ever,
  r.n_answered_ever,
  r.answer_rate,
  r.positive_answer_rate,
  r.acceptance_rate,
  r.acceptance_given_answered,
  r.acceptance_per_answer,
  r.self_accepted_share,
  r.closed_share,
  r.duplicate_share,
  r.answers_per_question,
  r.answered_within_a_day_rate,
  r.distinct_answerers_per_100_questions,
  r.window_capture_ratio,
  r.first_tag_share,
  r.acceptance_rate_as_first_tag,
  r.acceptance_rate_as_later_tag,
  r.acceptance_rate_lifetime,
  r.answer_rate_lifetime,

  -- Wilson score interval on the acceptance rate.
  -- Ranking on a raw proportion lets a tag with 30 questions outrank one with
  -- 30,000 on luck alone. The interval bound makes a tag earn its position:
  -- small samples get pulled toward the middle automatically, with no arbitrary
  -- cutoff doing the work.
  SAFE_DIVIDE(
    r.acceptance_rate + SAFE_DIVIDE(POW(p.z, 2), 2 * r.n_questions)
      - p.z * SQRT(
          SAFE_DIVIDE(r.acceptance_rate * (1 - r.acceptance_rate), r.n_questions)
          + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(r.n_questions, 2))
        ),
    1 + SAFE_DIVIDE(POW(p.z, 2), r.n_questions)
  ) AS acceptance_wilson_lower,
  SAFE_DIVIDE(
    r.acceptance_rate + SAFE_DIVIDE(POW(p.z, 2), 2 * r.n_questions)
      + p.z * SQRT(
          SAFE_DIVIDE(r.acceptance_rate * (1 - r.acceptance_rate), r.n_questions)
          + SAFE_DIVIDE(POW(p.z, 2), 4 * POW(r.n_questions, 2))
        ),
    1 + SAFE_DIVIDE(POW(p.z, 2), r.n_questions)
  ) AS acceptance_wilson_upper
FROM rated AS r
CROSS JOIN `so_analysis.params` AS p
