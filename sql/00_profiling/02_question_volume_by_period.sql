-- Profiling 2/3: Question volume and outcome rates over time.
--
-- Purpose:  Two questions in one pass.
--           (a) Where does the data actually stop? A load-job timestamp is not
--               proof; the last month with a normal question count is.
--           (b) Does the acceptance rate decline toward the end of the data?
--               If it does, that is right-censoring, not a trend: questions
--               asked close to the snapshot have had less time to be answered
--               and accepted. Any year-level rate that ignores this is biased
--               downward, and biased *unevenly* across tags with different
--               answer latencies.
-- Source:   bigquery-public-data.stackoverflow.posts_questions
-- Grain:    one row per calendar month
-- Cost:     see results/run_log.md (reads 3 narrow columns; never touches body)

WITH monthly AS (
  SELECT
    DATE_TRUNC(DATE(q.creation_date), MONTH) AS month,
    COUNT(*) AS questions,
    COUNTIF(q.answer_count > 0) AS answered,
    COUNTIF(q.accepted_answer_id IS NOT NULL) AS accepted
  FROM `bigquery-public-data.stackoverflow.posts_questions` AS q
  GROUP BY month
)

SELECT
  m.month,
  m.questions,
  ROUND(SAFE_DIVIDE(m.answered, m.questions), 4) AS answer_rate,
  ROUND(SAFE_DIVIDE(m.accepted, m.questions), 4) AS acceptance_rate,
  -- Conditional acceptance: given that somebody answered, did the asker come
  -- back and mark it? This is the stage that censoring hits hardest.
  ROUND(SAFE_DIVIDE(m.accepted, m.answered), 4) AS acceptance_rate_given_answered
FROM monthly AS m
ORDER BY m.month DESC
LIMIT 60
