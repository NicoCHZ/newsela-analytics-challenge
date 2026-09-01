-- Cohort 3/7: the narrow answer table, read from the source exactly once.
--
-- Purpose:  Three later steps need answers — the per-question outcomes, the
--           per-tag answerer supply, and each asker's own answering history —
--           and the last of those needs the full history back to 2008, because a
--           2022 asker may have been answering since 2010. Since these public
--           tables are not partitioned, a date filter would not reduce the bytes
--           anyway, so the whole table is read once, five narrow columns, and
--           materialized. `body` is never touched.
-- Source:   bigquery-public-data.stackoverflow.posts_answers
-- Output:   so_analysis.answers — one row per answer, all years
-- Cost:     see results/run_log.md
--
-- `lifetime_score` is the score at the time of the dump, not at any earlier
-- moment. It is kept for descriptive comparisons (was the accepted answer also
-- the top-scored one?) and is never used as a windowed outcome; the windowed
-- "positively answered" flag comes from vote dates in 13_build_post_vote_dates.

CREATE OR REPLACE TABLE `so_analysis.answers` AS
SELECT
  a.id AS answer_id,
  a.parent_id AS question_id,
  a.owner_user_id AS answerer_user_id,
  DATE(a.creation_date) AS answered_on,
  a.score AS lifetime_score
FROM `bigquery-public-data.stackoverflow.posts_answers` AS a
