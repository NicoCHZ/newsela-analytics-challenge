-- Prompt 1a/1b, third explanation: are the low-approval tags just the generic
-- ones, added in third or fourth position, describing a technology the
-- question passes through rather than what it is about?
--
-- Purpose:  The bottom of the ranking is full of cross-cutting tags (browser,
--           proxy, ssl, server, installation) and the top of specific tools
--           (awk, sed, dplyr, regex). If a tag's questions do badly when the tag
--           trails the list but fine when it leads it, the tag is not "hard";
--           it is a bystander on other people's hard questions. Three cheap
--           measures, per tag: how often it is the first tag, its acceptance
--           rate when first versus later, and how many distinct other tags it
--           travels with.
-- Source:   so_analysis.tag_funnel, question_cohort, ranking_params
-- Grain:    one row per tag in the two ten-tag lists, plus one pooled row for
--           each list and one for every other eligible tag
-- Cost:     see results/run_log.md
--
-- Tag order is the order the asker typed them, which is the closest thing the
-- data has to "what the question is about". It is a heuristic, not a label.

WITH params AS (
  SELECT
    r.min_questions
  FROM `so_analysis.ranking_params` AS r
),

ranked AS (
  SELECT
    t.tag,
    t.n_questions,
    t.n_as_first_tag,
    t.n_accepted,
    t.n_accepted_as_first_tag,
    ROW_NUMBER() OVER (ORDER BY t.acceptance_wilson_lower DESC, t.tag) AS rank_high,
    ROW_NUMBER() OVER (ORDER BY t.acceptance_wilson_upper ASC, t.tag) AS rank_low
  FROM `so_analysis.tag_funnel` AS t
  CROSS JOIN params AS p
  WHERE t.cohort_region = 'current_year'
    AND t.n_questions >= p.min_questions
),

listed AS (
  SELECT
    r.tag,
    r.n_questions,
    r.n_as_first_tag,
    r.n_accepted,
    r.n_accepted_as_first_tag,
    CASE
      WHEN r.rank_high <= 10 THEN 'highest_approval'
      WHEN r.rank_low <= 10 THEN 'lowest_approval'
      ELSE 'other_eligible'
    END AS list,
    IF(r.rank_high <= 10, r.rank_high, r.rank_low) AS rank_in_list
  FROM ranked AS r
),

question_tags AS (
  SELECT
    c.question_id,
    c.n_tags,
    tag
  FROM `so_analysis.question_cohort` AS c
  CROSS JOIN UNNEST(SPLIT(c.tags, '|')) AS tag
  WHERE c.cohort_region = 'current_year'
    AND tag != ''
),

company AS (
  SELECT
    a.tag,
    COUNTIF(a.n_tags = 1) AS n_only_tag,
    COUNT(DISTINCT b.tag) AS distinct_co_tags
  FROM question_tags AS a
  LEFT JOIN question_tags AS b
    ON b.question_id = a.question_id
   AND b.tag != a.tag
  GROUP BY a.tag
),

per_tag AS (
  SELECT
    l.list,
    l.rank_in_list,
    l.tag,
    l.n_questions,
    l.n_as_first_tag,
    l.n_accepted,
    l.n_accepted_as_first_tag,
    co.n_only_tag,
    co.distinct_co_tags
  FROM listed AS l
  INNER JOIN company AS co
    ON co.tag = l.tag
),

pooled AS (
  SELECT
    pt.list,
    0 AS rank_in_list,
    CONCAT('(all ', COUNT(*), ' tags in this list)') AS tag,
    SUM(pt.n_questions) AS n_questions,
    SUM(pt.n_as_first_tag) AS n_as_first_tag,
    SUM(pt.n_accepted) AS n_accepted,
    SUM(pt.n_accepted_as_first_tag) AS n_accepted_as_first_tag,
    SUM(pt.n_only_tag) AS n_only_tag,
    SUM(pt.distinct_co_tags) AS distinct_co_tags
  FROM per_tag AS pt
  GROUP BY pt.list
),

rows_out AS (
  SELECT
    pt.list, pt.rank_in_list, pt.tag, pt.n_questions, pt.n_as_first_tag, pt.n_accepted,
    pt.n_accepted_as_first_tag, pt.n_only_tag, pt.distinct_co_tags
  FROM per_tag AS pt
  WHERE pt.list != 'other_eligible'
  UNION ALL
  SELECT
    po.list, po.rank_in_list, po.tag, po.n_questions, po.n_as_first_tag, po.n_accepted,
    po.n_accepted_as_first_tag, po.n_only_tag, po.distinct_co_tags
  FROM pooled AS po
)

SELECT
  ro.list,
  ro.rank_in_list,
  ro.tag,
  ro.n_questions,
  ROUND(SAFE_DIVIDE(ro.n_as_first_tag, ro.n_questions), 4) AS first_tag_share,
  ROUND(SAFE_DIVIDE(ro.n_only_tag, ro.n_questions), 4) AS only_tag_share,
  ROUND(SAFE_DIVIDE(ro.n_accepted_as_first_tag, ro.n_as_first_tag), 4) AS acceptance_rate_as_first_tag,
  ROUND(SAFE_DIVIDE(ro.n_accepted - ro.n_accepted_as_first_tag, ro.n_questions - ro.n_as_first_tag), 4) AS acceptance_rate_as_later_tag,
  ROUND(SAFE_DIVIDE(ro.distinct_co_tags * 100, ro.n_questions), 1) AS distinct_co_tags_per_100_questions
FROM rows_out AS ro
ORDER BY ro.list, ro.rank_in_list, ro.tag
