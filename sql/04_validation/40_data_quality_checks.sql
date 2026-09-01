-- Data quality assertions.
--
-- Purpose:  One row per check, with what I expected, what I found, and whether
--           it changed the analysis. Checks that pass are worth little on their
--           own; the ones that fail, and the informational ones with surprising
--           values, are what shaped the rest of the project.
-- Source:   the materialized tables in so_analysis, plus the public `tags` table
--           for referential integrity
-- Grain:    one row per check
-- Cost:     see results/run_log.md
--
-- `severity` is set by hand per check rather than derived from the count,
-- because "expected to be non-zero" is a judgement, not a threshold. A check
-- that counts deleted accounts is informational; one that finds an accepted
-- answer older than its own question is not.
--
-- Three checks deserve a word:
--   * Freshness is SUPPOSED to fail. It is the check that answers "what is the
--     current year?" with evidence rather than an assumption, and in a live
--     pipeline it is what would have paged somebody in December 2022.
--   * The two "deletion boundary" rows are the fingerprint of Stack Overflow's
--     automatic removal of old unanswered questions: a step in the answer rate
--     exactly a year before the snapshot, and almost no surviving question with
--     a negative score and no answer. They are informational because the data
--     is behaving as the site's rules say it should — but any comparison across
--     that boundary has to know about it.
--   * "Accepted without an acceptance vote" is the referential check between
--     the question's accepted_answer_id and the votes table, which every timing
--     figure in this project depends on. It was a comment claiming "verified"
--     in the first version; now it is a row.

WITH params AS (
  SELECT
    p.snapshot_date,
    p.purge_boundary
  FROM `so_analysis.params` AS p
),

cohort_checks AS (
  SELECT
    COUNT(*) - COUNT(DISTINCT c.question_id) AS duplicate_question_ids,
    COUNTIF(c.n_tags = 0) AS questions_without_tags,
    COUNTIF(c.n_tags > 5) AS more_than_five_tags,
    COUNTIF(c.answer_count < 0) AS negative_answer_count,
    COUNTIF(c.was_ever_accepted AND c.answer_count = 0) AS accepted_but_no_answers,
    COUNTIF(c.title_length IS NULL OR c.title_length = 0 OR c.body_html_length IS NULL OR c.body_html_length = 0)
      AS empty_title_or_body,
    COUNTIF(c.cohort_region IS NULL) AS unlabelled_region,
    COUNTIF(c.is_community_owned) AS community_owned_posts,
    COUNTIF(c.posthoc_asker_account_deleted) AS asker_account_deleted,
    COUNTIF(c.posthoc_asker_account_deleted AND NOT c.has_display_name) AS deleted_without_display_name,
    COUNTIF(c.posthoc_score < 0 AND c.answer_count = 0) AS negative_score_unanswered_survivors
  FROM `so_analysis.question_cohort` AS c
  WHERE c.cohort_region = 'current_year'
),

outcome_checks AS (
  SELECT
    COUNTIF(o.question_id IS NULL) AS questions_missing_outcomes,
    COUNTIF(c.was_ever_accepted AND o.accepted_on IS NULL) AS accepted_without_acceptance_vote,
    COUNTIF(c.accepted_answer_id IS NOT NULL AND a.answer_id IS NULL) AS accepted_answer_missing_from_answers,
    COUNTIF(a.answer_id IS NOT NULL AND a.question_id != c.question_id) AS accepted_answer_belongs_to_another_question,
    COUNTIF(a.answered_on < c.asked_on) AS accepted_answer_predates_question,
    COUNTIF(c.answer_count != o.n_answers) AS answer_count_disagrees_with_answers_present
  FROM `so_analysis.question_cohort` AS c
  LEFT JOIN `so_analysis.question_outcomes` AS o
    ON o.question_id = c.question_id
  LEFT JOIN `so_analysis.answers` AS a
    ON a.answer_id = c.accepted_answer_id
  WHERE c.cohort_region = 'current_year'
),

