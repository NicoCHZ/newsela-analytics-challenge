# Stack Overflow post analysis

Nicolás Chirino — analysis of `bigquery-public-data.stackoverflow`.

Every number below is reproducible: the query that produced it is in `sql/`, and
its output is committed in `results/` so you can check the figures without a
Google Cloud project. `results/run_log.md` records what each query cost.

---

## Summary

**A caveat that comes first, because it changes the question.** The prompt asks
about "the current year". This dataset received its last question on
**25 September 2022** and has not been refreshed since. Its newest row is 1,436
days old. I therefore read "current year" as *current relative to the data*, and
analyse **1,125,763 questions asked between 1 January and 26 August 2022** — 2022
up to the point where outcomes are fully observable. The window boundary is
computed from the data in every script, not hardcoded, so this all still works if
the source is ever reloaded.

**F1 — The tags with the highest and lowest rate of accepted answers.**

| Highest | n | accepted | 95% CI | | Lowest | n | accepted | 95% CI |
|---|---:|---:|---|---|---|---:|---:|---|
| `awk` | 1,122 | 66.4% | 63.6–69.1 | | `browser` | 1,069 | 11.6% | 9.8–13.7 |
| `dplyr` | 3,654 | 63.6% | 62.1–65.2 | | `webview` | 896 | 11.6% | 9.7–13.9 |
| `sed` | 944 | 62.2% | 59.1–65.2 | | `google-chrome-extension` | 1,792 | 11.7% | 10.3–13.3 |
| `tidyverse` | 1,298 | 61.6% | 59.0–64.2 | | `sharepoint` | 1,140 | 12.5% | 10.8–14.6 |
| `pandas-groupby` | 997 | 60.2% | 57.1–63.2 | | `firebase-cloud-messaging` | 978 | 13.3% | 11.3–15.6 |
| `regex` | 6,262 | 59.8% | 58.6–61.0 | | `google-chrome` | 2,842 | 13.5% | 12.3–14.8 |
| `beautifulsoup` | 2,295 | 55.6% | 53.6–57.6 | | `proxy` | 1,057 | 13.5% | 11.6–15.7 |
| `group-by` | 1,674 | 55.6% | 53.2–57.9 | | `websocket` | 2,251 | 14.7% | 13.3–16.2 |
| `google-sheets-formula` | 1,521 | 54.4% | 51.9–56.9 | | `webpack` | 3,191 | 15.2% | 14.0–16.5 |
| `dataframe` | 18,557 | 51.9% | 51.2–52.6 | | `ssl` | 2,277 | 15.2% | 13.7–16.7 |

Cohort baseline: 29.7%. **Confidence: high for the top list, moderate for the
bottom** — see the sensitivity table in F3.

The shape is legible without any statistics. The top is **self-contained
transformation problems**: here is my input, here is the output I want. A regex
either matches or it does not. The bottom is **environment and integration
problems**: browsers, platforms, proxies, TLS, build tooling — where the answer
depends on a machine nobody else can see.

**F2 — The headline metric is a compound of two very different things.** Splitting
it apart is the most useful thing in this analysis:

| | asked → answered | answered → accepted | overall |
|---|---:|---:|---:|
| `awk` | 95.7% | 69.4% | 66.4% |
| `webpack` | 37.7% | 40.4% | 15.2% |
| cohort | 60.6% | 49.1% | 29.7% |

Decomposing the variance across the 473 ranked tags, **58% of the spread comes
from whether anyone answers at all and 42% from whether the asker comes back to
accept** (the two stages correlate at 0.63, so they are not independent). A tag
can be low for two completely different reasons, and a single "approval rate"
cannot tell you which.

**F3 — I can break most of my own bottom list.** Re-running the ranking with one
methodological choice changed at a time (`results/23_ranking_sensitivity.csv`):

| change | top 10 retained | bottom 10 retained |
|---|---:|---:|
| lifetime outcomes instead of a 30-day window | 9 | 7 |
| rank on observed rate instead of a confidence bound | 9 | 8 |
| 2021 instead of 2022 | 6 | 4 |
| volume floor 2,000 instead of 886 | 4 | 4 |
| volume floor 322 instead of 886 | 5 | **1** |

The top list is stable against how I measure. **Both lists are sensitive to the
volume floor, and the bottom list is barely stable at all** — drop the floor and
nine of ten tags change. I would report the top list to a stakeholder. I would
report the bottom list as a direction, not a list of names.

