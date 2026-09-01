-- Profiling 1/2: How fresh is this dataset, how big are its tables, and is any
-- of it partitioned?
--
-- Purpose:  Establish, from the data itself, what "the current year" can mean.
--           The challenge asks for the current year; before assuming anything,
--           I want the dataset to tell me what its own "today" is. The same
--           pass records the one physical fact the whole cost strategy rests
--           on: none of these tables is partitioned or clustered, so a date
--           filter reduces nothing and which columns you touch is the only
--           lever (see the README's cost section).
-- Source:   bigquery-public-data.stackoverflow.__TABLES__ and
--           INFORMATION_SCHEMA.COLUMNS (metadata, not table data)
-- Grain:    one row per table in the dataset
-- Cost:     see results/run_log.md (metadata only)
--
-- Read this alongside 02_question_volume_by_period.sql: this query gives the
-- table-level last-modified timestamp, which is a property of the *load job*,
-- while 02 gives the latest row-level creation_date, which is a property of the
-- *data*. They can disagree, and only the second one bounds the analysis.

WITH physical_layout AS (
  SELECT
    c.table_name,
    COUNTIF(c.is_partitioning_column = 'YES') AS partitioning_columns,
    COUNTIF(c.clustering_ordinal_position IS NOT NULL) AS clustering_columns
  FROM `bigquery-public-data.stackoverflow.INFORMATION_SCHEMA.COLUMNS` AS c
  GROUP BY c.table_name
)

SELECT
  t.table_id,
  t.row_count,
  ROUND(t.size_bytes / POW(1024, 3), 2) AS size_gb,
  DATE(TIMESTAMP_MILLIS(t.creation_time)) AS table_created_on,
  DATE(TIMESTAMP_MILLIS(t.last_modified_time)) AS table_last_loaded_on,
  COALESCE(l.partitioning_columns, 0) AS partitioning_columns,
  COALESCE(l.clustering_columns, 0) AS clustering_columns
FROM `bigquery-public-data.stackoverflow.__TABLES__` AS t
LEFT JOIN physical_layout AS l
  ON l.table_name = t.table_id
ORDER BY t.size_bytes DESC, t.table_id
