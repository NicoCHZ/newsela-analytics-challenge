-- Cohort 4/7: WHEN was each answer accepted, and when did it first get an upvote?
--
-- Purpose:  The question table records whether a question was *ever* accepted,
--           with no date. The date lives in the votes table: vote_type_id = 1 is
--           "AcceptedByOriginator" and vote_type_id = 2 is an upvote. Both dates
--           are needed to measure outcomes inside a fixed window, and the
--           acceptance date is also what makes an asker's prior track record
--           leakage-free (03_post_qualities/30). The votes table is read once
--           here and never again.
-- Source:   bigquery-public-data.stackoverflow.votes, so_analysis.params
-- Output:   so_analysis.post_vote_dates (one row per post that received either
--           vote type)
-- Cost:     see results/run_log.md
--
-- Two things to know about `votes.creation_date`:
--   * It is date-only: every timestamp sits at midnight. `accepted_at_raw` keeps
--     the raw value so 04_validation/40 can assert that, and all timing math in
--     this project is done in whole calendar days as a consequence.
--   * Acceptance dates are kept for every year, because prior questions of a
--     2022 asker can be arbitrarily old. Upvote dates are only needed for
--     answers to cohort questions, so they are kept from comparison_start on.
--     (This does not save bytes, since the table is not partitioned; it keeps
--     the output small.)

CREATE OR REPLACE TABLE `so_analysis.post_vote_dates` AS
SELECT
  v.post_id,
  MIN(IF(v.vote_type_id = 1, DATE(v.creation_date), NULL)) AS accepted_on,
  MIN(IF(v.vote_type_id = 1, v.creation_date, NULL)) AS accepted_at_raw,
  MIN(IF(v.vote_type_id = 2, DATE(v.creation_date), NULL)) AS first_upvote_on
FROM `bigquery-public-data.stackoverflow.votes` AS v
CROSS JOIN `so_analysis.params` AS p
WHERE v.vote_type_id = 1
  OR (v.vote_type_id = 2 AND DATE(v.creation_date) >= p.comparison_start)
GROUP BY v.post_id
