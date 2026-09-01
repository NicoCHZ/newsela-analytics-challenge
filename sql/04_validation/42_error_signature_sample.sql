-- A fixed sample of what the "error output" detector actually matched.
--
-- Purpose:  A regular expression is a claim about text, and the only honest
--           way to know its precision is to read what it caught. This pulls a
--           deterministic sample — every question whose id is a multiple of a
--           fixed number, in id order — so the same fifty rows come back on
--           every run and the README's hand count refers to something a reader
--           can open.
-- Source:   so_analysis.question_cohort
-- Grain:    one row per sampled question
-- Cost:     see results/run_log.md

SELECT
  c.question_id,
  REGEXP_REPLACE(REGEXP_REPLACE(c.error_signature_context, r'<[^>]+>', ' '), r'\s+', ' ') AS matched_context
FROM `so_analysis.question_cohort` AS c
WHERE c.cohort_region = 'current_year'
  AND c.body_has_error_signature
  AND MOD(c.question_id, 2000) = 0
ORDER BY c.question_id
LIMIT 50