asker_checks AS (
  SELECT
    COUNTIF(h.asker_account_age_days IS NULL) AS asker_not_found_in_users,
    COUNTIF(h.asker_account_age_days < 0) AS negative_account_age
  FROM `so_analysis.question_cohort` AS c
  LEFT JOIN `so_analysis.asker_history` AS h
    ON h.question_id = c.question_id
  WHERE c.cohort_region = 'current_year'
    AND c.owner_user_id IS NOT NULL
),

tag_checks AS (
  SELECT
    COUNT(DISTINCT IF(tg.tag_name IS NULL, tag, NULL)) AS tags_not_in_tag_table
  FROM `so_analysis.question_cohort` AS c
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  LEFT JOIN `bigquery-public-data.stackoverflow.tags` AS tg
    ON tg.tag_name = tag
  WHERE c.cohort_region = 'current_year'
    AND tag != ''
),

snapshot_checks AS (
  SELECT
    DATE_DIFF(p.snapshot_date,
              (SELECT MAX(a.answered_on) FROM `so_analysis.answers` AS a), DAY) AS days_newest_answer_before_snapshot,
    DATE_DIFF(p.snapshot_date,
              (SELECT MAX(v.accepted_on) FROM `so_analysis.post_vote_dates` AS v), DAY) AS days_newest_acceptance_before_snapshot,
    (SELECT COUNTIF(EXTRACT(TIME FROM v.accepted_at_raw) != TIME '00:00:00')
     FROM `so_analysis.post_vote_dates` AS v
     WHERE v.accepted_at_raw IS NOT NULL) AS acceptance_votes_not_at_midnight
  FROM params AS p
),

-- The last full month before the purge boundary against the first full month
-- after it, in points of answer rate.
purge_check AS (
  SELECT
    CAST(ROUND(100 * (
      SAFE_DIVIDE(COUNTIF(c.answer_count > 0 AND DATE_TRUNC(c.asked_on, MONTH) = DATE_TRUNC(DATE_SUB(p.purge_boundary, INTERVAL 1 MONTH), MONTH)),
                  COUNTIF(DATE_TRUNC(c.asked_on, MONTH) = DATE_TRUNC(DATE_SUB(p.purge_boundary, INTERVAL 1 MONTH), MONTH)))
      - SAFE_DIVIDE(COUNTIF(c.answer_count > 0 AND DATE_TRUNC(c.asked_on, MONTH) = DATE_TRUNC(DATE_ADD(p.purge_boundary, INTERVAL 1 MONTH), MONTH)),
                    COUNTIF(DATE_TRUNC(c.asked_on, MONTH) = DATE_TRUNC(DATE_ADD(p.purge_boundary, INTERVAL 1 MONTH), MONTH)))
    )) AS INT64) AS answer_rate_step_at_purge_boundary_points
  FROM `so_analysis.question_cohort` AS c
  CROSS JOIN params AS p
),

freshness_check AS (
  SELECT
    DATE_DIFF(CURRENT_DATE(), p.snapshot_date, DAY) AS days_since_newest_question
  FROM params AS p
),