**F4 — For prompt 2, the strongest attribute known at post time is not about the
question at all.** It is the asker's own track record: people whose earlier
questions were usually accepted get accepted at **1.61× the baseline**, those who
had never had one accepted at **0.62×**. The strongest attribute of the post
itself is **code blocks** — none, 0.59×; nine or more, 1.34×.

---

## Prompt 1

### The metric

Stack Overflow has no "approved" answer. The closest thing is the green check the
**asker** puts on one answer, and that is what I measure (`accepted_answer_id`).
It is worth being explicit that this is one person's judgement, not the
community's. Among accepted questions that actually had a choice to make — more
than one answer — **15.0% accepted something other than the highest-scored
answer**, and 12.4% of accepted answers were written by the asker themselves.

**On "lead to".** The prompt asks which tags *lead to* higher approval. Nothing
here can support that. Tags are chosen by the asker and describe what the question
already is — you cannot add `regex` to a Kubernetes question and see what happens.
The counterfactual is not just unidentified, it is incoherent. Everything above is
association.

### 1a. Two competing explanations

These are framed to predict *different* things, so the data can tell them apart.

| | **H1 — the problem is tractable** | **H2 — the people are different** |
|---|---|---|
| mechanism | some topics produce self-contained questions with a verifiable answer; others depend on an environment nobody can reproduce | acceptance requires the asker to return; some tags attract one-time askers who never do |
| predicts: answer rate in low tags | low | normal |
| predicts: acceptance given answered | normal | low |
| predicts: same person across both kinds of tag | gap persists | gap collapses |

### 1b. Why the low tags are low

The bottom tags fail at **both** stages: `webpack` gets an answer 37.7% of the
time against a 60.6% baseline, *and* converts at 40.4% against 49.1%. Browser and
platform questions depend on a version, an extension set and an OS the answerer
cannot see, so the same answer is right in one environment and wrong in another,
and toolchain answers go stale faster than they get accepted. F2 says the
answerability stage is the larger effect, though not overwhelmingly.

### 1c. Testing H2, and what happened

H2 is the more interesting claim — if true, tag approval rate is largely a
measure of user retention wearing a topic as a costume. It is also partly
testable here: **hold the person constant and let only the topic vary.**

I took the 7,580 askers who posted in both a top-50 and a bottom-50 tag during the
window, and compared each person against themselves
(`sql/02_tag_approval/22_within_asker_test.sql`):

| comparison | gap |
|---|---:|
| between tag groups, whole population | 29.9 pp |
| same, restricted to people who ask in both | 31.0 pp |
| **within the same person** | **28.2 pp** (SE 0.6) |

**The gap survives.** 28 of 29.9 points remain when the same human being asks in
both kinds of tag. On this evidence H2 is not the main story — the difference
travels with the question, not the asker. That was not what I expected going in.

What I would still need: close reasons and dates (to separate "nobody answered"
from "closed as a duplicate"); whether the asker returned to the site at all;
deleted questions, which this dataset omits entirely; and ideally a nudge
experiment — prompt askers sitting on a good unaccepted answer, and see whether
acceptance rises evenly across tags (H2) or only where good answers already exist
(H1). The honest limit of my test is that people who ask
across both worlds are more experienced than average by construction, so it says
little about the one-time askers H2 is really about.

---

## Prompt 2 — qualities of a post

**The classification matters more than the ranking.** Every attribute falls into
one of two groups, and only one of them can support advice:

- **Known at post time** — true the moment you hit submit. Actionable.
- **Post hoc** — accumulates afterwards. `score`, `view_count`, `comment_count`.
  These correlate beautifully and explain nothing.

The clearest illustration is in the data: questions with a **negative** score have
the **highest answer rate of any bucket in this analysis — 98.5%**. Downvotes do
not attract answers. Attention produces both.

Selected results (full table in `results/31_post_quality_rates.csv`; lift is
relative to the cohort baseline, and `share` is what fraction of questions the
bucket covers — a large lift on a rare attribute is a curiosity, not a lever):

