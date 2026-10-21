# career-ops review: what's worth borrowing

Reviewed 2026-10-22, against career-ops v1.37.0 (https://github.com/career-ops-hq/career-ops, MIT, about 76k stars and 14k forks, last pushed 2026-10-21). I cloned it into a scratch directory and only read it. Nothing in it was run or installed. File references below are relative to that repo unless they start with `engine/`, `app/` or `docs/`, which are ours.

## 1. What career-ops is

career-ops is a set of Markdown prompt files ("modes") plus about 150 small Node scripts. It runs inside a coding CLI such as Claude Code, Codex or Gemini. A single router skill (`.claude/skills/career-ops/SKILL.md`) sends a request to one of about 45 modes. It has three stated principles (`ARCHITECTURE.md`):

- **Local-first.**
- **Model-agnostic.**
- **Human in the loop: it never submits an application.**

All state lives in Markdown and TSV files the user owns (`data/applications.md`, `reports/NNN-*.md`, `cv.md`, `config/profile.yml`). SQLite is only a derived index.

### Workflow stages

| Stage | What it does | Where |
|---|---|---|
| Discovery | `scan.mjs` uses zero LLM tokens. It calls public, no-login ATS and board APIs through about 100 provider modules (Greenhouse, Lever, Ashby, **Workday CXS, SmartRecruiters, Workable, Recruitee, Zoho Recruit, BambooHR, Teamtailor, iCIMS, SuccessFactors, Oracle Cloud, Eightfold, Phenom**, HN, RemoteOK…). Login-only sources are deliberately kept out of core. `titles` mode suggests adjacent job titles from the CV. | `scan.mjs`, `providers/*.mjs`, `providers/ADDING_A_PROVIDER.md`, `modes/scan.md`, `modes/titles.md` |
| Liveness | A ladder of checks: public ATS API first (404/410 or a closed marker), then a browser check, then text patterns ("no longer accepting", in many languages). It is conservative, so "uncertain" is never treated as "expired". Evaluation is gated on it. | `liveness-api.mjs`, `liveness-core.mjs`, `liveness-browser.mjs`, `check-liveness.mjs`, `modes/oferta.md` § Liveness gate |
| Quick triage | A cheap go/no-go check that reads only a compact `_brief.md` instead of the full CV. | `modes/triage.md`, `modes/_brief.template.md` |
| Evaluation | The A–H report:<br>A role summary (geo-mismatch, work-auth tiers)<br>B requirement→evidence table<br>C level strategy<br>D compensation, with company-type reliability tiers<br>E CV customisation plan<br>F STAR+Reflection stories<br>G posting legitimacy<br>H draft answers<br>Then a Verdict, a Risk Summary and an Evidence-confidence table. The score is 1–5 across five dimensions (CV match, North Star, comp, culture, red flags). | `modes/oferta.md`, `modes/_shared.md` |
| Gates before evaluation | Blacklist, dealbreakers (must quote the JD sentence that breaks the rule), agency confirmation, and a bounded research budget (at most 5 web searches). | `modes/oferta.md` |
| Legitimacy / scam | Block G covers freshness, JD quality, layoffs, reposts and classification risk. Conditional signals 8–22 include **candidate-paid fees**, agency licensing, unpaid placement, pay-range width and AI-screening disclosure. All are warn-only and never change the score. | `modes/oferta-signals/*.md`, `detect-reposts.mjs`, `templates/*.yml` |
| CV tailoring | An HTML/LaTeX CV is generated for each job and goes through a **mechanical fact gate** (every number, tool or employer must appear in `cv.md` or `article-digest.md`). Optional extras: an adversarial "hiring-manager audit" subagent and an ATS parseability lint. | `modes/pdf.md`, `verify-cv-facts.mjs`, `modes/pdf/hm-audit.md`, `verify-ats.mjs`, `keyword-match.mjs`, `jd-skill-gap.mjs` |
| Cover letters / writing | Cover letters, plus a "voice DNA" anti-AI-slop guide (no em dashes, varied rhythm, banned phrases) and a recruiter-side risk map. | `modes/cover.md`, `voice-dna.template.md`, `modes/_writing.md`, `modes/heuristics/recruiter-side.md` |
| Apply | **Assist only.** It fills forms in a Playwright browser and stops before Submit. Pre-scans: knock-out questions, immigration-status screening, prohibited questions, a cross-channel duplicate check (agency vs direct). | `modes/apply.md`, `apply-scope.mjs` |
| Tracking | A Markdown tracker plus scripts to merge, dedup, normalise statuses, flag postings closing soon and measure funnel velocity. | `tracker*.mjs`, `closing-soon.mjs`, `funnel-velocity.mjs`, `stats.mjs` |
| Follow-up / replies | A follow-up cadence (7 days after applying, 3 after a reply, 1 after an interview). `reply-watch` classifies employer emails (Interview, Rejected, Offer, Auto-confirmation, Noise…) and *proposes* status changes for the user to confirm. | `modes/followup.md`, `followup-cadence.mjs`, `modes/reply-watch.md`, `reply-watch.mjs`, `paste-reply.mjs` |
| Outreach | LinkedIn connection-note drafts (recruiter persona vs hiring-manager persona). A saved-contacts lookup checks for a warm lead before any cold search. A **LinkedIn `Connections.csv` export joined against target companies** finds warm intros. | `modes/contacto.md`, `contact-lookup.mjs`, `linkedin-join.mjs` |
| Interview | Company-specific prep, a practice interviewer that asks one question at a time, a post-interview debrief that updates the question and story banks, a red-flag detector, a weekly digest, and a story-bank matcher for behavioural ATS questions. Retracted claims are a hard gate. | `modes/interview-prep.md`, `modes/interview/{plan,practice,debrief}.md`, `match-star.mjs`, `story-provenance-check.mjs`, `weekly-digest.mjs` |
| Offer / negotiation | A contract "reading companion" that never gives verdicts and sends legal questions to a lawyer list. Salary records track desired, advertised, actual and stated pay. Negotiation talking points are tied to verified achievements. | `modes/offer-prep.md`, `salary-gap.mjs`, `negotiation-roi.mjs` |
| Learning loop | `patterns` (rejection patterns, once there are 5 or more applications sent). `calibrate` (do scores predict interviews and offers, with honest small-n floors; advisory only). `upskill` / `skip-blockers` (gaps that keep appearing in skipped roles). `retro` (user corrections become accepted rules). | `modes/patterns.md`, `analyze-patterns.mjs`, `modes/calibrate.md`, `calibrate.mjs`, `upskill.mjs`, `skip-blockers.mjs`, `modes/retro.md`, `learn.mjs` |
| Evals | A frozen golden set of 10 synthetic JDs used to check whether a cheaper model agrees with the reference score and archetype. | `evals/README.md`, `evals/golden/*.json`, `eval-golden.mjs` |
| i18n | Native mode translations into 17 languages, including Hindi (`modes/hi/`). The Hindi shared file has India-specific comp notes: CTC vs in-hand pay, notice periods and buyout, variable pay. | `modes/hi/_shared.md`, `modes/hi/naukri.md` |

### Techniques worth noticing

- **The fact gate is code, not a prompt** (`verify-cv-facts.mjs`). It has a provenance tier for the story bank: a number in `story-bank.md` doesn't count as fact unless `cv.md` backs it (`story-provenance-check.mjs`).
- **Two-pass requirement table** (`modes/oferta.md` § Block B). The model rates each requirement's importance from the JD alone *before* it reads the CV. Order is the mechanism that stops the model inflating importance for things the candidate has.
- **Evidence confidence separate from score** (`modes/_shared.md` § Evidence confidence). Each dimension is marked supported, partial or unknown, which gives a High/Medium/Low confidence, plus up to 3 "checks that could change the decision".
- **"Not evaluated" is a real state** in the Risk Summary, so an all-green summary can be trusted.
- **Untrusted-content discipline everywhere.** JD text, emails and transcripts are data. Imperative text aimed at an AI is quoted as an anomaly, not obeyed.
- **Conservative liveness.** A false "expired" is treated as worse than no check, so the Ashby check confirms the posting is still on the org board and is not fooled by a JS-rendered empty page (`liveness-api.mjs` header).
- **Repost detection that avoids false positives** (`detect-reposts.mjs`). It needs a minimum time span, because postings seen in the same sweep are parallel openings, and it matches on title identity, not fuzzy similarity.

## 2. What AutoApply already has (short map)

- **Pipeline** (`engine/autoapply/pipeline.py`): discover → score → prep → apply → maintenance.
  - Quota loop and borderline review band.
  - Scores are reused while the profile/preferences fingerprint is unchanged.
  - Auto-ghost after 21 days; "Heard back?" nudges on days 7 and 14.
- **Scoring** (`engine/autoapply/scoring.py`):
  - About 10 deterministic hard filters (company, keyword, off-field, industry, seniority, remote/location with Indian city aliases, no-sponsorship regex, salary floor, cooldown, daily cap).
  - Then a batched LLM score from 0 to 100, with factors skills / seniority / role / domain and up to 5 concerns. Threshold 70.
  - No golden eval set.
- **Answers** (`engine/autoapply/answers/`):
  - A resolver chain: profile → never-guess → memory → grounded generation with a confidence score → Needs-You.
  - A guardrail audit before submit.
  - Inbox questions clustered by embedding.
  - Résumé **picked from variants** (with a response-rate weight), never tailored.
  - Cover letter with a `fact_check` grounding gate. It is already comparable to career-ops' fact gate.
- **Discovery**:
  - Public Greenhouse, Lever and Ashby APIs.
  - Google Jobs (public).
  - LinkedIn and Glassdoor through a **logged-in** browser profile (off by default).
  - Career-page agent with a JSON-LD to LLM ladder, and a company finder via Google `site:` queries.
  - Search planner that learns which searches pay off; starter boards.
- **Apply**:
  - Scripted Greenhouse, Lever and Ashby adapters, plus an agentic Workday/unknown adapter (`apply/agentic.py`).
  - `ToolGate` blocks submit clicks until `request_submit`, and verification needs evidence.
  - Site-account creation with passwords kept in the Keychain (`site_accounts.py`).
  - `reconsider.py` and `role_focus.py`.
- **Outreach** (in progress, `docs/COLD_EMAIL_PLAN.md`, `engine/autoapply/outreach/`, not wired in yet):
  - Contact scout with confidence and provenance.
  - Grounded drafts, SMTP with caps, IMAP reply/bounce classification, a suppression list, and a LinkedIn referral copilot where the human sends.
- **App** (`app/Sources/AutoApply/Features/`): Dashboard (funnel, response rate by résumé, score histogram), Board, JobDetail (factor bars, Q&A audit, screenshots), Inbox, Review, EasyApply, AddJob, Profile (story bank), Resumes, Settings, ActivityLog, ColdEmail preview.
- **Absent**:
  - Liveness checks, repost and scam detection.
  - Interview prep and negotiation.
  - Application reply-watch: application statuses are set by hand.
  - Calibration and rejection-pattern learning.
  - Scoring evals and multi-language support.
  - India-specific sources (Naukri and the like are only routed to the manual list).

## 3. Where AutoApply is already ahead

- **End-to-end autonomy with real safety engineering.** Durable `submitting` state, `unknown_verify` never retried, a submit gate, ToolGate, screenshot evidence, caps and cooldowns. career-ops stops at "you press Submit".
- **Needs-You clustering plus answer memory.** One answer unblocks many jobs. career-ops answers each form from scratch for every application.
- **A real app.** Board, review queue with screenshots, Q&A provenance, dashboard and menu bar. career-ops is a CLI, a TUI and an optional web view over Markdown files.
- **Discovery that finds companies.** The company finder, careers agent and search planner find employers the user didn't name. career-ops only sweeps a `portals.yml` list the user maintains (plus `discover-new-companies.mjs`).
- **Résumé response-rate learning** in the picker, and **score reuse by fingerprint**.
- **Cold email with contact discovery** (planned) goes well beyond career-ops' LinkedIn-note drafts.
- **Workday and iCIMS account handling** and **emailed verification codes**.

## 4. Gap analysis: ranked "worth stealing" list

Effort: S = a few days, M = 1–2 weeks, L = more.

### 1. Liveness check before prep and apply (S, priority **high**)

- **What:** a zero-token ladder: ATS API per job (Greenhouse/Lever/Workday) or per org (Ashby: is the posting still listed?), then page text patterns, then "uncertain" (never "expired").
  - career-ops: `liveness-api.mjs`, `liveness-core.mjs`, `check-liveness.mjs`, `modes/oferta.md` § Liveness gate.
- **Why it matters:** jobs can sit in `queued` for days, especially through the review band and Needs-You. Today nothing checks that the job is still open, so:
  - prep and agentic apply burn tokens on closed postings;
  - the agent may report confusing results;
  - users see "submitted" for ghost roles.

  Indian boards and company career sites re-list and close postings often.
- **Fit:**
  - A `liveness.py` beside `discovery/base.py`, called in `pipeline.py` at the start of `prep` (next to `_skip_if_stale`) and again right before `submit_gate`.
  - A new skip reason `posting_closed` in `scoring.py`'s `SKIP_*` set.
  - Reuse the Greenhouse/Lever/Ashby clients we already have.
  - JobDetail shows the last-checked time.

### 2. More public ATS providers, especially Workday CXS, SmartRecruiters, Workable, Recruitee and Zoho Recruit (M, priority **high**)

- **What:** no-login JSON endpoints, e.g. Workday `POST https://<tenant>.<instance>.myworkdayjobs.com/wday/cxs/<tenant>/<site>/jobs`.
  - career-ops: `providers/workday.mjs`, `smartrecruiters.mjs`, `workable.mjs`, `recruitee.mjs`, `zoho-recruit.mjs`, `bamboohr.mjs`, `teamtailor.mjs`, `successfactors.mjs`, `oraclecloud.mjs`, `eightfold.mjs`, `phenom.mjs`; how-to in `providers/ADDING_A_PROVIDER.md`.
- **Why it matters:**
  - Many large Indian employers (IT services, GCCs, banks) post on Workday, SuccessFactors, Oracle or Eightfold. Many Indian startups use Zoho Recruit or Workable.
  - Today we reach them only through Google Jobs or the careers agent, which is slower, costs LLM tokens, and depends on Google's rate limits.
  - Public APIs are also ToS-cleaner than the logged-in LinkedIn and Glassdoor sources.
- **Fit:**
  - New `discovery/<ats>.py` modules on `discovery/base.py`.
  - Detection in `careers.py` (`ATS board check` rung) and `company_finder.py` (`site:myworkdayjobs.com` queries).
  - `companies.ats`/`board_token` already model this.
  - Apply still goes through `apply/agentic.py`.

### 3. Posting legitimacy and scam signals (M, priority **high**)

- **What:** warn-only signals that never change the score:
  - **candidate-paid fees** (training, onboarding, deposit or "registration" fees);
  - agency intermediary with no employer named;
  - reposting pattern (minimum span plus title identity);
  - JD vagueness and contradictions;
  - contractor wording disguised as employment;
  - stale posting age.
  - career-ops: `modes/oferta-signals/21-candidate-paid-fees.md`, `10-agency-licensing-check.md`, `20-unpaid-placement.md`, `modes/oferta.md` § Block G, `modes/_shared.md` § Posting Legitimacy, `detect-reposts.mjs`.
- **Why it matters:** fake-job and "pay to get placed" scams are widespread in India, often posted on aggregators and reached through Google Jobs. An autonomous agent that applies to them, and may create accounts on their sites, is worse than a human doing it.
- **Fit:**
  - Add a `legitimacy` object to `SCORE_SCHEMA` (the LLM is already reading the JD; the extra output tokens are cheap).
  - Add a deterministic repost check over `jobs`. We need a `first_seen` per URL, which `jobs.created_at` already provides.
  - A "Suspicious" tier forces `awaiting_review` instead of auto-apply.
  - Show it as a badge in Board and JobDetail.
  - Keep career-ops' framing: present signals, never accuse.

### 4. Reply-watch for applications (M, priority **high**)

- **What:** classify employer emails into Interview, Responded, Need Action, Rejected, Offer, Auto-confirmation, Noise or Unknown. Match each to a tracker row by company, role and domain, then *propose* a status change the user confirms.
  - career-ops: `modes/reply-watch.md`, `reply-watch.mjs`, `reply-matcher.mjs`, `docs/REPLY_PROPOSALS.md`.
- **Why it matters:**
  - Our funnel, response-rate-by-résumé and the auto-ghost all depend on application status, which users set by hand today. Most won't, so the dashboard and résumé learning run on bad data.
  - Auto-ghost can also mark jobs ghosted that were actually rejected.
- **Fit:**
  - We already have read-only IMAP (`mail/common.py`, `mail/imap_codes.py`) and a reply classifier (`outreach/mailwatch.py`).
  - Extend `mailwatch` to scan for messages from applied companies' domains and ATS senders (greenhouse-mail.io, myworkday, lever).
  - Write a suggestion to the Inbox ("Acme looks like a rejection: confirm?").
  - `db.set_status` runs on confirmation. Never changes the board by itself, the same rule the cold-email plan already has.

### 5. Close the learning loop: calibration, skip-blockers, upskill (M, priority **medium-high**)

- **What:**
  - `calibrate`: interview and offer rate per score band, with a verdict of separating, flat, inverted or insufficient; it withholds rates when n is too small.
  - `skip-blockers` / `upskill`: which critical requirements keep appearing as missing in skipped roles, with each report weighted by 5 minus its score.
  - `patterns`: outcomes by archetype, remote policy and source.
  - All advisory and never auto-tune.
  - career-ops: `modes/calibrate.md`, `calibrate.mjs`, `skip-blockers.mjs`, `upskill.mjs`, `modes/patterns.md`, `analyze-patterns.mjs`.
- **Why it matters:** we hold richer data than career-ops: every score, factor, concern and skip reason is in SQLite. Users want to know whether 70 is the right threshold for them and what to learn next. This is a cheap, sticky feature, and it depends on item 4 for clean outcomes.
- **Fit:**
  - SQL over `scores` × `applications.status`.
  - Our `scores.reasons.concerns` already gives gap text; normalise it with the fast LLM or embeddings.
  - New Dashboard cards: "Do your scores predict interviews?" and "What keeps blocking you".
  - Optionally a threshold suggestion the user accepts in Settings (the histogram preview already exists).

### 6. Interview prep pack from the story bank (M–L, priority **medium**)

- **What:**
  - When status becomes Interview: company-specific prep (process, likely questions, STAR stories mapped to JD requirements, questions to ask).
  - Practice mode (one question at a time, with feedback).
  - Debrief mode (updates the question and story banks).
  - A "retracted claims" hard gate.
  - career-ops: `modes/interview-prep.md`, `modes/interview/{plan,practice,debrief}.md`, `match-star.mjs`, `story-provenance-check.mjs`.
- **Why it matters:** it is the next step after we get someone an interview, and today we drop them there. Indian candidates often face several technical rounds plus HR rounds.
- **Fit:**
  - A new `engine/autoapply/interview.py` that uses `stories`, `jobs.description` and `scores.reasons`.
  - A new "Interview" tab in JobDetail when `status = interview`.
  - Adopt the story-provenance rule: numbers in generated stories must trace back to the profile. Our `fact_check` covers this.

### 7. Requirement→evidence table, evidence confidence and a golden eval set (S–M, priority **medium**)

- **What:**
  - The two-pass Block B table (JD importance first, then CV match with a quoted evidence line; at most 12 rows, gaps first).
  - Supported/partial/unknown evidence per dimension, giving a confidence tier.
  - Dealbreaker hits must quote the JD sentence.
  - A frozen golden set of labelled JDs to check scorer drift when we change models or prompts.
  - career-ops: `modes/oferta.md` § Block B and § Dealbreaker gate, `modes/_shared.md` § Evidence confidence, `evals/README.md`, `evals/golden/*.json`, `eval-golden.mjs`.
- **Why it matters:**
  - Our factor bars (skills / seniority / role / domain) don't show *which* requirement is missing.
  - Users who disagree with a score have nothing to argue with.
  - We have no regression guard on score quality (`engine/tests/a_core/test_scoring.py` covers only logic).
- **Fit:**
  - Extend `SCORE_SCHEMA` with `requirements[{req, importance, match, jd_quote, evidence}]` and `confidence`. To keep token cost down, request it only for jobs above the borderline band, or compute it lazily in JobDetail.
  - Add `engine/tests/evals/` with about 20 Indian and global JDs plus a fixture profile, run on demand rather than in CI.

### 8. Warm intros from the user's own LinkedIn export, plus voice rules for outreach (S, priority **medium**)

- **What:**
  - `linkedin-join.mjs` joins `Connections.csv`, which the user downloads themselves from LinkedIn → Settings → Data Privacy, against tracked and target companies.
  - `contact-lookup.mjs` checks saved contacts before any cold search.
  - `voice-dna.template.md` and `modes/_writing.md` give concrete anti-AI-tell writing rules.
- **Why it matters:**
  - Referrals beat cold email by a wide margin in India.
  - A CSV the user exports involves no scraping and no ToS risk.
  - Cold emails that read as AI-written hurt reply rates and sender reputation.
- **Fit:**
  - Import into `contacts` with `origin = linkedin_export`.
  - Surface "You know 2 people at Acme" in JobDetail and the referral copilot (`outreach/referrals.py`, `COLD_EMAIL_PLAN.md` § F.1).
  - Add the voice rules to the `outreach/drafts.py` and `answers/cover_letter.py` prompts.

### Also considered (lower priority)

- **CV tailoring with a fact gate** (L, medium-low).
  - career-ops: `modes/pdf.md`, `verify-cv-facts.mjs`.
  - Real value, but it means building PDF rendering and taking on the risk of ATS parse problems. Our variant picker plus the response-rate signal is a reasonable 80% answer.
  - If we do it later: reword only, never add skills (`modes/pdf.md` § Keyword injection), and run the same `fact_check`.
- **India compensation notes** (S, medium-low).
  - career-ops: `modes/hi/_shared.md`; company-type reliability tiers in `modes/_shared.md`.
  - CTC vs in-hand, fixed vs variable, notice period and buyout.
  - Useful for the salary-floor filter (compare fixed CTC, not "up to" CTC) and for answers to never-guess salary questions.
- **Adjacent titles from the CV, including removals** (S, low).
  - career-ops: `modes/titles.md`.
  - Our `role_focus.py` already expands vague roles. Adding "suggest titles you aren't searching for" to `prefs_suggest.py` is a small add-on.
- **Retro: user corrections become standing rules** (S, low).
  - career-ops: `modes/retro.md`, `learn.mjs`.
  - Our answer memory already covers most of this.
- **Cross-channel duplicate check** (S, low).
  - career-ops: `modes/apply.md` § Preflight.
  - Warns when the same role was already applied for through an agency, or vice versa. Matters for Indian consultancies that re-post client roles.
- **Offer-stage contract reading companion** (M, low for now).
  - career-ops: `modes/offer-prep.md`.

## 5. Don't copy (risky or not a fit)

- **Logged-in scraping.** career-ops deliberately keeps login-gated sources out of core (`ARCHITECTURE.md` § Discovery; `LEGAL_DISCLAIMER.md` §4). That is a mirror for us: our `discovery/linkedin.py` and `glassdoor.py` read listings through the user's logged-in profile, which is against LinkedIn's and Glassdoor's ToS even at human pace and with read-only access.
  - Keep them off by default, and keep the account risk clearly in front of the user.
  - Prefer the public-ATS providers in item 2, which make them less necessary.
- **Keyword "injection" beyond rewording, and anything resembling white-text or hidden keywords.** career-ops forbids this too (`modes/pdf.md` § ATS Rules). Don't add skills to CVs or answers that the user's sources don't support.
- **Web research on named hiring managers** (`modes/pdf/hm-audit.md`), and LinkedIn profile-finding beyond what `COLD_EMAIL_PLAN.md` already allows (titles in Google results only). It builds profiles of private individuals, raises DPDP and GDPR questions, and costs tokens.
- **Their stance against auto-submitting.** `LEGAL_DISCLAIMER.md` §5 lists "auto-submitting applications without human review" as unacceptable use. This is not a legal constraint on us, but expect the comparison. Our answer is the review mode, caps, cooldowns, the fact gate and verification. Keep `per-ATS mode` defaults conservative (Workday = review) and keep making clear that the user controls auto mode.
- **Jurisdiction legal tables** (signals 11–22 for Ontario, California, the EU…). Too much legal surface for us to maintain. Take only the scam pattern (candidate-paid fees), which is jurisdiction-independent.
- **Files as the source of truth, plus 45 prompt modes.** Their architecture suits a CLI. Ours (SQLite plus a typed protocol plus an app) is the right one for a product. Borrow behaviours, not structure.

## 6. License

- **Code:** career-ops is **MIT** (`LICENSE`, © 2026 Santiago Fernández de Valderrama; `scaffolder/` is MIT too).
  - Copying or porting code or prompt text is allowed if we keep the copyright and permission notice, e.g. in a `THIRD_PARTY_NOTICES` file and a header comment on ported files.
  - Most of this would be ported from JS to Python, which is reasonably a derivative work: still keep the notice.
  - Ideas, workflows and rubrics aren't copyrightable at all.
- **Exceptions to check before copying a specific file:**
  - `modes/offer-prep.md` says it adapts a concept from Anthropic's Apache-2.0 `claude-for-legal` (the text is theirs, the concept credited).
  - `jd-skill-gap.mjs` credits an Apache-2.0 project.
  - `upskill` credits `MadsLorentzen/ai-job-search`.
  - Bundled fonts are OFL.
- **Name and brand:** `TRADEMARK.md` reserves the "career-ops" name and brand for commercial product naming and endorsement. Don't use the name in our UI or marketing beyond factual attribution.
