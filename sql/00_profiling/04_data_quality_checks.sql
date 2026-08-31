-- Data quality assertions.
--
-- Purpose:  One row per check, with what I expected, what I found, and whether
--           it changed the analysis. Checks that pass are worth little on their
--           own; the two that fail here are what shaped the rest of the project.
-- Source:   cohort tables plus posts_answers for referential integrity
-- Grain:    one row per check
-- Cost:     see results/run_log.md
--
-- `severity` is set by hand per check rather than derived from the count,
-- because "expected to be non-zero" is a judgement, not a threshold. A check
-- that flags 9,883 deleted accounts is informational; one that flags a single
-- answer predating its own question is not.

WITH cohort_checks AS (
  SELECT
    COUNT(*) - COUNT(DISTINCT c.question_id) AS duplicate_question_ids,
    COUNTIF(c.tags IS NULL OR c.tags = '') AS questions_without_tags,
    COUNTIF(c.n_tags > 5) AS more_than_five_tags,
    COUNTIF(c.answer_count < 0) AS negative_answer_count,
    COUNTIF(c.was_ever_accepted AND c.answer_count = 0) AS accepted_but_no_answers,
    COUNTIF(c.is_community_owned) AS community_owned_posts,
    COUNTIF(c.posthoc_asker_account_deleted) AS asker_account_deleted,
    COUNTIF(c.asked_on > c.snapshot_date) AS asked_after_snapshot,
    COUNTIF(c.title_length = 0 OR c.body_length = 0) AS empty_title_or_body
  FROM `so_analysis.question_cohort` AS c
),

-- Referential integrity of the field the whole analysis rests on.
accepted_answer_checks AS (
  SELECT
    COUNTIF(a.id IS NULL) AS accepted_answer_missing_from_answers,
    COUNTIF(a.id IS NOT NULL AND a.parent_id != c.question_id) AS accepted_answer_belongs_to_another_question,
    COUNTIF(a.id IS NOT NULL AND DATE(a.creation_date) < c.asked_on) AS accepted_answer_predates_question
  FROM `so_analysis.question_cohort` AS c
  LEFT JOIN `bigquery-public-data.stackoverflow.posts_answers` AS a
    ON a.id = c.accepted_answer_id
  WHERE c.accepted_answer_id IS NOT NULL
),

-- Does the denormalized counter on the question agree with the answers present?
answer_count_checks AS (
  SELECT
    COUNTIF(c.answer_count != COALESCE(o.n_answers, 0)) AS answer_count_disagrees_with_join,
    COUNTIF(c.answer_count > COALESCE(o.n_answers, 0)) AS counter_higher_than_rows_present
  FROM `so_analysis.question_cohort` AS c
  LEFT JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
),

-- The freshness assertion. This is the one that is SUPPOSED to fail: it is the
-- check that answers "what is the current year?" with evidence rather than an
-- assumption, and in a production pipeline it is what would have paged somebody
-- in December 2022.
freshness_check AS (
  SELECT
    DATE_DIFF(CURRENT_DATE(), MAX(DATE(q.creation_date)), DAY) AS days_since_newest_question
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
),

all_checks AS (
  SELECT 'freshness: days since the newest question in the source' AS check_name,
         (SELECT days_since_newest_question FROM freshness_check) AS observed,
         'blocking' AS severity,
         'expected under 7 in a live pipeline' AS expectation
  UNION ALL SELECT 'accepted answer id not present in posts_answers',
         (SELECT accepted_answer_missing_from_answers FROM accepted_answer_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'accepted answer belongs to a different question',
         (SELECT accepted_answer_belongs_to_another_question FROM accepted_answer_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'accepted answer created before its own question',
         (SELECT accepted_answer_predates_question FROM accepted_answer_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'duplicate question ids',
         (SELECT duplicate_question_ids FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'questions with no tags',
         (SELECT questions_without_tags FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'questions with more than five tags',
         (SELECT more_than_five_tags FROM cohort_checks), 'blocking', 'expected 0 - that is the site limit'
  UNION ALL SELECT 'negative answer_count',
         (SELECT negative_answer_count FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'marked accepted but answer_count is zero',
         (SELECT accepted_but_no_answers FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'empty title or body',
         (SELECT empty_title_or_body FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'questions asked after the snapshot date',
         (SELECT asked_after_snapshot FROM cohort_checks), 'blocking', 'expected 0'
  UNION ALL SELECT 'answer_count disagrees with the answers actually present',
         (SELECT answer_count_disagrees_with_join FROM answer_count_checks), 'informational',
         'some disagreement expected: deleted answers stay counted'
  UNION ALL SELECT 'answer_count higher than the answer rows present',
         (SELECT counter_higher_than_rows_present FROM answer_count_checks), 'informational',
         'the direction deleted answers would produce'
  UNION ALL SELECT 'community wiki posts in the cohort',
         (SELECT community_owned_posts FROM cohort_checks), 'informational', 'no single owner - acceptance means something different'
  UNION ALL SELECT 'asker account deleted after posting',
         (SELECT asker_account_deleted FROM cohort_checks), 'informational', 'expected non-zero; a post-hoc attribute'
)

SELECT
  c.check_name,
  c.observed,
  c.severity,
  c.expectation,
  CASE
    WHEN c.severity = 'informational' THEN 'NOTED'
    WHEN c.check_name LIKE 'freshness%' AND c.observed > 7 THEN 'FAIL'
    WHEN c.severity = 'blocking' AND c.observed > 0 THEN 'FAIL'
    ELSE 'PASS'
  END AS status
FROM all_checks AS c
ORDER BY
  CASE WHEN c.severity = 'blocking' THEN 0 ELSE 1 END,
  c.observed DESC
