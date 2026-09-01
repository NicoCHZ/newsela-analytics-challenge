# Stack Overflow post analysis

Nicolás Chirino. An analysis of `bigquery-public-data.stackoverflow`.

Every number below can be traced: the query that produced it is in `sql/`, its
output is committed in `results/`, and the two share a name. You can check the
figures without a Google Cloud project. `results/run_log.md` records what each
query cost and the date it ran.

---

## Summary

### A caveat that changes the question

The prompt asks about "the current year". This dataset received its last question
on 25 September 2022 and has not been refreshed since. I therefore read "current
year" as current relative to the data, and analyse 1,125,763 questions asked
between 1 January and 26 August 2022: the year, up to the point where every
question has had the same 30 days in which to be answered and accepted. Every
boundary comes from the data (`sql/01_cohort/10_build_params.sql`), so the scripts
still do the right thing if the source is ever reloaded.

### F1. The tags with the highest and lowest rate of accepted answers

Ranked by a 95% confidence bound among the 470 tags with enough questions to pin
their rate to within 3 points, in the order the query ranks them. Highest is
ordered by the lower bound (the rate I am confident a tag is at least at);
lowest by the upper bound. That is why `pandas-groupby` (60.2%) sits below
`regex` (59.8%): regex has a tighter interval.

| Highest | n | accepted | 95% CI | | Lowest | n | accepted | 95% CI |
|---|---:|---:|---|---|---|---:|---:|---|
| `awk` | 1,122 | 66.4% | 63.6-69.1 | | `google-chrome-extension` | 1,792 | 11.7% | 10.3-13.3 |
| `dplyr` | 3,654 | 63.6% | 62.1-65.2 | | `browser` | 1,069 | 11.6% | 9.8-13.7 |
| `sed` | 944 | 62.2% | 59.1-65.2 | | `webview` | 896 | 11.6% | 9.7-13.9 |
| `tidyverse` | 1,298 | 61.6% | 59.0-64.2 | | `sharepoint` | 1,140 | 12.5% | 10.8-14.6 |
| `regex` | 6,262 | 59.8% | 58.6-61.0 | | `google-chrome` | 2,842 | 13.5% | 12.3-14.8 |
| `pandas-groupby` | 997 | 60.2% | 57.1-63.2 | | `firebase-cloud-messaging` | 978 | 13.3% | 11.3-15.6 |
| `beautifulsoup` | 2,295 | 55.6% | 53.6-57.6 | | `proxy` | 1,057 | 13.5% | 11.6-15.7 |
| `group-by` | 1,674 | 55.6% | 53.2-57.9 | | `websocket` | 2,251 | 14.7% | 13.3-16.2 |
| `google-sheets-formula` | 1,521 | 54.4% | 51.9-56.9 | | `webpack` | 3,191 | 15.2% | 14.0-16.5 |
| `dataframe` | 18,557 | 51.9% | 51.2-52.6 | | `ssl` | 2,277 | 15.2% | 13.7-16.7 |

The cohort baseline is 29.7%. The full list of 470 tags, with everything measured
about each one, is in `results/26_eligible_tags.csv`.

The shape is visible without any statistics. The top is made of self-contained
transformation problems: here is my input, here is the output I want, and a regex
either matches or it does not. The bottom is made of environment and integration
problems (browsers, platforms, proxies, TLS, build tooling), where the answer
depends on a machine nobody else can see. Two further columns say the same thing
more sharply. A top-list question draws 1.2 to 2.5 answers; a bottom-list question
draws 0.3 to 0.5. And when a bottom-list question does get an accepted answer, the
asker wrote it themselves 17% to 48% of the time (`webpack` 48%, `ssl` 42%, `proxy`
34%), against 1.5% to 2.8% at the top.

### F2. Acceptance is two rates multiplied together

