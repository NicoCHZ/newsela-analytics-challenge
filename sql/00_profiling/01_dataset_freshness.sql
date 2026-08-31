-- Profiling 1/3: How fresh is this dataset, and how big are the tables?
--
-- Purpose:  Establish, from the data itself, what "the current year" can mean.
--           The challenge asks for the current year; before assuming anything,
--           I want the dataset to tell me what its own "today" is.
-- Source:   bigquery-public-data.stackoverflow.__TABLES__
-- Grain:    one row per table in the dataset
-- Cost:     0 bytes. __TABLES__ is table metadata, not table data.
--
-- Read this alongside 02_question_volume_by_period.sql: this query gives the
-- table-level last-modified timestamp, which is a property of the *load job*,
-- while 02 gives the latest row-level creation_date, which is a property of the
-- *data*. They can disagree, and only the second one bounds the analysis.

SELECT
  table_id,
  row_count,
  ROUND(size_bytes / POW(1024, 3), 2) AS size_gb,
  TIMESTAMP_MILLIS(creation_time) AS table_created_at,
  TIMESTAMP_MILLIS(last_modified_time) AS table_last_modified_at,
  DATE_DIFF(CURRENT_DATE(), DATE(TIMESTAMP_MILLIS(last_modified_time)), DAY) AS days_since_last_load
FROM `bigquery-public-data.stackoverflow.__TABLES__`
ORDER BY size_bytes DESC
