-- Cohort 2/7: the question-level analysis base.
--
-- Purpose:  Materialize every question in the analysis window together with the
--           attributes that were knowable AT THE MOMENT IT WAS POSTED. This is
--           the only pass in the whole project that reads `body`, which holds
--           roughly three quarters of the source table's bytes. Everything
--           downstream reads this narrow table instead.
-- Source:   bigquery-public-data.stackoverflow.posts_questions, so_analysis.params
-- Output:   so_analysis.question_cohort — one row per question
-- Cost:     see results/run_log.md (this is the expensive one, by design, once)
--
-- Window:   from comparison_start (1 January of the previous year) to cohort_end
--           (the snapshot minus the maturation window). Both come from
--           so_analysis.params, so nothing here is hardcoded. Each question is
--           labelled with the region it falls in:
--             current_year        — the analysis cohort
--             prior_year_unpurged — the previous year, less than 365 days old at
--                                   the snapshot: not yet touched by the site's
--                                   automatic deletion of old unanswered questions
--             prior_year_purged   — the previous year, already a survivor population
--
-- Text features, and what each one actually measures:
--   code_block_count      <pre><code> blocks — real code, not the inline <code>
--                         spans a sentence uses for an identifier
--   inline_code_count     the spans, kept separately
--   body_text_length      length with HTML tags stripped, so a post full of
--                         markup or image links is not counted as "long"
--   link_count_excluding_images
--                         Stack Overflow wraps uploaded images in a link, so a raw
--                         link count would mostly re-count images
--   body_has_error_signature
--                         anchored on what runtime output looks like (a Python
--                         traceback, a JVM "at ...(File.java:12)" frame,
--                         "SomethingError: ...", a compiler "error C1234:"),
--                         NOT on the word "exception", which any try/catch block
--                         contains. error_signature_context keeps the matched
--                         text so the pattern's precision can be checked by eye.
--   body_mentions_attempt / body_mentions_expected_result
--                         the two things the site's own asking guidelines request
--
-- Columns prefixed `posthoc_` accumulate AFTER the question is posted. They are
-- carried for descriptive work only and must never be treated as predictors —
-- see the taxonomy in 03_post_qualities/31 and the README.

CREATE OR REPLACE TABLE `so_analysis.question_cohort` AS

WITH patterns AS (
  SELECT
    r'Traceback \(most recent call last\)|Exception in thread |\bat [\w$.]+\([\w]+\.(?:java|kt|scala):\d+\)|\b[A-Z][A-Za-z]*(?:Error|Exception): |Uncaught [A-Z]\w*(?:Error|Exception)|(?i:unhandled (?:exception|promise rejection))|(?i:\berror(?:\[E\d+\]| TS\d+| CS?\d+| LNK\d+)?: )|(?i:\berrno\b)|(?i:segmentation fault)|(?i:core dumped)|(?i:stack ?trace)|(?i:\bpanic: )|(?i:\bfatal(?: error)?: )'
      AS error_signature,
    r'(?i:\b(?:i(?: have|\'ve)? tried|i attempted|my attempt|what i tried|things i(?:\'ve| have)? tried)\b)'
      AS attempt,
    r'(?i:\b(?:expected (?:output|result|behaviou?r)|i expect(?:ed)?|should (?:return|print|output|be|look like|give))\b)'
      AS expected_result
)

SELECT
  q.id AS question_id,
  q.owner_user_id,
  q.creation_date AS asked_at,
  DATE(q.creation_date) AS asked_on,
  CASE
    WHEN DATE(q.creation_date) >= p.cohort_start THEN 'current_year'
    WHEN DATE(q.creation_date) > p.purge_boundary THEN 'prior_year_unpurged'
    ELSE 'prior_year_purged'
  END AS cohort_region,
  q.accepted_answer_id,

  -- Tags, kept raw here and exploded downstream so the fan-out is explicit.
  q.tags,
  ARRAY_LENGTH(ARRAY(SELECT t FROM UNNEST(SPLIT(q.tags, '|')) AS t WHERE t != '')) AS n_tags,
  SPLIT(q.tags, '|')[SAFE_OFFSET(0)] AS first_tag,

  -- ---- Attributes knowable at post time (legitimate predictors) ----
  LENGTH(q.title) AS title_length,
  ENDS_WITH(TRIM(q.title), '?') AS title_is_a_question,
  REGEXP_CONTAINS(LOWER(q.title), r'\b(urgent|asap|help me|please help|pls help)\b') AS title_pleads_for_help,
  CASE
    WHEN REGEXP_CONTAINS(LOWER(q.title), r'^how ') THEN 'how'
    WHEN REGEXP_CONTAINS(LOWER(q.title), r'^why ') THEN 'why'
    WHEN REGEXP_CONTAINS(LOWER(q.title), r'^(what|which|where|when|who) ') THEN 'what / which / where'
    WHEN REGEXP_CONTAINS(LOWER(q.title), r'^(is|are|can|could|does|do|should|will|would) ') THEN 'yes-or-no question'
    WHEN REGEXP_CONTAINS(LOWER(q.title), r'(error|exception|not working|doesn.t work|does not work|fail|cannot|can.t|unable|issue|problem)') THEN 'problem report'
    ELSE 'other'
  END AS title_form,

  LENGTH(q.body) AS body_html_length,
  LENGTH(REGEXP_REPLACE(q.body, r'<[^>]+>', '')) AS body_text_length,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<pre[^>]*>\s*<code')) AS code_block_count,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<code'))
    - ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<pre[^>]*>\s*<code')) AS inline_code_count,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<img ')) AS image_count,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<a href'))
    - ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<a href[^>]*>\s*<img')) AS link_count_excluding_images,
  REGEXP_CONTAINS(q.body, pt.error_signature) AS body_has_error_signature,
  REGEXP_EXTRACT(q.body, CONCAT(r'((?s:.{0,60})(?:', pt.error_signature, r')(?s:.{0,60}))')) AS error_signature_context,
  REGEXP_CONTAINS(q.body, pt.attempt) AS body_mentions_attempt,
  REGEXP_CONTAINS(q.body, pt.expected_result) AS body_mentions_expected_result,
  q.community_owned_date IS NOT NULL AS is_community_owned,

  -- ---- Outcome inputs (as recorded on the question itself) ----
  q.answer_count,
  q.accepted_answer_id IS NOT NULL AS was_ever_accepted,

  -- ---- Post-hoc attributes: descriptive only, never predictors ----
  q.score AS posthoc_score,
  q.view_count AS posthoc_view_count,
  q.comment_count AS posthoc_comment_count,
  -- NOT an "anonymous asker" flag, which is what this looks like at first glance.
  -- Stack Overflow drops owner_user_id but KEEPS owner_display_name when an
  -- account is deleted; has_display_name lets 04_validation/40 assert that every
  -- such row still carries a name. A null user id therefore records an account
  -- deletion that happened somewhere between the question and the dump — an
  -- event in the future relative to the post — which is why it sits here.
  q.owner_user_id IS NULL AS posthoc_asker_account_deleted,
  q.owner_display_name IS NOT NULL AS has_display_name
FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
CROSS JOIN `so_analysis.params` AS p
CROSS JOIN patterns AS pt
WHERE DATE(q.creation_date) >= p.comparison_start
  AND DATE(q.creation_date) <= p.cohort_end
