-- Prompt 2: which qualities of a post go with getting answered, and accepted?
--
-- Purpose:  Measure how each attribute of a question relates to the two outcomes
--           the prompt asks about, and — more importantly — sort the attributes
--           into the ones that could actually inform advice and the ones that
--           cannot.
-- Source:   so_analysis.question_cohort, question_outcomes, asker_history
-- Grain:    one row per (feature_class, feature, bucket)
-- Cost:     see results/run_log.md
--
-- THE TAXONOMY IS THE ANSWER, and it comes before any number:
--
--   known_at_post_time - true the instant the question is submitted. These are
--       the only attributes that can support a claim like "write it this way and
--       you are more likely to get an answer", because they are the only ones a
--       person can act on.
--
--   post_hoc - accumulates AFTER the question is posted: score, views, comments.
--       These correlate with the outcome beautifully and explain nothing. A
--       question does not get answered because it has views; it has views partly
--       because it got answered. They are reported here on purpose, clearly
--       labelled, because they are the obvious answer to this prompt and the
--       reason they are the wrong answer is the substance of it.
--
-- One attribute moved classes while I was writing this. A null `owner_user_id`
-- looks like an anonymous asker, and as a post-time attribute it showed a 44%
-- acceptance rate against a 30% baseline — implausible enough to check. Stack
-- Overflow keeps `owner_display_name` and drops the id when an ACCOUNT IS
-- DELETED, and all 10,193 such rows in this cohort have a display name. It
-- records a future event, so it is a post-hoc attribute, and it is listed as one.
--
-- Deliberately excluded: `users.reputation`. It is a late-2022 snapshot, not the
-- asker's reputation on the day they posted — see 03_post_qualities/30.
--
-- Why buckets rather than a correlation coefficient: several of these
-- relationships are expected to be non-monotonic. A title can be too short or
-- too long; a body can be a one-liner or a wall of text. A single coefficient
-- would report "no relationship" for a strong inverted-U, which is exactly the
-- shape most likely to be interesting here.

WITH params AS (
  SELECT DATE '2022-01-01' AS cohort_start
),

