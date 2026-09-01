# SQL conventions

These are the conventions I applied throughout this repository. They are adapted
from Mozilla's public [bigquery-etl style guide](https://github.com/mozilla/bigquery-etl),
with the parts specific to their internal tooling removed, plus a few rules of my
own that came out of getting things wrong the first time.

## Formatting

1. SQL keywords in `UPPERCASE`; identifiers, aliases and function results in
   `lowercase`.
2. Two-space indentation, no tabs.
3. One column per line in every `SELECT`.
4. Every table gets an explicit alias with `AS`, and every column is qualified
   with that alias whenever more than one source is in scope.
5. Explicit join types (`INNER JOIN`, `LEFT JOIN`, `CROSS JOIN`), never a bare
   `JOIN`.
6. `ORDER BY` only in the final `SELECT`, never inside a CTE. A top-N inside a
   CTE is written with `QUALIFY ROW_NUMBER() OVER (...) <= n`, which says what
   it is doing.
7. Every ordering ends with a tie-breaker (the tag name, the check name), in
   the final `ORDER BY` and inside every `ROW_NUMBER()`. Ties resolved by
   whatever order the engine happened to produce made the committed CSVs
   change between runs of an unchanged query. A `git diff` should be silent
   when nothing changed.

## Structure

8. CTEs rather than subqueries in `FROM`. One CTE per logical step, named for
   what it contains (`questions_in_window`), not for what it does (`step_2`).
9. Every query is layered top to bottom in the same order: `params`, cohort,
   features, and a thin final `SELECT` that only shapes and names the output.
10. Constants live in one place and are derived where they can be.
    `so_analysis.params` holds every date boundary, the maturation window, the
    interval width and the group sizes; `so_analysis.ranking_params` holds the
    volume floor, computed from the cohort's own base rate. A query that needs
    a constant `CROSS JOIN`s the table, and a `params` CTE at the top of a
    query only ever reads from those tables. There are no magic numbers in the
    middle of a query, and nothing to edit by hand if the source is reloaded.
11. `SAFE_DIVIDE(a, b)` rather than `a / b`. Every rate here divides by a count,
    and counts can be zero.
12. `COUNTIF(x IS NOT NULL)` rather than `COUNT(x)`. It states the intent
    instead of relying on the reader remembering that `COUNT` skips nulls.
13. Boolean outcome flags are `COALESCE`d to `FALSE` where they are built, so
    "no answer" and "not within the window" behave identically everywhere
    downstream, and no `COUNTIF` silently drops a `NULL`.
14. Never `SELECT *`, not even from a CTE. Listing the columns is what makes a
    rename or a dropped column fail loudly at the point of use.

## Comments

15. A header block on every file: purpose, source tables, output grain (one
    row per what?), and assumptions. The measured cost is recorded once, in
    `results/run_log.md`, by the runner. Headers point there rather than
    carrying a number that goes stale.
16. Inline comments explain why, not what. A comment earns its place when it
    records an assumption, justifies a threshold, or flags a known data quirk.
17. A comment must not claim something the repository does not show. "Verified
    that every accepted question has an acceptance vote" is a data-quality row
    with a number in it, or it is not written.

## Cost discipline

The analysis runs on the BigQuery sandbox, which allows 1 TB of query processing
per month. BigQuery bills on bytes read from the columns referenced, not on rows
returned, which drives every rule below.

18. Read each source table once, narrow, and materialize. `posts_questions` is
    read once with `body` (the expensive pass) and once more with four narrow
    columns for asker history; `posts_answers`, `votes`, `post_history` and
    `post_links` are each read once. Everything else in the repository reads
    the materialized tables in `so_analysis`, measured in megabytes.
19. Column pruning is the only real cost lever on this dataset. These public
    tables are not partitioned or clustered (00_profiling/01 checks), so a date
    filter reduces nothing. A `WHERE` on a date is there to keep an output
    small or a join correct, never to save bytes, and its comment says so.
20. Dry-run every query before executing it. Dry runs are free, and they are
    what the runner records as the cold-run cost.
21. `LIMIT` does not reduce bytes billed. It caps rows returned, not bytes
    scanned. It is used here to keep committed result files readable, never as
    a cost control.
22. The runner writes each output to a temporary file and moves it into
    `results/` only when the query succeeds, so a failed run never leaves a
    committed file half-written.

## Analytical guardrails

23. Every rate needs a volume floor. A tag with three questions and three
    accepted answers is a 100% rate and means nothing. The floor is derived from
    the precision I would need to call two tags different, not chosen by feel.
24. Rank by an interval bound rather than a point estimate when comparing rates
    across groups of very different sizes.
25. Outcomes are dated. A prior event counts as "known at post time" only if
    its own date is before the question was asked. Reading a prior question's
    acceptance from its final state leaks the future.
26. A robustness check that changes the eligible population must report
    retention against what is still eligible, not against ten, and a rank
    correlation over the tags common to both variants. Otherwise raising a
    floor looks like instability when nothing moved.
27. When a cohort spans the site's automatic-deletion boundary (a year before
    the snapshot), say which side each comparison sits on. The older side is a
    survivor population.
