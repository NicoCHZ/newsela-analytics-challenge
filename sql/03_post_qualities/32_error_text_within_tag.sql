-- Prompt 2, follow-up: is the error-message effect real, or just a proxy for topic?
--
-- Purpose:  Questions that paste an error message or stack trace get accepted
--           less often, which is the opposite of what I expected. The obvious
--           alternative explanation is that error text simply marks the
--           environment-dependent topics that already rank badly in Prompt 1 —
--           in which case the attribute tells us nothing the tag did not.
--
--           This compares questions with and without error text INSIDE each tag,
--           so the topic is held constant. If the gap survives, the attribute is
--           carrying information of its own.
-- Source:   so_analysis.question_cohort, question_outcomes, tag_funnel
-- Grain:    one row (a summary)
-- Cost:     see results/run_log.md
--
-- Restricted to tags with at least 100 questions on each side of the comparison,
-- so no tag contributes a rate built on a handful of rows.

WITH question_tags AS (
  SELECT
    tag,
    c.body_has_error_signature,
    o.accepted_in_window
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  WHERE c.asked_on >= '2022-01-01'
    AND tag != ''
),

eligible_tags AS (
  SELECT t.tag
  FROM `so_analysis.tag_funnel` AS t
  WHERE t.cohort = '2022_ytd'
    AND t.n_questions >= 886
),

per_tag AS (
  SELECT
    qt.tag,
    COUNTIF(qt.body_has_error_signature) AS n_with_error,
    COUNTIF(NOT qt.body_has_error_signature) AS n_without_error,
    SAFE_DIVIDE(COUNTIF(qt.body_has_error_signature AND qt.accepted_in_window),
                COUNTIF(qt.body_has_error_signature)) AS acceptance_with_error,
    SAFE_DIVIDE(COUNTIF(NOT qt.body_has_error_signature AND qt.accepted_in_window),
                COUNTIF(NOT qt.body_has_error_signature)) AS acceptance_without_error
  FROM question_tags AS qt
  INNER JOIN eligible_tags AS e
    ON e.tag = qt.tag
  GROUP BY qt.tag
  HAVING COUNTIF(qt.body_has_error_signature) >= 100
     AND COUNTIF(NOT qt.body_has_error_signature) >= 100
),

overall AS (
  SELECT
    SAFE_DIVIDE(COUNTIF(qt.body_has_error_signature AND qt.accepted_in_window),
                COUNTIF(qt.body_has_error_signature))
    - SAFE_DIVIDE(COUNTIF(NOT qt.body_has_error_signature AND qt.accepted_in_window),
                  COUNTIF(NOT qt.body_has_error_signature)) AS gap
  FROM question_tags AS qt
)

SELECT
  COUNT(*) AS tags_compared,
  ROUND((SELECT gap FROM overall), 4) AS gap_ignoring_tag,
  -- Volume-weighted average of the gap measured inside each tag.
  ROUND(SAFE_DIVIDE(
    SUM((p.acceptance_with_error - p.acceptance_without_error) * (p.n_with_error + p.n_without_error)),
    SUM(p.n_with_error + p.n_without_error)), 4) AS gap_within_tag,
  COUNTIF(p.acceptance_with_error < p.acceptance_without_error) AS tags_where_error_text_is_worse,
  COUNTIF(p.acceptance_with_error > p.acceptance_without_error) AS tags_where_error_text_is_better
FROM per_tag AS p
