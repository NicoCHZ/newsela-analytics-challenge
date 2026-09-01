-- Prompt 2, follow-up: are the post-attribute effects real, or the topic in
-- disguise?
--
-- Purpose:  Every attribute in 31_post_quality_rates is measured across the
--           whole cohort, so each one is confounded with topic: dplyr questions
--           cannot be written without code and rank near the top of Prompt 1;
--           proxy questions rarely contain code and rank near the bottom. A
--           "code blocks" lift could be nothing but Prompt 1 wearing a different
--           label. This compares questions with and without each attribute
--           INSIDE each tag, so the topic is held constant. If the gap survives,
--           the attribute is carrying information of its own.
-- Source:   so_analysis.question_cohort, question_outcomes, asker_history,
--           tag_funnel, params, ranking_params
-- Grain:    one row per attribute
-- Cost:     see results/run_log.md
--
-- Reading the columns:
--   gap_all_questions   the difference in acceptance rate with and without the
--                       attribute, each question counted once (what 31 shows).
--   gap_ignoring_tag    the same difference on the (question, tag) pairs that
--                       enter the within-tag comparison, so that the next column
--                       is compared against a like-for-like base.
--   gap_within_tag      the volume-weighted average of the difference measured
--                       inside each tag.
--   share_surviving     gap_within_tag / gap_ignoring_tag. 1.0 means the topic
--                       explains none of it; 0 means it explains all of it.
--
-- Restricted to tags that clear the volume floor and have at least
-- `min_per_side` questions on each side of the comparison, so no tag
-- contributes a rate built on a handful of rows.

WITH params AS (
  SELECT
    p.min_per_side,
    r.min_questions
  FROM `so_analysis.params` AS p
  CROSS JOIN `so_analysis.ranking_params` AS r
),

question_attributes AS (
  SELECT
    c.question_id,
    c.tags,
    o.accepted_in_window,
    c.body_has_error_signature,
    c.code_block_count,
    c.image_count,
    c.link_count_excluding_images,
    c.body_mentions_attempt,
    c.body_mentions_expected_result,
    c.body_text_length,
    h.question_id IS NOT NULL AS asker_known,
    h.prior_questions,
    h.asker_account_age_days
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  LEFT JOIN `so_analysis.asker_history` AS h
    ON h.question_id = c.question_id
  WHERE c.cohort_region = 'current_year'
),

long AS (
  SELECT
    qa.question_id,
    qa.tags,
    qa.accepted_in_window,
    f.attribute,
    f.has_attribute
  FROM question_attributes AS qa
  CROSS JOIN UNNEST([
    STRUCT('body_contains_error_output' AS attribute, qa.body_has_error_signature AS has_attribute),
    STRUCT('body_has_at_least_one_code_block', qa.code_block_count > 0),
    STRUCT('body_has_four_or_more_code_blocks', qa.code_block_count >= 4),
    STRUCT('body_contains_image', qa.image_count > 0),
    STRUCT('body_contains_link_other_than_image', qa.link_count_excluding_images > 0),
    STRUCT('body_says_what_was_tried', qa.body_mentions_attempt),
    STRUCT('body_states_expected_result', qa.body_mentions_expected_result),
    STRUCT('body_text_under_300_chars', qa.body_text_length < 300),
    STRUCT('body_text_3000_chars_or_more', qa.body_text_length >= 3000),
    -- Asker attributes are undefined for deleted accounts; those rows drop out.
    STRUCT('asker_first_question_ever', IF(qa.asker_known, qa.prior_questions = 0, NULL)),
    STRUCT('asker_signed_up_same_day', IF(qa.asker_known, qa.asker_account_age_days < 1, NULL))
  ]) AS f
  WHERE f.has_attribute IS NOT NULL
),

question_level AS (
  SELECT
    l.attribute,
    SAFE_DIVIDE(COUNTIF(l.has_attribute AND l.accepted_in_window), COUNTIF(l.has_attribute))
      - SAFE_DIVIDE(COUNTIF(NOT l.has_attribute AND l.accepted_in_window), COUNTIF(NOT l.has_attribute)) AS gap
  FROM long AS l
  GROUP BY l.attribute
),

tagged AS (
  SELECT
    l.attribute,
    tag,
    l.has_attribute,
    l.accepted_in_window
  FROM long AS l
  CROSS JOIN UNNEST(SPLIT(l.tags, '|')) AS tag
  INNER JOIN `so_analysis.tag_funnel` AS t
    ON t.tag = tag
   AND t.cohort_region = 'current_year'
  CROSS JOIN params AS p
  WHERE tag != ''
    AND t.n_questions >= p.min_questions
),

per_tag AS (
  SELECT
    tg.attribute,
    tg.tag,
    COUNTIF(tg.has_attribute) AS n_with,
    COUNTIF(NOT tg.has_attribute) AS n_without,
    COUNTIF(tg.has_attribute AND tg.accepted_in_window) AS k_with,
    COUNTIF(NOT tg.has_attribute AND tg.accepted_in_window) AS k_without
  FROM tagged AS tg
  GROUP BY tg.attribute, tg.tag
  HAVING COUNTIF(tg.has_attribute) >= (SELECT p.min_per_side FROM params AS p)
     AND COUNTIF(NOT tg.has_attribute) >= (SELECT p.min_per_side FROM params AS p)
),

summary AS (
  SELECT
    pt.attribute,
    COUNT(*) AS tags_compared,
    SAFE_DIVIDE(SUM(pt.k_with), SUM(pt.n_with)) - SAFE_DIVIDE(SUM(pt.k_without), SUM(pt.n_without)) AS gap_ignoring_tag,
    SAFE_DIVIDE(
      SUM((SAFE_DIVIDE(pt.k_with, pt.n_with) - SAFE_DIVIDE(pt.k_without, pt.n_without)) * (pt.n_with + pt.n_without)),
      SUM(pt.n_with + pt.n_without)) AS gap_within_tag,
    COUNTIF(SAFE_DIVIDE(pt.k_with, pt.n_with) < SAFE_DIVIDE(pt.k_without, pt.n_without)) AS tags_where_attribute_is_worse,
    COUNTIF(SAFE_DIVIDE(pt.k_with, pt.n_with) > SAFE_DIVIDE(pt.k_without, pt.n_without)) AS tags_where_attribute_is_better
  FROM per_tag AS pt
  GROUP BY pt.attribute
)

SELECT
  s.attribute,
  s.tags_compared,
  ROUND(ql.gap, 4) AS gap_all_questions,
  ROUND(s.gap_ignoring_tag, 4) AS gap_ignoring_tag,
  ROUND(s.gap_within_tag, 4) AS gap_within_tag,
  ROUND(SAFE_DIVIDE(s.gap_within_tag, s.gap_ignoring_tag), 2) AS share_surviving_within_tag,
  s.tags_where_attribute_is_worse,
  s.tags_where_attribute_is_better
FROM summary AS s
INNER JOIN question_level AS ql
  ON ql.attribute = s.attribute
ORDER BY s.attribute
