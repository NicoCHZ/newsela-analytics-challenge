-- Prompt 2, step 1: what did we know about the ASKER before they posted?
--
-- Purpose:  The most tempting asker attribute is `users.reputation` — and it is
--           unusable. That column is a snapshot taken when the dump was built in
--           late 2022, not the reputation the person had when they asked. Using
--           it to explain a January 2022 outcome pours ten months of future
--           information into a predictor. It is the cleanest leakage trap in
--           this dataset and I have left it out entirely.
--
--           What IS safe: the account's age on the day of the question, and the
--           person's own track record on questions they had already asked.
-- Source:   posts_questions (full history, narrow columns only), users
-- Output:   so_analysis.asker_history — one row per question in the cohort
-- Cost:     see results/run_log.md
--
-- The 90-day lag on prior history is deliberate. A question asked last week may
-- not have been accepted yet even if it eventually will be, so counting it as
-- "not accepted" would import the same censoring problem at the asker level.
-- Only questions asked at least 90 days earlier are counted, by which point
-- ~93% of eventual acceptances have happened (see 00_profiling/03).

CREATE OR REPLACE TABLE `so_analysis.asker_history` AS

WITH all_questions AS (
  -- Full history is needed here: a 2022 asker's track record may start in 2010.
  -- Only four narrow columns, so the scan stays cheap.
  SELECT
    q.id AS question_id,
    q.owner_user_id,
    DATE(q.creation_date) AS asked_on,
    q.accepted_answer_id IS NOT NULL AS was_accepted
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
  WHERE q.owner_user_id IS NOT NULL
),

cohort AS (
  SELECT c.question_id, c.owner_user_id, c.asked_on
  FROM `so_analysis.question_cohort` AS c
  WHERE c.owner_user_id IS NOT NULL
),

prior_activity AS (
  SELECT
    c.question_id,
    COUNT(h.question_id) AS prior_questions,
    SAFE_DIVIDE(COUNTIF(h.was_accepted), COUNT(h.question_id)) AS prior_acceptance_rate
  FROM cohort AS c
  LEFT JOIN all_questions AS h
    ON h.owner_user_id = c.owner_user_id
   AND h.asked_on <= DATE_SUB(c.asked_on, INTERVAL 90 DAY)
  GROUP BY c.question_id
)

SELECT
  c.question_id,
  DATE_DIFF(c.asked_on, DATE(u.creation_date), DAY) AS asker_account_age_days,
  pa.prior_questions,
  pa.prior_acceptance_rate
FROM cohort AS c
LEFT JOIN `bigquery-public-data.stackoverflow.users` AS u
  ON u.id = c.owner_user_id
LEFT JOIN prior_activity AS pa
  ON pa.question_id = c.question_id
