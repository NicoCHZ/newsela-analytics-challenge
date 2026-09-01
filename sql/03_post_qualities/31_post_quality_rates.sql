-- Prompt 2: which qualities of a post go with getting answered, and accepted?
--
-- Purpose:  Measure how each attribute of a question relates to the two outcomes
--           the prompt asks about, and, more importantly, sort the attributes
--           into the ones that could actually inform advice and the ones that
--           cannot.
-- Source:   so_analysis.question_cohort, question_outcomes, asker_history,
--           tag_funnel (for how niche a question's tags are)
-- Grain:    one row per (feature_class, feature, bucket)
-- Cost:     see results/run_log.md
--
-- THE TAXONOMY IS THE ANSWER, and it comes before any number:
--
--   known_at_post_time - true the instant the question is submitted. These are
--       the only attributes that can support a claim like "write it this way and
--       you are more likely to get an answer", because they are the only ones a
--       person can act on. Asker history is included here because it is fully
--       knowable at that moment (03_post_qualities/30 makes sure of the dates),
--       but note that the prompt says "qualities on a post": the asker's record
--       is a quality of the poster, and the README labels it that way.
--
--   post_hoc - accumulates AFTER the question is posted: score, views, comments,
--       whether the account was later deleted. These correlate with the outcome
--       and explain nothing. A question does not get answered because it has
--       views; it has views partly because it got answered. They are reported
--       here on purpose, clearly labelled, because they are the obvious answer
--       to this prompt and the reason they are the wrong answer is the
--       substance of it.
--
-- A null `owner_user_id` looks like an anonymous asker; it is a deleted account
-- (the README explains why), which is a future event. Those rows are excluded
-- from EVERY asker-history bucket, consistently, rather than landing in "no
-- prior history"; 9,883 rows with a 43% acceptance rate would otherwise
-- contaminate that bucket.
--
-- Why buckets rather than a correlation coefficient: several of these
-- relationships are expected to be non-monotonic. A body can be a one-liner or
-- a wall of text. A single coefficient would report "no relationship" for a
-- strong inverted-U, which is exactly the shape most likely to be interesting.
--
-- `acceptance_given_answered` is reported next to the two rates because the
-- two can move in opposite directions (the negative-score bucket is the case
-- in point), and the funnel is what tells the two stories apart.

WITH narrowest_tag AS (
  -- How niche is the most specific tag on the question? A question carrying
  -- only mega-tags (python, javascript) competes for attention with thousands
  -- of others that day; one carrying a niche tag reaches the few people who
  -- follow it.
  SELECT
    c.question_id,
    MIN(t.n_questions) AS narrowest_tag_questions
  FROM `so_analysis.question_cohort` AS c
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  INNER JOIN `so_analysis.tag_funnel` AS t
    ON t.tag = tag
   AND t.cohort_region = 'current_year'
  WHERE c.cohort_region = 'current_year'
  GROUP BY c.question_id
),

base AS (
  SELECT
    c.asked_at,
    c.title_length,
    c.title_form,
    c.title_is_a_question,
    c.title_pleads_for_help,
    c.body_text_length,
    c.code_block_count,
    c.inline_code_count,
    c.body_has_error_signature,
    c.body_mentions_attempt,
    c.body_mentions_expected_result,
    c.image_count,
    c.link_count_excluding_images,
    c.n_tags,
    nt.narrowest_tag_questions,
    c.posthoc_asker_account_deleted,
    c.posthoc_score,
    c.posthoc_view_count,
    c.posthoc_comment_count,
    h.question_id IS NOT NULL AS asker_known,
    h.asker_account_age_days,
    h.prior_questions,
    h.prior_questions_settled,
    h.prior_acceptance_rate,
    h.prior_answer_rate,
    h.prior_answers_written,
    o.answered_in_window,
    o.accepted_in_window
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  LEFT JOIN `so_analysis.asker_history` AS h
    ON h.question_id = c.question_id
  LEFT JOIN narrowest_tag AS nt
    ON nt.question_id = c.question_id
  WHERE c.cohort_region = 'current_year'
),

overall AS (
  SELECT
    SAFE_DIVIDE(COUNTIF(b.answered_in_window), COUNT(*)) AS baseline_answer_rate,
    SAFE_DIVIDE(COUNTIF(b.accepted_in_window), COUNT(*)) AS baseline_acceptance_rate
  FROM base AS b
),

-- Reshape wide to long so every feature is measured identically.
long AS (
  SELECT
    f.feature_class,
    f.feature,
    f.bucket,
    f.bucket_order,
    b.answered_in_window,
    b.accepted_in_window
  FROM base AS b
  CROSS JOIN UNNEST([
    STRUCT('known_at_post_time' AS feature_class, 'title_length_chars' AS feature,
      CASE
        WHEN b.title_length < 35 THEN 'a. under 35'
        WHEN b.title_length < 50 THEN 'b. 35-49'
        WHEN b.title_length < 65 THEN 'c. 50-64'
        WHEN b.title_length < 85 THEN 'd. 65-84'
        ELSE 'e. 85 or more'
      END AS bucket, 1 AS bucket_order),

    STRUCT('known_at_post_time', 'title_form', b.title_form, 2),

    STRUCT('known_at_post_time', 'title_ends_with_question_mark',
      IF(b.title_is_a_question, 'yes', 'no'), 3),

    STRUCT('known_at_post_time', 'title_uses_urgency_words',
      IF(b.title_pleads_for_help, 'yes', 'no'), 4),

    STRUCT('known_at_post_time', 'body_text_length_chars',
      CASE
        WHEN b.body_text_length < 300 THEN 'a. under 300'
        WHEN b.body_text_length < 700 THEN 'b. 300-699'
        WHEN b.body_text_length < 1500 THEN 'c. 700-1499'
        WHEN b.body_text_length < 3000 THEN 'd. 1500-2999'
        ELSE 'e. 3000 or more'
      END, 5),

    STRUCT('known_at_post_time', 'code_blocks_in_body',
      CASE
        WHEN b.code_block_count = 0 THEN 'a. none'
        WHEN b.code_block_count = 1 THEN 'b. one'
        WHEN b.code_block_count <= 3 THEN 'c. 2-3'
        WHEN b.code_block_count <= 8 THEN 'd. 4-8'
        ELSE 'e. 9 or more'
      END, 6),

    STRUCT('known_at_post_time', 'inline_code_spans_in_body',
      CASE
        WHEN b.inline_code_count = 0 THEN 'a. none'
        WHEN b.inline_code_count <= 2 THEN 'b. 1-2'
        WHEN b.inline_code_count <= 9 THEN 'c. 3-9'
        ELSE 'd. 10 or more'
      END, 7),

    STRUCT('known_at_post_time', 'body_contains_error_output',
      IF(b.body_has_error_signature, 'yes', 'no'), 8),

    STRUCT('known_at_post_time', 'body_says_what_was_tried',
      IF(b.body_mentions_attempt, 'yes', 'no'), 9),

    STRUCT('known_at_post_time', 'body_states_expected_result',
      IF(b.body_mentions_expected_result, 'yes', 'no'), 10),

    STRUCT('known_at_post_time', 'body_contains_image',
      IF(b.image_count > 0, 'yes', 'no'), 11),

    STRUCT('known_at_post_time', 'body_contains_link_other_than_image',
      IF(b.link_count_excluding_images > 0, 'yes', 'no'), 12),

    STRUCT('known_at_post_time', 'number_of_tags',
      CAST(b.n_tags AS STRING), 13),

    STRUCT('known_at_post_time', 'narrowest_tag_on_the_question',
      CASE
        WHEN b.narrowest_tag_questions < 1000 THEN 'a. under 1,000 questions this year'
        WHEN b.narrowest_tag_questions < 10000 THEN 'b. 1,000-9,999'
        WHEN b.narrowest_tag_questions < 100000 THEN 'c. 10,000-99,999'
        ELSE 'd. 100,000 or more (only mega-tags)'
      END, 14),

    STRUCT('known_at_post_time', 'posting_hour_utc',
      CASE
        WHEN EXTRACT(HOUR FROM b.asked_at) < 4 THEN 'a. 00-03'
        WHEN EXTRACT(HOUR FROM b.asked_at) < 8 THEN 'b. 04-07'
        WHEN EXTRACT(HOUR FROM b.asked_at) < 12 THEN 'c. 08-11'
        WHEN EXTRACT(HOUR FROM b.asked_at) < 16 THEN 'd. 12-15'
        WHEN EXTRACT(HOUR FROM b.asked_at) < 20 THEN 'e. 16-19'
        ELSE 'f. 20-23'
      END, 15),

    STRUCT('known_at_post_time', 'posting_day_utc',
      CASE EXTRACT(DAYOFWEEK FROM b.asked_at)
        WHEN 2 THEN 'a. Monday'
        WHEN 3 THEN 'b. Tuesday'
        WHEN 4 THEN 'c. Wednesday'
        WHEN 5 THEN 'd. Thursday'
        WHEN 6 THEN 'e. Friday'
        WHEN 7 THEN 'f. Saturday'
        ELSE 'g. Sunday'
      END, 16),

    -- Asker history: NULL (excluded) whenever the account no longer exists.
    STRUCT('known_at_post_time', 'asker_account_age_at_post',
      CASE
        WHEN NOT b.asker_known OR b.asker_account_age_days IS NULL THEN NULL
        WHEN b.asker_account_age_days < 1 THEN 'a. same day as signup'
        WHEN b.asker_account_age_days < 30 THEN 'b. under a month'
        WHEN b.asker_account_age_days < 365 THEN 'c. under a year'
        WHEN b.asker_account_age_days < 1095 THEN 'd. 1-3 years'
        ELSE 'e. over 3 years'
      END, 17),

    STRUCT('known_at_post_time', 'asker_prior_questions',
      CASE
        WHEN NOT b.asker_known THEN NULL
        WHEN b.prior_questions = 0 THEN 'a. none'
        WHEN b.prior_questions <= 4 THEN 'b. 1-4'
        WHEN b.prior_questions <= 19 THEN 'c. 5-19'
        WHEN b.prior_questions <= 99 THEN 'd. 20-99'
        ELSE 'e. 100 or more'
      END, 18),

    STRUCT('known_at_post_time', 'asker_prior_answers_written',
      CASE
        WHEN NOT b.asker_known THEN NULL
        WHEN b.prior_answers_written = 0 THEN 'a. none'
        WHEN b.prior_answers_written <= 4 THEN 'b. 1-4'
        WHEN b.prior_answers_written <= 19 THEN 'c. 5-19'
        WHEN b.prior_answers_written <= 99 THEN 'd. 20-99'
        ELSE 'e. 100 or more'
      END, 19),

    -- Rates need a denominator worth trusting: at least three settled prior
    -- questions. "Always accepted" on a single prior question is not a habit.
    STRUCT('known_at_post_time', 'asker_prior_acceptance_rate',
      CASE
        WHEN NOT b.asker_known THEN NULL
        WHEN b.prior_questions_settled < 3 THEN 'f. fewer than 3 settled prior questions'
        WHEN b.prior_acceptance_rate = 0 THEN 'a. never accepted before'
        WHEN b.prior_acceptance_rate < 0.34 THEN 'b. under a third'
        WHEN b.prior_acceptance_rate < 0.67 THEN 'c. a third to two thirds'
        WHEN b.prior_acceptance_rate < 1 THEN 'd. most of the time'
        ELSE 'e. always'
      END, 20),

    STRUCT('known_at_post_time', 'asker_prior_answer_rate',
      CASE
        WHEN NOT b.asker_known THEN NULL
        WHEN b.prior_questions_settled < 3 THEN 'f. fewer than 3 settled prior questions'
        WHEN b.prior_answer_rate = 0 THEN 'a. never answered before'
        WHEN b.prior_answer_rate < 0.34 THEN 'b. under a third'
        WHEN b.prior_answer_rate < 0.67 THEN 'c. a third to two thirds'
        WHEN b.prior_answer_rate < 1 THEN 'd. most of the time'
        ELSE 'e. always'
      END, 21),

    -- Below this line: contaminated by the outcome. Shown for contrast only.
    STRUCT('post_hoc', 'asker_account_later_deleted',
      IF(b.posthoc_asker_account_deleted, 'yes', 'no'), 30),

    STRUCT('post_hoc', 'question_score',
      CASE
        WHEN b.posthoc_score < 0 THEN 'a. negative'
        WHEN b.posthoc_score = 0 THEN 'b. zero'
        WHEN b.posthoc_score <= 2 THEN 'c. 1-2'
        ELSE 'd. 3 or more'
      END, 31),

    STRUCT('post_hoc', 'question_view_count',
      CASE
        WHEN b.posthoc_view_count < 50 THEN 'a. under 50'
        WHEN b.posthoc_view_count < 200 THEN 'b. 50-199'
        WHEN b.posthoc_view_count < 1000 THEN 'c. 200-999'
        ELSE 'd. 1000 or more'
      END, 32),

    STRUCT('post_hoc', 'question_comment_count',
      CASE
        WHEN b.posthoc_comment_count = 0 THEN 'a. none'
        WHEN b.posthoc_comment_count <= 2 THEN 'b. 1-2'
        WHEN b.posthoc_comment_count <= 5 THEN 'c. 3-5'
        ELSE 'd. 6 or more'
      END, 33)
  ]) AS f
)

SELECT
  l.feature_class,
  l.feature,
  l.bucket,
  COUNT(*) AS n_questions,
  -- Share of the questions for which the attribute is defined (asker features
  -- exclude deleted accounts, so their shares are over the remaining 99%).
  ROUND(SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER (PARTITION BY l.feature)), 4) AS share_of_cohort,
  ROUND(SAFE_DIVIDE(COUNTIF(l.answered_in_window), COUNT(*)), 4) AS answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(l.accepted_in_window), COUNT(*)), 4) AS acceptance_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(l.accepted_in_window), COUNTIF(l.answered_in_window)), 4) AS acceptance_given_answered,
  -- Lift: how many times the cohort baseline. 1.0 means the attribute tells you
  -- nothing. Reported alongside share_of_cohort on purpose: a large lift on 0.5%
  -- of questions is a curiosity, not a lever.
  ROUND(SAFE_DIVIDE(SAFE_DIVIDE(COUNTIF(l.answered_in_window), COUNT(*)),
                    (SELECT ov.baseline_answer_rate FROM overall AS ov)), 3) AS answer_lift,
  ROUND(SAFE_DIVIDE(SAFE_DIVIDE(COUNTIF(l.accepted_in_window), COUNT(*)),
                    (SELECT ov.baseline_acceptance_rate FROM overall AS ov)), 3) AS acceptance_lift
FROM long AS l
WHERE l.bucket IS NOT NULL
GROUP BY l.feature_class, l.feature, l.bucket, l.bucket_order
ORDER BY l.bucket_order, l.bucket