all_checks AS (
  SELECT 'freshness: days since the newest question in the source' AS check_name,
         (SELECT f.days_since_newest_question FROM freshness_check AS f) AS observed,
         'blocking' AS severity,
         'expected under 7 in a live pipeline' AS expectation
  UNION ALL SELECT 'accepted question with no acceptance vote in the votes table',
         (SELECT o.accepted_without_acceptance_vote FROM outcome_checks AS o), 'blocking', 'expected 0'
  UNION ALL SELECT 'accepted answer id not present in posts_answers',
         (SELECT o.accepted_answer_missing_from_answers FROM outcome_checks AS o), 'blocking', 'expected 0'
  UNION ALL SELECT 'accepted answer belongs to a different question',
         (SELECT o.accepted_answer_belongs_to_another_question FROM outcome_checks AS o), 'blocking', 'expected 0'
  UNION ALL SELECT 'accepted answer created before its own question',
         (SELECT o.accepted_answer_predates_question FROM outcome_checks AS o), 'blocking', 'expected 0'
  UNION ALL SELECT 'cohort question with no outcome row',
         (SELECT o.questions_missing_outcomes FROM outcome_checks AS o), 'blocking', 'expected 0'
  UNION ALL SELECT 'duplicate question ids',
         (SELECT cc.duplicate_question_ids FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'questions with no tags',
         (SELECT cc.questions_without_tags FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'questions with more than five tags',
         (SELECT cc.more_than_five_tags FROM cohort_checks AS cc), 'blocking', 'expected 0 - that is the site limit'
  UNION ALL SELECT 'negative answer_count',
         (SELECT cc.negative_answer_count FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'marked accepted but answer_count is zero',
         (SELECT cc.accepted_but_no_answers FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'empty or null title or body',
         (SELECT cc.empty_title_or_body FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'question outside every cohort region',
         (SELECT cc.unlabelled_region FROM cohort_checks AS cc), 'blocking', 'expected 0'
  UNION ALL SELECT 'deleted-account asker without a display name',
         (SELECT cc.deleted_without_display_name FROM cohort_checks AS cc), 'blocking',
         'expected 0 - the site keeps the name when it drops the id'
  UNION ALL SELECT 'asker account created after the question',
         (SELECT ac.negative_account_age FROM asker_checks AS ac), 'blocking', 'expected 0'
  UNION ALL SELECT 'newest answer: days before the question snapshot',
         (SELECT s.days_newest_answer_before_snapshot FROM snapshot_checks AS s), 'blocking',
         'expected 0 or 1 - all tables cut on the same day'
  UNION ALL SELECT 'newest acceptance vote: days before the question snapshot',
         (SELECT s.days_newest_acceptance_before_snapshot FROM snapshot_checks AS s), 'blocking',
         'expected 0 or 1 - all tables cut on the same day'
  UNION ALL SELECT 'acceptance votes with a time of day other than midnight',
         (SELECT s.acceptance_votes_not_at_midnight FROM snapshot_checks AS s), 'informational',
         'expected 0: the column is date-only, so timing is computed in whole days'
  UNION ALL SELECT 'answer_count disagrees with the answers actually present',
         (SELECT o.answer_count_disagrees_with_answers_present FROM outcome_checks AS o), 'informational',
         'expected near 0: the counter excludes deleted answers, as does the dump'
  UNION ALL SELECT 'asker id not found in the users table',
         (SELECT ac.asker_not_found_in_users FROM asker_checks AS ac), 'informational', 'expected near 0'
  UNION ALL SELECT 'distinct tags not present in the tags table',
         (SELECT t.tags_not_in_tag_table FROM tag_checks AS t), 'informational', 'expected 0'
  UNION ALL SELECT 'community wiki posts in the cohort',
         (SELECT cc.community_owned_posts FROM cohort_checks AS cc), 'informational',
         'no single owner - acceptance means something different'
  UNION ALL SELECT 'asker account deleted after posting',
         (SELECT cc.asker_account_deleted FROM cohort_checks AS cc), 'informational',
         'expected non-zero; a post-hoc attribute, not an anonymous asker'
  UNION ALL SELECT 'deletion boundary: negative-score questions still unanswered',
         (SELECT cc.negative_score_unanswered_survivors FROM cohort_checks AS cc), 'informational',
         'expected near 0: the site deletes them, so the survivors are the answered ones'
  UNION ALL SELECT 'deletion boundary: answer-rate step one year before the snapshot (points)',
         (SELECT pc.answer_rate_step_at_purge_boundary_points FROM purge_check AS pc), 'informational',
         'expected well above 5: older months are a survivor population'
)

SELECT
  c.check_name,
  c.observed,
  c.severity,
  c.expectation,
  CASE
    WHEN c.severity = 'informational' THEN 'NOTED'
    WHEN c.check_name LIKE 'freshness%' AND c.observed > 7 THEN 'FAIL'
    WHEN c.check_name LIKE 'newest %' AND c.observed > 1 THEN 'FAIL'
    WHEN c.check_name LIKE 'newest %' THEN 'PASS'
    WHEN c.severity = 'blocking' AND c.observed > 0 THEN 'FAIL'
    ELSE 'PASS'
  END AS status
FROM all_checks AS c
ORDER BY
  CASE WHEN c.severity = 'blocking' THEN 0 ELSE 1 END,
  c.check_name