| attribute (known at post time) | bucket | share | answer lift | acceptance lift |
|---|---|---:|---:|---:|
| asker's prior acceptance rate | never accepted before | 11% | 0.92 | **0.62** |
| | usually accepted | 10% | 1.15 | **1.61** |
| code blocks in body | none | 20% | 0.81 | **0.59** |
| | 9 or more | 5% | 1.09 | **1.34** |
| asker's prior questions | none | 41% | 0.97 | 0.86 |
| | 100 or more | 6% | 1.09 | 1.29 |
| account age at post | same day as signup | 13% | 0.91 | 0.70 |
| body length | under 300 chars | 6% | 0.92 | 0.65 |
| | 1,500–2,999 chars | 24% | 1.02 | **1.09** |
| | 3,000+ chars | 14% | 0.95 | 1.00 |
| title ends with "?" | yes | 23% | 1.05 | 1.07 |
| title contains "urgent"/"help me" | yes | **0.06%** | 0.99 | 0.73 |
| body contains an error or stack trace | yes | 18% | 0.93 | 0.90 |
| number of tags | 2 | 25% | 1.03 | 1.05 |
| | 5 | 16% | 0.96 | 0.95 |

Three things worth pulling out.

**Body length is an inverted U.** Under 300 characters scores 0.65; the peak is
1,500–2,999 at 1.09; past 3,000 it falls back to 1.00. This is why I report
bucketed rates rather than correlation coefficients — a single coefficient would
have called this "no relationship". The same shape appears in title length.

**Pasting an error message is associated with *lower* acceptance (0.90), not
higher.** I expected the opposite: an error message reads like a specific,
reproducible problem. My first explanation was that error text merely marks the
environment-dependent topics that already rank badly in prompt 1 — in which case
the attribute would be telling us nothing the tag had not. That explanation is
mostly wrong. Comparing questions with and without error text *inside the same
tag* across 421 tags, the gap goes from 3.3 points to 2.7
(`sql/03_post_qualities/32_error_text_within_tag.sql`): **82% of it survives with
the topic held constant.** It is also not a universal rule — error text goes with
worse acceptance in 246 of those tags and better in 175. A modest real effect with
genuine heterogeneity, not a law.

**Question comment count has essentially no relationship with either outcome**
(every bucket between 0.92 and 1.06). I had expected comments to signal an unclear
question and predict worse outcomes. They do not, and I am reporting that rather
than dropping it.

Deliberately excluded: `users.reputation`. It is a snapshot taken when the dump
was built in late 2022, not the asker's reputation on the day they posted. Using
it to explain a January 2022 outcome pours ten months of future information into a
predictor. I used account age and prior-question history instead, both computed
strictly from what preceded the question, with a 90-day lag so that a prior
question's own outcome had time to settle.

---

## Data quality and validation

`sql/00_profiling/04_data_quality_checks.sql` returns 15 assertions with an
expectation attached to each (`results/04_data_quality_checks.csv`). Thirteen
pass. The two that do not are the interesting ones.

| check | result | what I did |
|---|---|---|
| days since the newest question | **1,436 — FAIL** | redefined the analysis window from the data; this is what a freshness assertion is for, and in a live pipeline it would have paged someone in December 2022 |
| accepted answer predates its own question | **1 row — FAIL** | question 72063568, accepted answer 18 days older. A merged or migrated post. One row in 2.75M; left in, noted here |
| accepted answer id resolves to a real answer | 0 orphans | — |
| accepted answer belongs to the right question | 0 | — |
| `answer_count` vs answers actually present | 2 rows disagree | the denormalised counter is trustworthy, which is unusual and worth knowing |
| duplicate ids, null tags, >5 tags, empty bodies | 0 | — |
| asker's account deleted after posting | 36,575 | reclassified as post-hoc, see below |

Two things surfaced during the work rather than from the checklist.

**`votes.creation_date` is date-only.** Every acceptance vote in the table sits at
exactly midnight. Compared against a question's full timestamp, 44% of same-day
acceptances appear to have happened *before* the question was asked. All timing
here is therefore computed in whole calendar days, which is the real resolution of
the data.

**A null `owner_user_id` is not an anonymous asker.** It looks like one, and as a
post-time attribute it showed a 44% acceptance rate against a 30% baseline —
implausible enough to check. Stack Overflow keeps `owner_display_name` and drops
the id when an **account is deleted**, and all 10,193 such rows in the 2022 cohort
have a display name. It records an event in the future relative to the post, so it
belongs with `score` and `view_count`, not with title length.

---

## Assumptions, limitations, confidence

**Assumptions.** "Approved" means accepted by the asker. "Current year" means 2022
through 26 August. Outcomes are measured within 30 days of asking — chosen because
89% of all eventual acceptances happen inside that window, and 93% within 90
(`results/03_acceptance_timing.csv`). A tag qualifies for ranking at 886 questions,
the smallest sample that pins its rate to ±3 points at 95% confidence given the
cohort's own base rate; that keeps 473 of 41,411 tags, covering 66% of all tag
assignments. Timestamps are UTC.

