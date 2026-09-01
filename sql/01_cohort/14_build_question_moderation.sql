-- Cohort 5/7: what moderation did to each question — closed, reopened, or
-- marked as a duplicate.
--
-- Purpose:  A question with no answer is not one thing. It may have been hard,
--           or it may have been closed as a duplicate within the hour, which is
--           a moderation outcome rather than a difficulty signal. Prompt 1's
--           bottom tags cannot be interpreted without telling those apart. The
--           question table in this dataset has no closed_date column; the
--           events live in post_history (type 10 = closed, 11 = reopened) and
--           duplicate links in post_links (link_type_id = 3).
-- Source:   bigquery-public-data.stackoverflow.post_history — narrow columns
--           only. Its `text` column holds a full post revision per row and is
--           what makes the table 113 GB; it is never read. post_links,
--           so_analysis.question_cohort, so_analysis.params
-- Output:   so_analysis.question_moderation — one row per cohort question that
--           was ever closed, reopened, or linked as a duplicate
-- Cost:     see results/run_log.md (the same query with the close-reason text
--           would read 104 GB; this one reads about 3.5)

CREATE OR REPLACE TABLE `so_analysis.question_moderation` AS

WITH cohort AS (
  SELECT
    c.question_id
  FROM `so_analysis.question_cohort` AS c
),

close_events AS (
  SELECT
    h.post_id AS question_id,
    MIN(IF(h.post_history_type_id = 10, DATE(h.creation_date), NULL)) AS first_closed_on,
    MAX(IF(h.post_history_type_id = 11, DATE(h.creation_date), NULL)) AS last_reopened_on,
    COUNTIF(h.post_history_type_id = 10) AS close_events
  FROM `bigquery-public-data.stackoverflow.post_history` AS h
  CROSS JOIN `so_analysis.params` AS p
  WHERE h.post_history_type_id IN (10, 11)
    -- Events on cohort questions cannot predate the cohort. This does not
    -- reduce bytes (no partitioning); it keeps the aggregation small.
    AND DATE(h.creation_date) >= p.comparison_start
  GROUP BY h.post_id
),

duplicate_links AS (
  SELECT
    l.post_id AS question_id,
    MIN(DATE(l.creation_date)) AS duplicate_linked_on
  FROM `bigquery-public-data.stackoverflow.post_links` AS l
  WHERE l.link_type_id = 3
  GROUP BY l.post_id
)

SELECT
  c.question_id,
  ce.first_closed_on,
  ce.last_reopened_on,
  COALESCE(ce.close_events, 0) AS close_events,
  d.duplicate_linked_on
FROM cohort AS c
LEFT JOIN close_events AS ce
  ON ce.question_id = c.question_id
LEFT JOIN duplicate_links AS d
  ON d.question_id = c.question_id
WHERE ce.question_id IS NOT NULL
  OR d.question_id IS NOT NULL
