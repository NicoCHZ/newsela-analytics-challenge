-- Prompt 2, step 1: what did we know about the ASKER before they posted?
--
-- Purpose:  The most tempting asker attribute is `users.reputation` — and it is
--           unusable. That column is a snapshot taken when the dump was built in
--           late 2022, not the reputation the person had when they asked. Using
--           it to explain a January 2022 outcome pours ten months of future
--           information into a predictor. It is the cleanest leakage trap in
--           this dataset and I have left it out entirely.
--
--           What IS safe: the account's age on the day of the question, the
--           person's own record on questions they had already asked, and how
--           much they had already answered for other people.
-- Source:   posts_questions (full history, four narrow columns), users
--           (two columns), so_analysis.answers, post_vote_dates, params
-- Output:   so_analysis.asker_history — one row per cohort question whose
--           asker's account still exists (a deleted account has no history to
--           look up, and 31_post_quality_rates treats it as unknown, not as
--           "no history")
-- Cost:     see results/run_log.md
--
-- Leakage-free by construction, in two ways:
--   * A prior question counts as "answered before" or "accepted before" only if
--     that event is DATED before the new question was asked. The first version
--     of this table read acceptance from the question's final state, so a prior
--     question accepted the week after the new one — the classic "come back,
--     accept the old answers, ask the new question" session — was counted as
--     history. The dates from 13_build_post_vote_dates remove that.
--   * Rates are computed over prior questions at least `settle_days` old, so a
--     question asked last week is not counted as "never accepted" merely because
--     nobody has had time yet. The plain count of prior questions has no such
--     lag: it is a count of behaviour, not of outcomes.

CREATE OR REPLACE TABLE `so_analysis.asker_history` AS

WITH params AS (
  SELECT
    p.settle_days
  FROM `so_analysis.params` AS p
),

cohort AS (
  SELECT
    c.question_id,
    c.owner_user_id,
    c.asked_on
  FROM `so_analysis.question_cohort` AS c
  WHERE c.owner_user_id IS NOT NULL
),

-- Every question ever asked by anyone: a 2022 asker's record may start in 2010.
all_questions AS (
  SELECT
    q.id AS question_id,
    q.owner_user_id,
    DATE(q.creation_date) AS asked_on,
    q.accepted_answer_id
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
  WHERE q.owner_user_id IS NOT NULL
),

first_answers AS (
  SELECT
    a.question_id,
    MIN(a.answered_on) AS first_answer_on
  FROM `so_analysis.answers` AS a
  GROUP BY a.question_id
),

history AS (
  SELECT
    h.question_id,
    h.owner_user_id,
    h.asked_on,
    fa.first_answer_on,
    v.accepted_on
  FROM all_questions AS h
  LEFT JOIN first_answers AS fa
    ON fa.question_id = h.question_id
  LEFT JOIN `so_analysis.post_vote_dates` AS v
    ON v.post_id = h.accepted_answer_id
),

prior_questions AS (
  SELECT
    c.question_id,
    COUNTIF(h.question_id IS NOT NULL) AS prior_questions,
    COUNTIF(h.asked_on <= DATE_SUB(c.asked_on, INTERVAL p.settle_days DAY)) AS prior_questions_settled,
    COUNTIF(h.asked_on <= DATE_SUB(c.asked_on, INTERVAL p.settle_days DAY)
            AND h.first_answer_on < c.asked_on) AS prior_answered_before,
    COUNTIF(h.asked_on <= DATE_SUB(c.asked_on, INTERVAL p.settle_days DAY)
            AND h.accepted_on < c.asked_on) AS prior_accepted_before
  FROM cohort AS c
  CROSS JOIN params AS p
  LEFT JOIN history AS h
    ON h.owner_user_id = c.owner_user_id
   AND h.asked_on < c.asked_on
  GROUP BY c.question_id
),

prior_answers AS (
  SELECT
    c.question_id,
    COUNTIF(a.answer_id IS NOT NULL) AS prior_answers_written
  FROM cohort AS c
  LEFT JOIN `so_analysis.answers` AS a
    ON a.answerer_user_id = c.owner_user_id
   AND a.answered_on < c.asked_on
  GROUP BY c.question_id
)

SELECT
  c.question_id,
  DATE_DIFF(c.asked_on, DATE(u.creation_date), DAY) AS asker_account_age_days,
  pq.prior_questions,
  pq.prior_questions_settled,
  SAFE_DIVIDE(pq.prior_answered_before, pq.prior_questions_settled) AS prior_answer_rate,
  SAFE_DIVIDE(pq.prior_accepted_before, pq.prior_questions_settled) AS prior_acceptance_rate,
  pa.prior_answers_written
FROM cohort AS c
LEFT JOIN `bigquery-public-data.stackoverflow.users` AS u
  ON u.id = c.owner_user_id
LEFT JOIN prior_questions AS pq
  ON pq.question_id = c.question_id
LEFT JOIN prior_answers AS pa
  ON pa.question_id = c.question_id