**Limitations, in the order I would want a reviewer to weigh them.**

*Deleted posts are absent.* Stack Overflow's dumps exclude them, and unanswered
low-quality questions are deleted disproportionately. **Every rate here is an
upper bound**, and the inflation is probably larger in beginner-heavy tags —
meaning the true gap between the top and bottom lists is likely wider than
measured. No amount of SQL on this dataset can correct it.

*Tags are not independent.* A question carries up to five and is counted under
each, so these are marginal rates. `dplyr` and `tidyverse` are largely the same
questions. The ranking should be read as roughly a dozen clusters, not 20
independent findings.

*Acceptance is one person's decision.* It measures asker follow-through as well as
answer quality. F2 quantifies how much: about 42% of the spread.

*Statistical precision is not the binding constraint.* At n in the millions the
intervals are ±1 point or less. Changing the volume floor moves the bottom list by
nine names out of ten. The uncertainty here is definitional, not statistical, and
reporting a tighter interval would be false precision about a question that was
never fully specified.

**What would change my mind.**

- If the within-asker gap had collapsed instead of holding at 28 points, I would
  have abandoned the tag framing and treated this as user segmentation.
- If a dataset including closed and deleted questions cut the top tags' advantage
  by more than half, I would conclude I had been measuring moderation policy.
- If the bottom-ten list did not reproduce on a non-overlapping time window, I
  would treat it as noise. It half-reproduces on 2021 (4 of 10), which is why I
  have labelled its confidence moderate rather than high.

---

## Prompt 3 — with more time

Two analyses, chosen because each resolves something I currently cannot answer.

**1. Separate "nobody answered" from "closed as a duplicate".** My bottom tags
fail mostly at the answering stage, and I cannot distinguish a genuinely hard
question from one that was closed as a duplicate within an hour — the second is a
moderation outcome, not a difficulty signal, and popular beginner-heavy tags
attract far more of them. `post_links` (link type 3) and `post_history` (type 10)
carry both, and `post_history` is the largest table in the dataset at 113 GB, so
this needs a deliberate one-pass extract rather than casual joins. It would tell
me whether tags like `google-chrome` are hard to answer or merely well-policed —
which changes the recommendation completely.

**2. Move the unit of analysis from the question to the answer.** Everything here
asks which questions get resolved. The complementary question is which *answers*
win: does answerer tenure, response latency, length or code content predict
acceptance, holding the question constant? Comparing answers to the *same*
question controls for question quality perfectly, which no design in this
submission does. That is what you would need to intervene — advice to answerers
rather than to askers — and it would also test the error-message finding above
directly, by checking whether error-bearing questions attract answers that are
plausible but unverifiable.

Also worth naming: the Stack Exchange data dump is still published and current
through 2026. Answering the prompt's literal question about the *actual* current
year means loading that instead, and the interesting part would be the comparison
— question volume and answer rates were already falling sharply before this
snapshot ends, and the arrival of LLM assistants sits entirely outside it.

---

## Repository

```
sql/00_profiling/       freshness, volume over time, acceptance timing, data quality
sql/01_cohort/          the analysis base (one pass over the body column) and outcomes
sql/02_tag_approval/    prompt 1: funnel, rankings, within-asker test, sensitivity
sql/03_post_qualities/  prompt 2: leakage-safe asker history, attribute rates
results/                committed outputs, plus run_log.md with cost per query
docs/sql-style.md       the SQL and cost conventions I held myself to
scripts/run_queries.sh  runs everything end to end and regenerates results/
```

To reproduce, in your own project:

```bash
bq --location=US mk --dataset "$BQ_PROJECT:so_analysis"
BQ_PROJECT=your-project-id ./scripts/run_queries.sh
```

**Cost.** The whole analysis bills **52.4 GB**, 5% of the BigQuery sandbox's
monthly allowance, and 36.7 GB of that is a single query. `posts_questions` is not
partitioned or clustered — I checked — so a `WHERE creation_date >= ...` filter
reduces nothing. In fact adding one to a bare `COUNT(*)` takes it from 0 bytes to
184 MB, because the count is answered from metadata until the filter forces a
column read. The only lever on this dataset is which columns you touch, so the
strategy is to read `body` exactly once, derive every text feature in that pass,
and have all eleven other queries read the narrow result instead.