base AS (
  SELECT
    c.title_length,
    c.title_is_a_question,
    c.title_pleads_for_help,
    c.body_length,
    c.code_block_count,
    c.body_has_image,
    c.body_has_link,
    c.body_has_error_signature,
    c.n_tags,
    c.posthoc_asker_account_deleted,
    c.posthoc_score,
    c.posthoc_view_count,
    c.posthoc_comment_count,
    h.asker_account_age_days,
    h.prior_questions,
    h.prior_acceptance_rate,
    o.answered_in_window,
    o.accepted_in_window
  FROM `so_analysis.question_cohort` AS c
  INNER JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  LEFT JOIN `so_analysis.asker_history` AS h
    ON h.question_id = c.question_id
  WHERE c.asked_on >= (SELECT cohort_start FROM params)
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

    STRUCT('known_at_post_time', 'title_ends_with_question_mark',
      IF(b.title_is_a_question, 'yes', 'no'), 2),

    STRUCT('known_at_post_time', 'title_uses_urgency_words',
      IF(b.title_pleads_for_help, 'yes', 'no'), 3),

    STRUCT('known_at_post_time', 'body_length_chars',
      CASE
        WHEN b.body_length < 300 THEN 'a. under 300'
        WHEN b.body_length < 700 THEN 'b. 300-699'
        WHEN b.body_length < 1500 THEN 'c. 700-1499'
        WHEN b.body_length < 3000 THEN 'd. 1500-2999'
        ELSE 'e. 3000 or more'
      END, 4),

    STRUCT('known_at_post_time', 'code_blocks_in_body',
      CASE
        WHEN b.code_block_count = 0 THEN 'a. none'
        WHEN b.code_block_count = 1 THEN 'b. one'
        WHEN b.code_block_count <= 3 THEN 'c. 2-3'
        WHEN b.code_block_count <= 8 THEN 'd. 4-8'
        ELSE 'e. 9 or more'
      END, 5),

    STRUCT('known_at_post_time', 'body_contains_error_or_stack_trace',
      IF(b.body_has_error_signature, 'yes', 'no'), 6),

    STRUCT('known_at_post_time', 'body_contains_image',
      IF(b.body_has_image, 'yes', 'no'), 7),

    STRUCT('known_at_post_time', 'body_contains_link',
      IF(b.body_has_link, 'yes', 'no'), 8),

    STRUCT('known_at_post_time', 'number_of_tags',
      CAST(b.n_tags AS STRING), 9),

    STRUCT('known_at_post_time', 'asker_account_age_at_post',
      CASE
        -- Null age here means the account no longer exists, so there is no
        -- signup date to measure from. Those rows belong to the post-hoc
        -- account-deletion feature below, not to a phantom "unknown age" bucket.
        WHEN b.asker_account_age_days IS NULL THEN NULL
        WHEN b.asker_account_age_days < 1 THEN 'a. same day as signup'
        WHEN b.asker_account_age_days < 30 THEN 'b. under a month'
        WHEN b.asker_account_age_days < 365 THEN 'c. under a year'
        WHEN b.asker_account_age_days < 1095 THEN 'd. 1-3 years'
        ELSE 'e. over 3 years'
      END, 11),

    STRUCT('known_at_post_time', 'asker_prior_questions',
      CASE
        WHEN b.prior_questions IS NULL OR b.prior_questions = 0 THEN 'a. none'
        WHEN b.prior_questions <= 4 THEN 'b. 1-4'
        WHEN b.prior_questions <= 19 THEN 'c. 5-19'
        WHEN b.prior_questions <= 99 THEN 'd. 20-99'
        ELSE 'e. 100 or more'
      END, 12),

    STRUCT('known_at_post_time', 'asker_prior_acceptance_rate',
      CASE
        WHEN b.prior_acceptance_rate IS NULL THEN 'f. no prior history'
        WHEN b.prior_acceptance_rate = 0 THEN 'a. never accepted before'
        WHEN b.prior_acceptance_rate < 0.34 THEN 'b. under a third'
        WHEN b.prior_acceptance_rate < 0.67 THEN 'c. a third to two thirds'
        WHEN b.prior_acceptance_rate < 1 THEN 'd. most of the time'
        ELSE 'e. always'
      END, 13),

    -- Below this line: contaminated by the outcome. Shown for contrast only.
    STRUCT('post_hoc', 'asker_account_later_deleted',
      IF(b.posthoc_asker_account_deleted, 'yes', 'no'), 19),

    STRUCT('post_hoc', 'question_score',
      CASE
        WHEN b.posthoc_score < 0 THEN 'a. negative'
        WHEN b.posthoc_score = 0 THEN 'b. zero'
        WHEN b.posthoc_score <= 2 THEN 'c. 1-2'
        ELSE 'd. 3 or more'
      END, 20),

    STRUCT('post_hoc', 'question_view_count',
      CASE
        WHEN b.posthoc_view_count < 50 THEN 'a. under 50'
        WHEN b.posthoc_view_count < 200 THEN 'b. 50-199'
        WHEN b.posthoc_view_count < 1000 THEN 'c. 200-999'
        ELSE 'd. 1000 or more'
      END, 21),

    STRUCT('post_hoc', 'question_comment_count',
      CASE
        WHEN b.posthoc_comment_count = 0 THEN 'a. none'
        WHEN b.posthoc_comment_count <= 2 THEN 'b. 1-2'
        WHEN b.posthoc_comment_count <= 5 THEN 'c. 3-5'
        ELSE 'd. 6 or more'
      END, 22)
  ]) AS f
)

SELECT
  l.feature_class,
  l.feature,
  l.bucket,
  COUNT(*) AS n_questions,
  ROUND(SAFE_DIVIDE(COUNT(*), SUM(COUNT(*)) OVER (PARTITION BY l.feature)), 4) AS share_of_cohort,
  ROUND(SAFE_DIVIDE(COUNTIF(l.answered_in_window), COUNT(*)), 4) AS answer_rate,
  ROUND(SAFE_DIVIDE(COUNTIF(l.accepted_in_window), COUNT(*)), 4) AS acceptance_rate,
  -- Lift: how many times the cohort baseline. 1.0 means the attribute tells you
  -- nothing. Reported alongside share_of_cohort on purpose: a large lift on 0.5%
  -- of questions is a curiosity, not a lever.
  ROUND(SAFE_DIVIDE(SAFE_DIVIDE(COUNTIF(l.answered_in_window), COUNT(*)),
                    (SELECT baseline_answer_rate FROM overall)), 3) AS answer_lift,
  ROUND(SAFE_DIVIDE(SAFE_DIVIDE(COUNTIF(l.accepted_in_window), COUNT(*)),
                    (SELECT baseline_acceptance_rate FROM overall)), 3) AS acceptance_lift
FROM long AS l
WHERE l.bucket IS NOT NULL
GROUP BY l.feature_class, l.feature, l.bucket, l.bucket_order
ORDER BY l.bucket_order, l.bucket