| | asked → answered | answered → accepted | overall |
|---|---:|---:|---:|
| `awk` | 95.7% | 69.4% | 66.4% |
| `webpack` | 37.7% | 40.4% | 15.2% |
| cohort | 60.6% | 49.1% | 29.7% |

Across the 470 ranked tags, 58% of the spread in acceptance comes from whether
anyone answers at all and 42% from what happens once somebody has. The two stages
are correlated at 0.63, so they are not independent
(`results/25_summary_figures.csv`; the decomposition is exact in logarithms and
splits the covariance evenly). The second stage is more than "did the asker come
back": it mixes whether the answers were any good with whether anyone returned to
say so. Of the questions that had a community-upvoted answer within 30 days, 32%
were never accepted by anyone.

### F3. How much of the ranking is the method

I re-ran the ranking with one choice changed at a time
(`results/24_ranking_sensitivity.csv`). "Retained" is counted against the tags
still eligible under the variant, because raising a floor removes small tags by
definition, and that is not instability. The rank correlation is over the tags
eligible under both.

| change | eligible | rank corr. | top 10 retained | bottom 10 retained |
|---|---:|---:|---:|---:|
| lifetime outcomes instead of a 30-day window | 470 | 0.998 | 9 of 10 | 7 of 10 |
| Oct-Dec 2021 instead of 2022 (the previous year's un-purged months) | 181 | 0.966 | 4 of 4 | 3 of 3 |
| Jan-Sep 2021 (purged by the site; see Data quality) | 477 | 0.929 | 8 of 10 | 3 of 6 |
| looser floor (5-point precision, 321 questions) | 1,233 | 1.000 | 5 of 10 | 1 of 10 |
| stricter floor (2,000 questions) | 210 | 1.000 | 4 of 4 | 4 of 4 |
| rank on the observed rate instead of a bound | 470 | 0.997 | 9 of 10 | 8 of 10 |
| "approved" = an answer the community upvoted within 30 days | 470 | 0.943 | 5 of 10 | 5 of 10 |
| "rate of approved answers" per answer written, not per question | 470 | 0.526 | 0 of 10 | 1 of 10 |
| excluding answers the asker wrote themselves | 470 | 0.989 | 10 of 10 | 9 of 10 |
| excluding questions closed within the window | 470 | 0.998 | 9 of 10 | 9 of 10 |

The ranking itself barely moves: the correlation stays at 0.93 or above under
every change of window, floor, bound, year or moderation. What moves is which ten
names sit at the extremes when the floor admits smaller tags. With the looser
floor, nine of the bottom ten are displaced, by `facebook-graph-api`, `magento2`,
`cpanel`, `appium`, `elementor` and their like: the same kind of tag, with even
worse rates. Fifteen eligible tags have an upper bound below 17%, every one of
them a platform, integration or tooling tag, and the ten names above are the
lowest ten of that group. I would report the top as a list and the bottom as a
category.

`results/22_tag_rankings.csv` also ranks with no floor and no interval
(`naive_highest` / `naive_lowest`). The top of that list is `jstreer`: 10
questions, 100%. That is what the prompt's question looks like before any of the
choices above.

Only the definition changes the result. If "rate of approved answers" is read per
answer written (accepted answers over answers), `awk` and `sed` fall to the
bottom: they attract two or three answers per question, and only one can be
accepted. That reading measures competition among answerers rather than whether
askers get helped. I explain below why I chose the per-question reading.

### F4. For prompt 2, the strongest attribute is not about the question at all

It is the asker's own track record, measured only from events that had already
happened when they posted. People whose earlier questions were usually accepted
get accepted at 1.61 times the baseline; those with three or more settled prior
questions and no acceptance ever, at 0.52 times. Of the post itself, the strongest
attributes are code blocks (none, 0.66; two or three, 1.18) and stating what
result you expected (1.27, and 1.11 on being answered at all). Both survive with
the topic held constant (89% and 67% of the gap, respectively).

### Implications, as hypotheses

If I were advising the site, I would test these. The submission form could ask
for the expected result and a code block, since both go with better outcomes
inside every topic. A reminder to askers sitting on an upvoted, unaccepted answer
would target the 32% of questions that had an upvoted answer and were never
accepted. And since accepted answers in the bottom tier are often the asker's own
(`webpack` 48%, `ssl` 42%), those questions may need a different support path
(diagnostics, environment capture) rather than more answerers. Each of these
would need an experiment; none is a finding of this analysis.

---

## Reading the prompt

The prompt leaves five things open. Here is how I read each one, and what changes
under the other reading.

| phrase | reading used | alternative | what changes |
|---|---|---|---|
| "approved answers" | the asker accepted an answer (the green check) | an answer the community upvoted | 5 of the top 10 change (`haskell`, `julia`, `c++20` enter); rank correlation 0.94 |
| "rate of approved answers" | per question: share of questions with an accepted answer | per answer: accepted answers over answers written | the ranking inverts (correlation 0.53); see F3 |
| "the current year" | 2022 to 26 August, the last year in the data | the trailing twelve months, or the previous full year | the previous year is a survivor population (see Data quality); the trailing twelve months would straddle the boundary |
| "lead to" | association; nothing here identifies a cause | none | see "The metric" below |
| "qualities on a post" | attributes of the post, plus attributes of the poster knowable at post time | the post alone | the asker's record is the strongest attribute, and it is labelled as the poster's rather than the post's |

---

## Prompt 1

### The metric

Stack Overflow has no "approved" answer. The closest thing is the green check the
asker puts on one answer, and that is what I measure (`accepted_answer_id`, dated
through the acceptance vote in the votes table; every accepted question in the
cohort has one). This is one person's judgement, not the community's. Among
accepted questions that had a real choice to make, meaning more than one answer,
15.0% accepted something other than the highest-scored answer, and 12.4% of
accepted answers were written by the asker themselves.

The prompt asks which tags lead to higher approval. Tags are chosen by the asker
and describe what the question already is. You cannot add `regex` to a Kubernetes
question and see what happens. The numbers above are associations.

### 1a. Competing explanations

Three, framed so the data can tell them apart. Each predicts both funnel stages
low in the bottom tags, for different reasons, so the funnel alone cannot separate
them. The discriminating tests are the last two rows.

| | H1: the problem is tractable | H2: the people are different | H3: the tag is a bystander |
|---|---|---|---|
| mechanism | some topics produce self-contained questions with a verifiable answer; others depend on an environment nobody can reproduce | acceptance requires the asker to return; some tags attract one-time askers who never do | low tags are generic labels (`browser`, `proxy`) added to questions that are really about something else, so nobody who follows the tag can help |
| why answering is low | nobody can reproduce the problem | novices write questions that get answered less | the question is not about the tag |
| why acceptance given an answer is low | answers are plausible but unverifiable | the asker never comes back | same as H1 |
| same person across both kinds of tag | gap persists | gap collapses | gap persists |
| tag first vs tag trailing | no difference | no difference | the tag does fine when it leads |

### 1b. Why the low tags are low

The bottom tags fail at both stages: `webpack` gets an answer 37.7% of the time
against a 60.6% baseline, and converts at 40.4% against 49.1%. The funnel table
(`results/22_tag_rankings.csv`) adds three things.

Moderation does not explain it. I built the closure and duplicate events for
every question (`sql/01_cohort/14_build_question_moderation.sql`) expecting the
bottom tags to be full of questions closed within the hour. They are not. Apart
from `google-chrome-extension` (14% closed, 14% linked as duplicates), the bottom
tags are closed 0.5% to 4% of the time. The top tags are closed more (`regex` 11%,
`sed` 11%, `awk` 10%, almost all as duplicates) and still get accepted. Excluding
closed questions changes nothing (F3).

A shortage of people does not explain it either. Distinct answerers per hundred
questions are similar at both ends (17 to 56 at the top, 23 to 40 at the bottom).
What differs is how often anyone answers at all, 0.3 to 0.5 answers per question
at the bottom against 1.2 to 2.5 at the top, and who resolves it: the asker
themselves, 17% to 48% of the time.

The bottom tags are also slower, and the window costs them slightly more. The
30-day window captures 97% to 98% of the top tags' eventual acceptances and 84% to
91% of the bottom tags'. Measuring over the questions' whole life moves three
bottom names and leaves the tier intact (F3).

Browser and platform questions depend on a version, an extension set and an OS
the answerer cannot see, so the same answer is right in one environment and wrong
in another. The person who can finally see the problem is the asker, which is why
they end up answering it. That is H1. The self-answer share is the clearest mark
of it in this data.

### 1c. Testing H2 and H3, and what happened

I pick H1 (the problem is tractable). The tests below are what I ran to try to
kill it, by checking the two alternatives that would look the same in the funnel.

#### Holding the person constant

If tag approval is largely a measure of user retention wearing a topic as a
costume, the gap should collapse when the same person asks in both kinds of tag.
The test (`sql/02_tag_approval/23_within_asker_test.sql`) picks the 50 highest and
50 lowest tags on half the questions and measures on the other half, so choosing
the extremes does not reward its own noise. It weights each person's own
difference by how many questions they have on each side, which makes it
comparable with the population gap:

| comparison | gap |
|---|---:|
| between tag groups, whole evaluation half (130,839 questions) | 29.8 pp |
| same, restricted to the 2,766 people who ask in both | 29.7 pp |
| within the same person | 29.1 pp (SE 1.0) |
| within the same person, at the answering stage | 29.4 pp |
| within the same person, at the acceptance-given-answered stage | 20.4 pp |
| within the same person, people with at least two questions on each side (262) | 30.1 pp |

The gap survives intact. The same human being is answered 29 points less often in
the low tags and, once answered, accepts 20 points less often. On this evidence
the composition version of H2 (different people in different tags) is not
supported among repeat askers. The limit of the test is that people who ask across
both worlds are more experienced than average by construction, so it says little
about the one-time askers H2 is really about. It also cannot separate "the problem
was not solvable" from "the answer arrived too late for this person to care";
the two would look identical here.

#### Does the tag do better when it leads?

No (`results/33_tag_position.csv`). The bottom tags are more often the first tag
on their questions than the top tags are (19% against 10%), and they do worse
when they lead: 11.4% accepted as the first tag against 14.3% when trailing. What
is true is that they keep very mixed company, 51 distinct co-tags per hundred
questions against 17 at the top, which fits H1's picture of integration problems
spanning several technologies better than the bystander story. H3 is rejected as
stated.

#### What I would still need

The users table has no last-seen date, so I cannot tell whether the asker
returned to the site at all after posting. Deleted questions are omitted entirely.
The remaining test I would want is a nudge experiment: prompt askers sitting on
an upvoted unaccepted answer, and see whether acceptance rises evenly across tags
(H2) or only where the answer was verifiable (H1).

---

## Prompt 2: qualities of a post

The classification matters more than the ranking. Every attribute falls into one
of two groups, and only one of them can support advice. Attributes known at post
time are true the moment you hit submit, so a person can act on them. Post hoc
attributes accumulate afterwards: `score`, `view_count`, `comment_count`, whether
the account was later deleted. These correlate with the outcome and explain
nothing.

The table shows selected results; the full table is in
`results/31_post_quality_rates.csv`. Lift is relative to the cohort baseline,
`share` is the fraction of questions the bucket covers, and the last column is how
much of the effect survives when questions with and without the attribute are
compared inside the same tag (`results/32_within_tag_lifts.csv`). A large lift on
a rare attribute is a curiosity, not a lever.

| attribute (known at post time) | bucket | share | answer lift | acceptance lift | survives within tag |
|---|---|---:|---:|---:|---:|
| asker's prior acceptance rate (3 or more settled prior questions) | never accepted before | 3% | 0.92 | 0.52 | |
| | most of the time | 10% | 1.15 | 1.61 | |
| asker's prior questions | none, first question ever | 26% | 0.92 | 0.73 | 100% |
| | 100 or more | 7% | 1.09 | 1.31 | |
| asker's prior answers written | none | 54% | 0.97 | 0.86 | |
| | 100 or more | 3% | 1.11 | 1.33 | |
| account age at post | same day as signup | 13% | 0.91 | 0.70 | 100% |
| code blocks in body | none | 25% | 0.84 | 0.66 | 89% |
| | 2-3 | 33% | 1.08 | 1.18 | |
| inline code spans | none | 70% | 0.97 | 0.91 | |
| | 10 or more | 2% | 1.08 | 1.31 | |
| body states the expected result | yes | 7% | 1.11 | 1.27 | 67% |
| body says what was tried | yes | 15% | 1.02 | 1.07 | 80% |
| body text (tags stripped) | under 300 chars | 10% | 0.95 | 0.73 | 91% |
| | 700-1,499 | 32% | 1.04 | 1.09 | |
| | 3,000 or more | 12% | 0.94 | 0.96 | 66% |
| title form | "how ..." | 22% | 1.06 | 1.06 | |
| | "why ..." | 3% | 1.05 | 1.11 | |
| | problem report ("... not working", "... error") | 15% | 0.88 | 0.78 | |
| title ends with "?" | yes | 23% | 1.05 | 1.07 | |
| title contains "urgent" / "help me" | yes | 0.06% | 0.99 | 0.73 | |
| body contains an error message or stack trace | yes | 12% | 0.93 | 0.90 | 69% |
| body contains an image | yes | 12% | 1.03 | 1.09 | 83% |
| body contains a link (other than an image) | yes | 20% | 0.93 | 0.96 | 48% |
| number of tags | 2 | 25% | 1.03 | 1.05 | |
| | 5 | 16% | 0.96 | 0.95 | |
| narrowest tag on the question | under 1,000 questions this year | 64% | 0.93 | 0.91 | |
| | only mega-tags (100,000+) | 2% | 1.24 | 1.26 | |
| posting time (UTC) | 20:00-23:59 | 13% | 1.03 | 1.06 | |
| | 04:00-07:59 | 13% | 0.99 | 0.95 | |
| posting day | Saturday or Sunday | 18% | 1.04 | 1.07 | |

Saying what you expected is the most actionable thing in the table. Seven percent
of questions state an expected output or result. They are answered 11% more often
and accepted 27% more often, two thirds of that survives with the topic fixed, and
the direction holds in 257 of the 293 tags where it can be tested. Saying what you
tried helps less than the site's own guidance would suggest (1.07). Neither is a
large share of questions, which is what makes them levers rather than
descriptions.

Body length is an inverted U. Measured on the text with the HTML stripped, so
that markup and image links do not count as length, under 300 characters scores
0.73, the peak is 700 to 1,499 at 1.09, and past 3,000 it falls back to 0.96. Title
length has a different shape: flat until 85 characters, then a fall to 0.90.

A title that reports a problem does worse than a title that asks a question.
Titles of the form "X not working" or "error doing Y" are 15% of the cohort and
are answered 12% and accepted 22% less often than average; "how" and "why" titles
do modestly better. This is the closest thing here to a writing rule.

Pasting an error message goes with lower acceptance (0.90), not higher, which is
the opposite of what I expected. The detector is anchored on what runtime output
looks like (a Python traceback, a JVM stack frame, `SomethingError:`, a compiler
`error C1234:`) rather than on the word "exception", which every try/catch block
contains. In the fixed sample of fifty matches in
`results/42_error_signature_sample.csv`, 42 are runtime output and 8 are code that
handles or names errors. With the topic held constant, 69% of the gap survives,
though the direction is not universal: error text goes with worse acceptance in 222
tags and better in 151. My reading is that an error message marks a question the
asker could not diagnose themselves, and those are the ones nobody else can
diagnose either. A modest, uneven effect, not a law.

Niche tags do not help. I expected a question carrying a small, specific tag to
reach the few people who follow it. The opposite holds: questions whose most
specific tag has under a thousand questions a year are accepted 9% less often
than average, and questions carrying only mega-tags 26% more. Popular tags have
answerers watching; niche ones do not.

Question comment count has no real relationship with either outcome (every
bucket between 0.92 and 1.06). I had expected comments to signal an unclear
question. They do not, and I am reporting that rather than dropping it. Posting
time matters a little: late evening UTC and weekends do 5% to 7% better on
acceptance, and posting time is the cheapest thing on the list to act on.

I deliberately excluded `users.reputation`. It is a snapshot taken when the dump
was built in late 2022, not the asker's reputation on the day they posted, and
using it to explain a January 2022 outcome pours ten months of future information
into a predictor. I used account age, prior questions, prior answers written and
prior acceptance instead, all computed strictly from what preceded the question.
"Preceded" is enforced on the event, not the question: a prior question counts as
accepted only if the acceptance vote is dated before the new question was asked.
Reading acceptance from the question's final state instead would let the classic
"come back, accept the old answers, ask the new one" session leak in.

---

## Data quality and validation

`sql/04_validation/40_data_quality_checks.sql` returns 25 assertions with an
expectation attached to each (`results/40_data_quality_checks.csv`). Of the 17
blocking checks, 14 pass and 3 fail. The 8 informational ones are the interesting
part.

| check | result | what I did |
|---|---|---|
| days since the newest question | FAIL (see the run date in `run_log.md`) | redefined the analysis window from the data; this is what a freshness assertion is for, and in a live pipeline it would have paged someone in December 2022 |
| accepted answer predates its own question | 1 row, FAIL | a merged or migrated post; one row in 1.1M, left in |
| asker account created after the question | 12 rows, FAIL | account merges; the age feature treats them as negative and they fall out of its buckets |
| every accepted question has an acceptance vote | 0 missing | this is what lets acceptance be dated, and it is asserted as a row rather than assumed |
| newest answer and newest acceptance vote vs the question snapshot | 0 days | all tables were cut on the same day, so nothing in the window is censored by a table ending early |
| acceptance votes with a time other than midnight | 0 | the column is date-only; all timing here is in whole calendar days |
| accepted answer resolves, belongs to the right question; duplicate ids, null tags, >5 tags, empty bodies | 0 | none needed |
| `answer_count` vs answers actually present | 0 disagree | the counter and the dump both exclude deleted answers |
| asker's account deleted after posting | 9,883, all with a display name | reclassified as post hoc, see below |
| tags not in the site's tag table | 0 | none needed |
| the deletion boundary: answer-rate step a year before the snapshot | 13 points | see below |
| the deletion boundary: negative-score questions still unanswered | 936 of 81,317 | see below |

### The site deletes the questions that would have failed

Stack Overflow automatically removes questions that are a year old, unanswered
and at zero or negative score (and closed unanswered questions much sooner), and
the public dump excludes deleted posts. The pattern is in
`results/02_question_volume_by_period.csv`. The monthly answer rate is 79.6% in
August 2021, 75.7% in September and 66.8% in October: a 13-point step at exactly
365 days before the snapshot of 25 September 2022, flat on both sides. The share
of questions that are still unanswered with a non-positive score, the population
the rule removes, is 12.5% in August 2021 and 26.6% in October 2021. This has
three consequences.

The previous year is not a control. Its January to September months are a
survivor population, purged of exactly the questions that make a tag look bad, and
unevenly across tags. The sensitivity table keeps that variant, labelled, to show
what it does (bottom-ten retention 3 of 6, the worst of any variant). The clean
out-of-window comparison is October to December 2021, the previous year's
un-purged months.

A fall in answer rates from about 80% to about 60% over 2021 is mostly this
artefact. The surviving rows cannot say how much real decline sits underneath.

Questions with a negative score are answered 98.5% of the time, the highest of any
bucket in the analysis. The likely reason is that negative-score questions without
answers were deleted, not that downvotes attract answers. Their conversion from
answered to accepted (40%) is the lowest of any score bucket, which is what
survivorship predicts. Within the 2022 cohort the deletion rules act uniformly
(every question was old enough for the closure rule and too young for the year
rule), so the ranking is consistent, but every rate in this README is an upper
bound on the live site's.

### `votes.creation_date` is date-only

Every acceptance vote sits at exactly midnight. Compared against a question's
full timestamp, every same-day acceptance (43% of them) would appear to have
happened before the question was asked. All timing here is therefore computed in
whole calendar days, which is the real resolution of the data.

### A null `owner_user_id` is not an anonymous asker

It looks like one, and as a post-time attribute it showed a 43% acceptance rate
against a 30% baseline, which was implausible enough to check. Stack Overflow
keeps `owner_display_name` and drops the id when an account is deleted, and all
9,883 such rows in the cohort have a display name (the check above). It records
an event in the future relative to the post, so it belongs with `score` and
`view_count` rather than with title length, and it is excluded from every
asker-history bucket rather than counted as "no history".

---

## Assumptions, limitations, confidence

### Assumptions

"Approved" means accepted by the asker; the other readings are quantified in F3.
"Current year" means 2022 through 26 August. Outcomes are measured within 30 days
of asking, because 89% of all eventual acceptances happen inside that window and
93% within 90, measured on the fully matured 2019 cohort
(`results/41_acceptance_timing.csv`). A tag qualifies for ranking at 892
questions, the smallest sample that pins its rate to within 3 points at 95%
confidence given the cohort's own base rate. That keeps 470 of 41,411 tags,
covering 66% of all tag assignments (`results/25_summary_figures.csv`).
Timestamps are UTC.

### Limitations

These are in the order I would want a reviewer to weigh them.

Deleted posts are absent, and not at random. The site removes unanswered
low-quality questions, so every rate here is an upper bound, the inflation is
larger in beginner-heavy tags, and the true gap between the top and bottom lists
is probably wider than measured. Within the cohort the rules act uniformly; across
the year boundary they do not, which is why the previous year is not used as a
control.

Tags are not independent. A question carries up to five and is counted under
each, so these are marginal rates. `dplyr` and `tidyverse` are largely the same
questions. The ranking should be read as roughly a dozen clusters, not as 20
independent findings.

The definition is the largest source of uncertainty. Per question or per answer,
accepted or upvoted: F3 shows that the first of these inverts the ranking and the
second reshuffles half the top ten. With hundreds of thousands of questions, the
statistical intervals on the two lists are 1.5 to 3 points per tag. The
definitional uncertainty is an order of magnitude larger, and tighter intervals
would be false precision about a question that was never fully specified.

Acceptance is one person's decision. It measures asker follow-through as well as
answer quality; 32% of questions with an upvoted answer were never accepted.

The text features are regular expressions. The error detector is 84% precise on
a fixed sample; "expected result" and "what I tried" match phrasings, not
intentions; body length ignores HTML entities. Each is good enough to rank
buckets and not good enough to score an individual post.

### What would change my mind

- If the within-asker gap had collapsed instead of holding at 29 points, I would
  have abandoned the tag framing and treated this as user segmentation.
- If the bottom tags had turned out to be 30% closed as duplicates, I would have
  called the bottom list a moderation artefact. They are 0.5% to 4% closed; only
  `google-chrome-extension` is policed, and it stays at the bottom without it.
- If a dataset including deleted questions cut the top tags' advantage by more
  than half, I would conclude I had been measuring deletion policy.
- If the un-purged months of 2021 had ranked the common tags differently
  (correlation 0.97, every eligible name retained), I would have treated the
  lists as noise.

---

## Prompt 3: with more time

### Move the unit of analysis from the question to the answer

Everything here asks which questions get resolved. The complementary question is
which answers win: does answerer tenure, response latency, length or code content
predict acceptance, holding the question constant? Comparing answers to the same
question controls for question quality perfectly, which no design in this
submission does. That is what you would need to intervene, with advice to
answerers rather than to askers, and it would test the error-message finding
directly by checking whether error-bearing questions attract answers that are
plausible but unverifiable. The narrow answer columns are already materialized;
the cost is one more pass over the answer bodies (about 20 GB).

### Measure the deletion instead of bounding it

The public dump cannot show what was deleted, but the live site's API can. For a
sample of tags, count the question ids that exist in the dump against the id
range for the period; the gap is the purge. Done per tag, it turns "every rate is
an upper bound" into a corrected rate, and it would tell me whether the top tags'
advantage is as large on the live site as it is here. That is the one limitation
no amount of SQL on this dataset can address.

### A nudge experiment on the acceptance stage

Prompt askers who have had an upvoted, unaccepted answer for a week. If
acceptance rises evenly across tags, the second funnel stage is follow-through
(H2's mechanism, even if not its population). If it rises only where answers were
verifiable, it is answer quality (H1). This is the only design that separates the
two, and it is a product change rather than a query.

The prompt's literal question about the actual current year needs a newer dataset
than this one. Stack Exchange still publishes a data dump, under access terms that
changed in 2024. Loading it would make the comparison the interesting part,
including the arrival of LLM assistants, which sits entirely outside this
snapshot.

---

## Repository

```
sql/00_profiling/       freshness and physical layout; volume, outcomes and the deletion boundary by month
sql/01_cohort/          params derived from the data; the one pass over body; answers, vote dates,
                        moderation events; outcomes in a fixed window; cohort summary
sql/02_tag_approval/    prompt 1: derived floor, funnel, rankings, within-asker test, sensitivity,
                        summary figures, the full eligible list
sql/03_post_qualities/  prompt 2: leakage-free asker history, attribute rates, within-tag lifts,
                        the tag-position test
sql/04_validation/      data-quality assertions, acceptance timing, the error-detector sample
results/                committed outputs, plus run_log.md with the cost of each query
docs/sql-style.md       the SQL and cost conventions I held myself to
scripts/run_queries.sh  runs everything end to end, in dependency order, and regenerates results/
```

To reproduce, in your own project (requires the `bq` CLI and `jq`):

```bash
bq --location=US mk --dataset "$BQ_PROJECT:so_analysis"
BQ_PROJECT=your-project-id ./scripts/run_queries.sh
```

The runner checks that the dataset exists, runs the files in path order (which is
dependency order), writes each output atomically, and reads each query's cost back
from its own job. Running it twice on the same day produces byte-identical CSVs:
every ordering ends with a tie-breaker, and only the freshness check counts days.

### Cost

The whole analysis bills 55.9 GB, 5.5% of the BigQuery sandbox's monthly
allowance, and 36.6 GB of that is the single query that reads
`posts_questions.body`. These public tables are not partitioned or clustered
(`results/01_dataset_freshness.csv` checks the catalogue), so a `WHERE` on a date
reduces nothing; the only lever is which columns you touch. The strategy is to
read each source table once, narrow, and materialize, with `body` read exactly
once and every text feature derived in that pass, so that 13 of the 23 queries
read nothing but those tables, measured in megabytes. Closure and duplicate
events, which look expensive because `post_history` is 113 GB, cost 3.6 GB once
that table is read without its text column.
