-- Cohort 1/2: the question-level analysis base.
--
-- Purpose:  Materialize every question in the analysis window together with the
--           attributes that were knowable AT THE MOMENT IT WAS POSTED. This is
--           the only pass in the whole project that reads `body`, which holds
--           roughly three quarters of the source table's bytes. Everything
--           downstream reads this narrow table instead.
-- Source:   bigquery-public-data.stackoverflow.posts_questions
-- Output:   so_analysis.question_cohort — one row per question
-- Cost:     see results/run_log.md (this is the expensive one, by design, once)
--
-- Window:   the cohort ends `maturation_days` before the last question in the
--           data, so every question in it has had the same minimum observable
--           exposure. Without that, questions asked near the snapshot look worse
--           purely because nobody has had time to answer them yet.
--           Both boundaries are derived FROM THE DATA, not hardcoded, so this
--           script still does the right thing if the dataset is ever refreshed.
--
-- Note on feature classes: columns prefixed `posthoc_` accumulate AFTER the
-- question is posted. They are carried here for descriptive work only and must
-- never be treated as predictors of whether a question gets answered — see the
-- taxonomy in the README.

DECLARE snapshot_date DATE;
DECLARE maturation_days INT64 DEFAULT 30;  -- captures ~89% of eventual acceptances; see 00_profiling/03

SET snapshot_date = (
  SELECT DATE(MAX(q.creation_date))
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
);

CREATE OR REPLACE TABLE `so_analysis.question_cohort` AS
SELECT
  q.id AS question_id,
  q.owner_user_id,
  q.creation_date AS asked_at,
  DATE(q.creation_date) AS asked_on,
  q.accepted_answer_id,

  -- Tags, kept raw here and exploded downstream so the fan-out is explicit.
  q.tags,
  ARRAY_LENGTH(SPLIT(q.tags, '|')) AS n_tags,

  -- ---- Attributes knowable at post time (legitimate predictors) ----
  LENGTH(q.title) AS title_length,
  ARRAY_LENGTH(SPLIT(TRIM(q.title), ' ')) AS title_word_count,
  ENDS_WITH(TRIM(q.title), '?') AS title_is_a_question,
  REGEXP_CONTAINS(LOWER(q.title), r'\b(urgent|asap|help me|please help|pls help)\b') AS title_pleads_for_help,
  LENGTH(q.body) AS body_length,
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(q.body, r'<code>')) AS code_block_count,
  REGEXP_CONTAINS(q.body, r'<img ') AS body_has_image,
  REGEXP_CONTAINS(q.body, r'<a href') AS body_has_link,
  -- A pasted error message or stack trace is a proxy for a specific,
  -- reproducible problem rather than a vague one.
  REGEXP_CONTAINS(q.body, r'(?i)(exception|traceback|stack ?trace|error:|errno|segmentation fault)')
    AS body_has_error_signature,
  q.community_owned_date IS NOT NULL AS is_community_owned,

  -- ---- Outcome inputs (as recorded on the question itself) ----
  q.answer_count,
  q.accepted_answer_id IS NOT NULL AS was_ever_accepted,
  q.answer_count > 0 AS was_ever_answered,

  -- ---- Post-hoc attributes: descriptive only, never predictors ----
  q.score AS posthoc_score,
  q.view_count AS posthoc_view_count,
  q.comment_count AS posthoc_comment_count,
  q.favorite_count AS posthoc_favorite_count,
  q.last_edit_date IS NOT NULL AS posthoc_was_edited,
  -- NOT an "anonymous asker" flag, which is what this looks like at first glance.
  -- Stack Overflow drops owner_user_id but KEEPS owner_display_name when an
  -- account is deleted, and every such row here has a display name. So a null
  -- user id records an account deletion that happened somewhere between the
  -- question and the dump — an event in the future relative to the post. It sits
  -- in the post-hoc block for that reason. I originally had it as a post-time
  -- attribute and it produced a 44% acceptance rate against a 30% baseline,
  -- which is what sent me looking.
  q.owner_user_id IS NULL AS posthoc_asker_account_deleted,

  snapshot_date AS snapshot_date,
  maturation_days AS maturation_days
FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
WHERE q.creation_date >= '2021-01-01'                                   -- covers the 2022 cohort plus a full 2021 for robustness
  AND DATE(q.creation_date) <= DATE_SUB(snapshot_date, INTERVAL maturation_days DAY)
