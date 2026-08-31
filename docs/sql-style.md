# SQL conventions

These are the conventions I applied throughout this repository. They are adapted
from Mozilla's public [bigquery-etl style guide](https://github.com/mozilla/bigquery-etl),
with the parts specific to their internal tooling removed.

## Formatting

1. SQL keywords in `UPPERCASE`; identifiers, aliases and function results in
   `lowercase`.
2. Two-space indentation, no tabs.
3. One column per line in every `SELECT`.
4. Every table gets an explicit alias with `AS`, and every column is qualified
   with that alias whenever more than one source is in scope.
5. Explicit join types (`INNER JOIN`, `LEFT JOIN`) — never a bare `JOIN`.
6. `ORDER BY` only in the final `SELECT`, never inside a CTE.

## Structure

7. CTEs rather than subqueries in `FROM`. One CTE per logical step, named for
   what it *contains* (`questions_in_window`), not for what it *does* (`step_2`).
8. Every query is layered top to bottom in the same order:
   `params` → cohort → features → a thin final `SELECT` that only shapes and
   names the output.
9. **A `params` CTE at the top holds every constant.** Date boundaries, volume
   floors, maturation windows. No magic numbers buried in the middle of a query.
   This also makes each query re-runnable against a refreshed dataset by editing
   one block.
10. `SAFE_DIVIDE(a, b)` rather than `a / b`. Every rate here divides by a count,
    and counts can be zero.
11. `COUNTIF(x IS NOT NULL)` rather than `COUNT(x)` — it states the intent
    instead of relying on the reader remembering that `COUNT` skips nulls.

## Comments

12. A header block on every file: purpose, source tables, **output grain** (one
    row per what?), assumptions, and the measured cost.
13. Inline comments explain *why*, not *what*. A comment earns its place when it
    records an assumption, justifies a threshold, or flags a known data quirk.

## Cost discipline

The analysis runs on the BigQuery sandbox, which allows 1 TB of query processing
per month. BigQuery bills on **bytes read from the columns referenced**, not on
rows returned, which drives every rule below.

14. Never `SELECT *`.
15. **Never read `posts_questions.body` more than once.** It is the overwhelming
    majority of that table's storage. Every text-derived feature is computed in a
    single pass and materialized; nothing downstream touches it again.
16. Dry-run every query before executing it, and record the estimated bytes in
    the file header. Dry runs are free.
17. `LIMIT` does **not** reduce bytes billed. It caps rows returned, not bytes
    scanned. It is used here to keep committed result files readable, never as a
    cost control.
18. Column pruning is the only real cost lever on this dataset — see
    `docs/data-quality.md` for the partitioning check and what it implies.
19. Materialize the analysis cohort once. Every subsequent query then reads a
    narrow table measured in megabytes rather than re-scanning the source.

## Analytical guardrails

20. **Every rate needs a volume floor.** A tag with three questions and three
    accepted answers is a 100% rate and means nothing. The floor lives in
    `params` and is justified in the README, not chosen by feel.
21. Rank by an interval bound rather than a point estimate when comparing rates
    across groups of very different sizes.
