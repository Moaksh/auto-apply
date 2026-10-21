# Cold outreach: plan

Status: design. Owner: engine + app. Covers: email follow-ups on applications, prospecting, contact discovery, sending, compliance, a shared contact library (design only), LinkedIn referrals.

Ground rules carried over from the rest of AutoApply:
- The daemon is the only DB writer. The app reads SQLite through GRDB and changes things only through socket commands (`contract/protocol.md`).
- Nothing irreversible happens without the user. Applications have `awaiting_review`; outreach has **approval per batch, minimum**.
- The agent never automates LinkedIn or Glassdoor (`BLOCKED_HOSTS` in `apply/agentic.py`). This plan keeps that rule exactly.
- Every claim is grounded: drafts go through the same `fact_check` as cover letters (`answers/cover_letter.py`).

---

## A. Product flows

### A.1 Mode (a): follow-ups on applications

1. **Trigger.** An application reaches `submitted`, whether the agent submitted it or the user used `mark_applied` / `mark_easy_apply_done`. If `preferences.outreach_auto_scout` is on (default: on), the daemon queues a **scout** for the company. A company scouted in the last 30 days is not scouted again; its contacts are reused.
2. **Find people.** The scout (section B) produces ranked contacts for this application. Order: a recruiter named in the posting, then a recruiter or talent person for the role's function and location, then the likely hiring manager (Engineering Manager or Head of X for the team), then a senior engineer on the team.
3. **Draft.** When the best contact clears `outreach_min_email_confidence` (default 60), the daemon writes a draft automatically (default on): 60–110 words, grounded, mentioning the role and that the user applied. The thread is created in state `draft`, which adds to the Cold Email sidebar badge. No email is sent at this point.
4. **Pick and review.** In **Cold Email ▸ Outbox** the user sees the draft beside a contact card: name, title, a confidence badge, and a provenance popover such as "found on acme.com/team, 12 Oct". The user can edit the text, switch to another contact for the same company with one click (which re-drafts), or discard.
5. **Send (approval).** The user selects one or more drafts and clicks "Send N…". A sheet then says: *"Send 6 emails from you@gmail.com, spaced over about 40 minutes, between 09:30 and 17:30 on weekdays. [ ] Also send one follow-up after 5 business days if nobody replies."* Confirming calls `approve_outreach`. Each message moves to `scheduled` with a `send_at`.
6. **Sending.** The sender loop sends messages when they are due (section C). The job card gets a badge such as "Emailed Jane (Recruiter)", and the Activity log gets an `outreach` event.
7. **Follow-up.** If there is no reply after `outreach_followup_days` (default 5 business days), a follow-up is created as a reply in the same thread (`In-Reply-To`). If the user pre-approved it in step 5, it is scheduled straight away; otherwise it lands in the Outbox as a draft. There is never more than `outreach_max_followups` (default 1). A follow-up is cancelled automatically if the thread gets a reply, bounces or opts out, if the application's board status becomes `rejected` or `offer`, or if the contact is added to the do-not-contact list.
8. **Replies.** The IMAP watcher (C.6) attaches the reply to the thread and classifies it. **Needs You ▸ Replies** then shows "Jane at Acme replied: 'Thanks, I've passed your profile…'" with **Open in Gmail** and, when the reply suggests it, a one-click "Move to Interview" or "Move to Rejected". The board status never changes by itself. A reply also stops auto-ghosting for that application.

Timing rule: the first email goes out no earlier than 1 business day after submission. That reads as human and gives the ATS time to register the application.

### A.2 Mode (b): prospecting

1. **Pick a target company.** Sources: a company from the watchlist, a pending suggestion, a company search result (A.3), or a typed name or URL ("Add company").
2. **Company card.** Domain, a one-line "what they do" taken from the homepage meta description and `og:description` (stored as evidence, so drafts can cite it), open matching roles from the board if one is known (reusing the ATS readers), and a prospect fit score.
3. **Find people.** Same scout, but ranked for prospecting: an engineering leader for the user's function, then a founder or CTO (companies with fewer than about 50 people), then a recruiter.
4. **Draft.** A prospect note: why this company (only from evidence on the company's page), what I bring (only from profile and stories), and one clear ask (a 15-minute chat, or a pointer to the right person). The draft never claims "I applied" and never invents a "saw your talk".
5. Review, send, follow-up and replies work exactly as in A.1.
6. **Guardrails.** One active prospect thread per company, at most 2 people per company at once, and a 60-day cooldown per company after a thread closes with no reply. A company on `preferences.exclude_companies`, or one the user has an active application with, is offered mode (a) instead.

### A.3 Company search for prospecting

A search box on the **Prospects** tab: free text plus optional location, e.g. *"Series B fintech in Bangalore"* or *"developer tools startups, remote India"*.

1. The model turns the query into 3–4 Google queries, e.g. `"fintech startups" Bangalore "series b" 2026` or `site:ycombinator.com/companies fintech india`. They are read in the visible agent Chrome at human pace, using a `prospect_finder` daily budget (default 6 result pages) that works like `company_finder`'s.
2. Each result page is fetched over HTTP (httpx). The model then extracts `{company, url, evidence_quote}`. A company is dropped unless its name appears in the page text.
3. Enrich each company: resolve the domain, fetch the homepage meta, detect careers pages and ATS boards (reusing `discovery.careers` and `detect_ats`), and count matching roles with the board readers.
4. Score fit with the model against the profile and preferences (0–100, with reasons), using the same structured-output pattern as `scoring.py`.
5. Insert results into `prospects` with status `suggested`. The user can **Shortlist** (which starts a scout), **Watch** (adds it to the job watchlist, same path as `accept_company_suggestion`), or **Dismiss** (never suggested again).

Also seeded with no searching at all: watched companies that have no matching open role. These are good prospects, and the data already exists.

### A.4 Manual contacts

- An **Add contact** sheet: name, email, company (pick or type), title, how you know them (`friend | ex_colleague | alumni | met | other`), LinkedIn URL, notes, and a "Share to library" toggle (**off by default** for manual contacts; see E).
- A contact the user typed gets email confidence 100 and email status `user`, with an evidence row of kind `user`.
- **Import CSV** (Phase 2): columns `name,email,company,title,linkedin_url,notes`, deduplicated by normalized email.
- A manual contact can be the target of mode (a), mode (b), or a referral.

### A.5 What is automatic and what needs the user

| Step | Automatic? | Notes |
|---|---|---|
| Scouting a company after an application is submitted | Yes (toggle) | Uses Google budget and model tokens; capped per day |
| Scouting a prospect | On Shortlist | |
| Drafting for the best contact (mode a) | Yes (toggle) | Draft only |
| Drafting for prospects | On user click | |
| **Sending any first email** | **Never** | `approve_outreach`, per batch, with a confirm sheet |
| Sending a follow-up | Only if pre-approved in the original batch; otherwise a draft | Cancelled automatically on reply, bounce or opt-out |
| Detecting replies and bounces | Yes | Read-only IMAP |
| Adding to do-not-contact on opt-out or hard bounce | Yes | User can undo bounces only, never opt-outs |
| Changing the board status from a reply | No | Suggested in Needs You |
| Replying to a reply | Never | The user replies in Gmail |
| LinkedIn connect or DM | Never automated | Copilot only (F) |
| Uploading to the shared library | Only after opt-in | Phase 3 |

---

## B. Contact discovery

### B.1 Shape of the scout

`outreach/scout.py` defines `ContactScout.scout(company_id, purpose, job_id=None)`. It is deterministic code that calls small sources in order, stops early once it has enough, and writes `contacts` and `contact_evidence`. **It is not a free-roaming browser agent.** The model is used only as a structured extractor, classifier and drafter, through `LLMProvider.complete(schema=…)`, and every extraction is checked:

- each person's `name` (and `title` if given) must appear word for word in the fetched page text after the `textnorm` normalization; otherwise the person is dropped;
- each email must match a regex over the raw page; the model never creates email addresses.

This is cheaper, testable with fixtures, and it cannot drift onto LinkedIn.

Sources that only make HTTP requests (1, 2, 4, 6, 7) run immediately, even when the user asks during a run. Steps that read Google (3) need the visible Chrome profile. They run only when the `RunCoordinator` is idle, or as the final step of a `full` run, sharing the browser session that discovery already uses (Chromium allows one process per user-data-dir; see `workers.py`).

### B.2 Resolving the domain first

Contacts need a domain, but `companies.domain` is often null. The domain is resolved in this order, and only domains with MX records are kept:
1. a non-ATS host in `companies.careers_url` or the job's `apply_url`;
2. the company website link on the ATS board page (Greenhouse, Lever and Ashby board pages usually have one) or JSON-LD `hiringOrganization.sameAs/url` on the posting;
3. one Google query, `"{company}" official website`; the first non-aggregator result whose `<title>` contains the company name.

The result is stored in `companies.domain`. An existing column is reused, so no schema change is needed for this.

### B.3 Techniques, ranked by reliability (best first) and cost

| # | Technique | Gives | Reliability | Cost | Notes |
|---|---|---|---|---|---|
| 1 | **User-entered contact** | person + email | Highest | Free | Confidence 100 |
| 2 | **Job-posting contact lines** | recruiter name, sometimes email | Very high | Free (JD already in `jobs.description`) | Regex for emails and phrases like "reach out to", "recruiter:", "hiring manager:", plus model extraction checked against the text. Low coverage, about 5–10% of postings |
| 3 | **Company pages**: `/team`, `/about`, `/leadership`, `/company`, `/press`, `/contact`, `/careers`, engineering-blog author pages, `/.well-known/security.txt`, JSON-LD `Person` | names, titles, published emails, role mailboxes (careers@, jobs@) | High for startups, low for enterprises | Free; about 6–10 HTTP fetches per company, all in the background | Main source for companies under about 200 people. Every email seen on the domain is also **pattern evidence** |
| 4 | **GitHub org** | engineers and EMs (public members), name, company, blog, public email; **commit author emails on the company domain** | High for engineering orgs | Free: 60 requests/hour without a token; an optional personal access token in Keychain gives 5,000/hour | `GET /orgs/{org}/public_members`, `GET /users/{login}`, `GET /repos/{org}/{repo}/commits?per_page=50` (filter `*@{domain}`, drop `noreply`). Commit emails are the best free pattern evidence there is |
| 5 | **Google result pages** (`site:` queries), reading **only Google's results** | names and titles from result titles like "Jane Doe – Senior Recruiter – Acme \| LinkedIn"; email samples | Medium; titles can be stale | Google budget: `people_finder` default 6 result pages/day, human pace (`HumanPacer`), stop at CAPTCHA (`CAPTCHA_REST_HOURS`) | Queries: `site:linkedin.com/in "Acme" ("talent acquisition" OR recruiter) "Bengaluru"`; `site:linkedin.com/in "Acme" ("engineering manager" OR "head of engineering")`; `"@acme.com" -noreply` (email samples). We store the profile URL as a reference **but never open it**; the agent's navigate gate already denies linkedin.com |
| 6 | **Email pattern inference** | email for a named person | Depends on evidence (B.4) | Free | Needs at least one real address on the domain |
| 7 | **MX lookup** | deliverability of the domain, provider (Google / Microsoft / other) | Domain-level only | Free (`dnspython`) | No MX means the domain cannot receive email, so the contact is rejected |
| 8 | **Paid providers** (user's own key) | email + verification status, domain pattern | High | Hunter's free tier is about 25 searches and 50 verifications a month; paid beyond that | A pluggable `EmailProvider` protocol: `domain_search(domain)`, `find(first, last, domain)`, `verify(email)`. Hunter first (Phase 2), Apollo later. Key in Keychain (service `AutoApply Providers`); monthly credit counter in `meta` |

**Not done:**
- **SMTP RCPT verification** (connecting to the target's mail server and asking whether it accepts `RCPT TO:<guess>`). Reasons:
- outbound port 25 is blocked by most residential ISPs, including the common Indian ones;
- Google Workspace and Microsoft 365 accept or defer at RCPT, or rate-limit and flag the connecting IP;
- catch-all domains accept everything, so the answer means little;
- repeated probing gets the user's home IP onto blocklists, which hurts the very Gmail sending we depend on.

We record `mx_provider` and treat Google- or Microsoft-hosted domains as "verification impossible". The **bounce feedback loop** (C.6) is our verifier.
- Scraping LinkedIn, Glassdoor or any logged-in site. Guessing personal (non-domain) emails. Phone numbers.

### B.4 Pattern inference

`outreach/patterns.py` holds pure functions with heavy unit tests.

- Candidate patterns: `first.last`, `first`, `flast`, `firstlast`, `first_last`, `firstl`, `last.first`, `f.last`, `last`.
- **Evidence** is every (name, email) pair seen on the domain, from GitHub commits (author name and email), company pages, posting lines and providers. Role mailboxes (`careers`, `jobs`, `hr`, `info`, …) are excluded from pattern evidence.
- For each pair, find the patterns that produce the email from the name: normalize (`strip_accents`, lowercase, drop punctuation) and try two-part and multi-part names. Indian names often have a single given name, initials or a long surname, so we also try `first` + `last-initial` variants.
- `domain_patterns.pattern` is the pattern with the most independent confirmations. Pattern confidence is:
- `k` = samples that support the winning pattern, `m` = samples that contradict it;
- `conf = clamp(50 + 12*k − 15*m, 0, 85)`;
- with no samples (`k = 0`): a default guess scored 25 (`first.last` for companies over 50 people, `first` for small startups);
- a hard bounce on a pattern-guessed address subtracts 20 and increments `bounces`; after 2 bounces the next-best pattern is promoted and affected drafts are flagged.

### B.5 Confidence score and provenance

Each contact has **two scores**:

**`email_confidence` (0–100)**, worked out in `contacts.recompute_confidence()`:

| Basis | Score |
|---|---|
| Typed by the user, or we received a reply from this address | 100 |
| Published word for word on a company-domain page, in the job posting, or in a GitHub commit or profile | 95 |
| Provider says `valid` | 90 |
| Published on a third-party page or Google snippet only | 80 |
| Pattern inferred | the domain pattern's confidence (≤ 85), −10 if the name parse was ambiguous |
| Sent, no bounce within 72 h | +10, capped at 90 (a catch-all can accept and silently drop) |
| Hard bounce | 0, status `bounced`, address blocked |
| Domain has no MX / free-mail domain (gmail.com, yahoo.co.in, …) for a scraped contact | rejected, not stored |

Tiers shown in the UI: **Verified** ≥ 90, **Likely** 70–89, **Guess** 40–69, **Unknown** < 40. Default send threshold: 60. Anything lower needs "Send anyway" for that individual contact.

**`role_fit` (0–100)**: how relevant the person is for this purpose. The model rates the title against the job (function, seniority, location), and evidence age counts against it: a title only seen in an old snippet loses 15.

**Provenance**: one `contact_evidence` row per observation, with `kind`, `url`, `field` (name/title/email), a `snippet` of at most 280 characters, and `observed_at`. The UI shows the strongest line, e.g. "Email: GitHub commit in acme/api (3 Oct). Title: acme.com/team (12 Oct)." Provenance is also what decides whether a contact may be shared (E).

### B.6 What is realistic without paid APIs

These are honest, rough expectations, to be measured after Phase 1:
- **Startups and scale-ups with a team page or active GitHub org:** named, relevant people for most companies, and a confirmed pattern (k ≥ 1) for roughly half of them.
- **Large enterprises:** names and titles from Google results are reliable enough, but finding the pattern is hit-and-miss. Expect many "Guess" emails, and careers@ or recruiting mailboxes are often the honest best option.
- **Indian services companies and MNC captive centres:** names are easy to find; the pattern often comes only from bounce learning or a provider.

So the UI must make "Guess" obvious, and Hunter's free tier (25 searches a month) is a worthwhile optional upgrade for the 3–5 companies a week the user cares about most.

---

## C. Sending and deliverability

### C.1 Transport

- `mail/smtp_send.py`: `smtplib.SMTP("smtp.gmail.com", 587)`, then `starttls()`, then `login(address, keychain_get(address))`, reusing `imap_codes.keychain_get`, `normalize_password` and the `mail_account` meta. It runs in `asyncio.to_thread`.
- **v1 supports Gmail and Google Workspace only.** For a Workspace account whose admin has disabled app passwords, login fails with a clear error and sending stays off.
- Sending is a separate opt-in. `mail_account` gains `send_enabled: bool`, which becomes true only after the user clicks **Enable sending** in Settings ▸ Outreach and a **test email to themselves** succeeds.
- `From: "{profile.full_name}" <mailbox>`. If `profile.email` differs from the mailbox, Settings warns ("Replies will go to the mailbox you connected"). Gmail stores SMTP-sent mail in Sent Mail automatically, so the user's Gmail shows the whole conversation.

### C.2 Message format

- `email.message.EmailMessage`, `text/plain; charset=utf-8`, no HTML, **no tracking pixels, no link rewriting, no attachments by default**. Attachments on a first cold email hurt deliverability. Up to 2 plain links from `profile.links` (LinkedIn, portfolio or GitHub) are allowed. An optional "attach resume" toggle, off by default, is allowed on follow-ups to someone who replied.
- `Message-ID: make_msgid(domain=<mailbox domain>)`, stored in `outreach_messages.message_id_header`. Follow-ups set `In-Reply-To` and `References` to the previous message's ID and use subject `Re: <original subject>`.
- First-email subject: at most 8 words, specific, never starting with "Re:" or "Fwd:" (deceptive). Example: "Backend Engineer application – Asha Rao".
- Footer, always present and not editable away (the sender adds it to the stored body):
`—`
`I found your address on {source_label}. If you'd rather not hear from me, reply "no thanks" and I won't email again.`
`source_label` comes from the strongest email evidence, e.g. "acme.com/team", "the Acme job posting", "GitHub", or "a mutual contact" for user-entered contacts. This covers opt-out (CAN-SPAM style) and source disclosure (GDPR Art. 14) in one line.
- No `List-Unsubscribe` header. This is one-to-one mail, and bulk headers make it look like marketing.

### C.3 Caps and pacing (defaults are deliberately low)

| Setting | Default | Hard limit |
|---|---|---|
| `outreach_daily_cap`: **new** threads per day | 10 | 40 |
| Total sends per day, including follow-ups | 2 × cap | 60 |
| Per recipient domain per day | 2 | 3 |
| Spacing between sends | random 3–9 min | ≥ 90 s |
| Send window | 09:30–17:30 user's local time, Mon–Fri | — |
| Follow-ups per thread | 1 | 2 |
| Prospect cooldown per company | 60 days | — |

Gmail's documented consumer limit is about 500 recipients a day. That is not the risk. The risk is that a sudden burst from a personal account that never sends cold email gets throttled or flagged, so we stay at about 2% of the limit. New users get a 7-day ramp (5, then 8, then 10). Caps use the existing `cap_reached` event with a new `cap` value of `outreach_daily`. `approve_outreach` never fails because of caps; it schedules over the next allowed days and tells the user ("6 today, 4 tomorrow").

### C.4 Sending reliably (same approach as `submitting`)

The message states are as follows (allowed transitions live in `models.py`, enforced by `db.transition_outreach`):

```
draft → approved → scheduled → sending → sent
                    ↘ cancelled          ↘ failed (SMTP refused before DATA: definitely not sent)
                                         ↘ unknown (crash/timeout after DATA)
inbound: received
```

- `sending` is committed with `synchronous=FULL` **before** `smtp.send_message`, after a final check of pause, caps, the do-not-contact list, the thread's state (no reply yet) and the send window. Nothing awaits between that check and the write, so it is atomic on the daemon's single event loop, the same reasoning as `submit_gate` followed by `begin_submit`.
- On daemon start, every `sending` message becomes `unknown`. The mail watcher then looks for its Message-ID in `[Gmail]/Sent Mail` (`X-GM-RAW "rfc822msgid:<id>"`, falling back to `HEADER Message-ID`). If found, it becomes `sent`. If not, it stays `unknown` and shows in Needs You ("We may not have sent this email. Send again?"). **It is never resent automatically.**
- `pause_all` stops the sender before the next message.

### C.5 The do-not-contact list

The `suppression` table holds a normalized email **or** a whole domain, a reason (`opt_out | hard_bounce | user | shared_removal | complaint`) and a source. It is checked when drafting, when approving, and immediately before sending. Opt-outs can never be undone in the UI (only "delete record" in the data tools). A deleted contact is added to the list if the user ticks "also never email" (default checked).

### C.6 Detecting replies and bounces (IMAP)

`outreach/mailwatch.py` runs from the maintenance loop every 10 minutes while any thread has had a message sent in the last 45 days.

- It reuses `imap_codes._login` and selects `INBOX` with `readonly=True`, using `BODY.PEEK[]` so nothing is ever marked as read.
- **Replies:** search `OR HEADER In-Reply-To "<id>" HEADER References "<id>"` for each open thread's message IDs. Also search `FROM <contact email> SINCE <first sent date>`, because people sometimes start a new thread. When the X-GM-EXT-1 extension is available, also match `X-GM-THRID` of the sent message.
- **Bounces:** messages from `mailer-daemon@googlemail.com` / `postmaster@`, with `Content-Type: multipart/report; report-type=delivery-status`. The `message/delivery-status` part is parsed for `Final-Recipient` and `Status`. `5.x.x` is a hard bounce (thread `bounced`, contact confidence 0, recipient added to the do-not-contact list, the pattern penalised). `4.x.x` is ignored until a final failure arrives. The original Message-ID inside the bounce links it to the message.
- **Classification:** auto-replies are spotted first, without the model, from `Auto-Submitted: auto-replied`, `X-Autoreply`, `Precedence: auto_reply` and subject patterns; these are marked `ooo` and **do not** count as replies (the follow-up is pushed back to the stated return date if the model can extract it). Everything else goes to the model with the schema `{label: positive|referred|not_interested|opt_out|question|other, suggested_status?: interview|rejected|null, return_date?}`. An opt-out regex runs as well ("unsubscribe", "remove me", "stop emailing", "don't contact"); if either the regex or the model says opt-out, the sender is added to the do-not-contact list.
- **Effects:** the thread becomes `replied` (or `bounced` / `opted_out`), pending follow-ups are cancelled, an event `outreach_reply` is emitted, and the Needs You Replies count goes up. For mode (a), `db.ghost_stale_applications` skips applications whose thread has a reply.
- **LinkedIn notification emails**, for F: `invitations@linkedin.com` "{Name} accepted your invitation" and `messages-noreply@linkedin.com` "{Name} sent you a message" are matched by name to referrals in state `requested` or `asked`.

### C.7 Personalisation, grounded

`outreach/drafts.py` reuses the cover-letter machinery:
- `allowed_sources` = profile facts, stories, `raw_text`, job title, job description (mode a), company name and domain, **company evidence snippets** (the homepage meta and about text we fetched; mode b), the contact's name and title.
- `candidate_sources` (for first-person sentences) = profile, stories and the company/role names, as in `cover_letter.candidate_sources`.
- On top of `fact_check`, there are rules specific to outreach:
- nothing about the recipient beyond their name, title and team unless an evidence snippet supports it, so no "loved your talk" made up;
- mode (b) may not say "I applied";
- never claim someone referred the user unless a referral record says so;
- one ask per email.
- There is one regeneration with feedback, as `generate_cover_letter` does. If the draft is still unsupported, it is saved with `grounded = 0` and the UI shows the unsupported phrases highlighted. **Approval is blocked** until the user edits the text: user edits are re-checked, and the user may click "These are true" to override, which is recorded on the message.
- Word limits: first email 110, follow-up 60, connection note 300 characters, referral DM 120 words.
- Prompts per kind: `application_followup`, `prospect`, `followup`, `linkedin_connect_note`, `linkedin_referral_dm`, `referral_email`.

---

## D. Compliance and ethics

This is not legal advice. The owner should get a one-hour review before Phase 3.

**Positioning.** This is one-to-one outreach by an individual job seeker, in their own name, from their own mailbox, at low volume, to business addresses, about a job. That is the most defensible kind of cold email. The design keeps it that way: no bulk mail, no tracking, no hidden identity.

- **CAN-SPAM (US).** It applies to "commercial electronic mail" whose primary purpose is advertising a product or service. A job seeker's email is very likely outside it, but we follow its core rules anyway: accurate From and Subject, a working opt-out honoured immediately (the law allows 10 business days), no deceptive "Re:". We don't add a postal address (that requirement is for commercial senders); this is noted as a conscious choice.
- **GDPR / UK GDPR (EU/UK recipients).** Lawful basis is **legitimate interest** (Art. 6(1)(f)): a job seeker contacting business staff about recruiting, in their professional role, which they can reasonably expect. Safeguards that make the balancing test hold:
- business contact data only;
- the source is disclosed in the footer (Art. 14);
- easy opt-out, honoured permanently;
- minimisation (B.5 stores nothing else);
- retention: contacts with no thread for 12 months are deleted automatically, threads after 24 months.

The household exemption probably does not cover job seeking, so don't rely on it. ePrivacy: UK PECR allows unsolicited email to corporate addresses with opt-out. Some EU states (e.g. Germany) are stricter about unsolicited advertising, but recruiting outreach by an individual isn't advertising; still, keep volume low and opt-out honest.
- **India, DPDP Act 2023 (Rules notified Nov 2025, being phased in).**
- The individual user's own use is largely exempt as personal purpose (s.3(c)(i)). Data that the person made or caused to be made publicly available is outside the Act (s.3(c)(ii)), which covers contacts from their own team page or GitHub.
- **Pattern-inferred emails are not "made public by the data principal".** For the shared library, the owner would be a **Data Fiduciary** for any data that isn't exempt. This drives the shared-library rule in E: share patterns and published contacts, never guessed addresses.
- The library operator needs: a notice, a grievance contact, erasure on request, breach notification to the Data Protection Board and to affected people, reasonable security, and a deletion schedule.
- Host the data in India (Supabase `ap-south-1`, Mumbai) to avoid cross-border questions.
- **Honest identity and AI.** Every email is sent as the user, from the user's mailbox, after the user approved the exact text. No pretending to be a recruiter or referrer, no fake urgency. AI drafting needs no disclosure because the user is the author of record, and the fact-check keeps it truthful.
- **Deletion.** Settings ▸ Outreach ▸ Data has "Delete all contacts", "Delete contacts older than…" (both `delete_contacts`; "older than" never deletes contacts the user typed or imported, and neither touches a contact in a live conversation), and per-contact delete (with "never email"). Deleting a contact keeps only the hash entry in the do-not-contact list.

### D.1 The shared library: plainly stated risks

1. **This is third-party personal-data sharing.** Pooling everyone's contacts turns individual outreach into a contact database run by the owner. That is the activity regulators care about (data brokerage), and the people listed never agreed to it.
2. **Abuse:** a "universal list" is valuable to spammers and recruiters-for-hire. A user who reaches 10 contacts could join and then scrape everything.
3. **Accuracy and harm:** wrong titles or guessed addresses spread errors, and they spread opt-out violations if removal doesn't reach everyone.
4. **Platform terms:** data taken from LinkedIn search snippets is arguably LinkedIn-derived; pooling it is riskier than one person using it.

**Mitigations designed in (E):**
- share only **business** contact data with **public provenance** (URL plus observation date);
- share domain **patterns**, which are not personal data, instead of guessed addresses;
- no free-mail domains; contributions are opt-in and per contact (manual "people I know" contacts are private by default);
- **global removal** honoured by every client within 24 hours (a list of hashed addresses synced to all users, including those without access);
- per-company lookup only, never bulk export, with daily and monthly limits;
- an audit log and decoy records to trace leaks;
- 90-day access grants the admin can revoke at any time;
- terms of use banning resale and bulk mailing;
- 18-month retention unless re-confirmed.

---

## E. Shared library (Supabase): build later

### E.1 Auth

- Supabase Auth with **email OTP**: a 6-digit code typed into the app. This avoids a deep-link URL scheme for magic links. GitHub OAuth is optional later.
- Tokens: the refresh token goes in Keychain (service `AutoApply Share`). The **daemon** performs sync (`outreach/share_sync.py`, httpx against PostgREST RPC) because it owns the data. The app only runs the login UI and passes the session to the daemon with `share_sign_in {access_token, refresh_token}`.
- Region: `ap-south-1`.

### E.2 Tables

```sql
-- members (1:1 auth.users)
create table members (
user_id uuid primary key references auth.users on delete cascade,
display_name text,
role text not null default 'member' check (role in ('member','admin')),
sharing_opt_in boolean not null default false,
opted_in_at timestamptz,
terms_version text,                       -- accepted terms of use
status text not null default 'active' check (status in ('active','suspended')),
created_at timestamptz not null default now()
);

-- company-level data (not personal): domain + email pattern
create table lib_domains (
domain text primary key,                  -- lowercase, punycode
company_name text,
pattern text,                             -- 'first.last' etc.
pattern_confidence int check (pattern_confidence between 0 and 100),
evidence_count int not null default 0,
mx_provider text check (mx_provider in ('google','microsoft','other','none')),
bounce_count int not null default 0,
updated_at timestamptz not null default now()
);

-- people with PUBLIC provenance only
create table lib_contacts (
id bigint generated always as identity primary key,
email_norm text not null unique,          -- lower(trim(nfkc(email)))
email_hash text not null unique,          -- sha256(email_norm), for suppression joins
domain text not null references lib_domains(domain),
full_name text not null,
title text,
role_category text check (role_category in ('recruiter','talent_lead','hiring_manager','eng_leader','engineer','founder','role_mailbox','other')),
source_kind text not null check (source_kind in ('company_page','job_posting','github','provider_verified','reply_confirmed')),
source_url text,                          -- required unless reply_confirmed
observed_at timestamptz not null,
first_contributor uuid references members(user_id) on delete set null,
status text not null default 'active' check (status in ('active','bounced','removed')),
is_canary boolean not null default false, -- honeytoken (never shown as such)
last_confirmed_at timestamptz,
created_at timestamptz not null default now()
);

create table contributions (
id bigint generated always as identity primary key,
user_id uuid not null references members(user_id) on delete cascade,
contact_id bigint references lib_contacts(id) on delete set null,
email_hash text not null,
submitted_at timestamptz not null default now(),
outcome text not null check (outcome in ('accepted_new','accepted_evidence','duplicate','rejected')),
reject_reason text,
unique (user_id, email_hash)
);

create table access_requests (
id bigint generated always as identity primary key,
user_id uuid not null references members(user_id) on delete cascade,
status text not null default 'pending' check (status in ('pending','approved','denied','revoked','expired')),
credited_count_at_request int not null,
message text,
decided_by uuid references members(user_id),
decided_at timestamptz,
expires_at timestamptz,                   -- approved grants: now() + 90 days
created_at timestamptz not null default now()
);

create table global_suppression (
email_hash text primary key,
reason text not null check (reason in ('removal_request','opt_out','hard_bounce','admin')),
created_at timestamptz not null default now()
);

create table removal_requests (              -- from the public removal page
id bigint generated always as identity primary key,
email_hash text not null,
verified_at timestamptz,                  -- OTP sent to that address and confirmed
created_at timestamptz not null default now()
);

create table lookup_usage (
user_id uuid not null references members(user_id) on delete cascade,
day date not null,
lookups int not null default 0,
primary key (user_id, day)
);

create table audit_log (                     -- append-only (revoke update/delete; trigger raises)
id bigint generated always as identity primary key,
at timestamptz not null default now(),
actor uuid,
action text not null,                     -- contribute|lookup|request_access|approve|deny|revoke|remove|suspend
target text,
meta jsonb not null default '{}'
);
```

### E.3 RLS and access paths

- RLS is **enabled on every table**.
- `lib_contacts` and `contributions` have **no select policy** for members. All reads go through `security definer` RPCs, so there is no table endpoint to page through.
- `members`: a user can select and update their own row (`sharing_opt_in`, `display_name`, `terms_version`). `role` and `status` can only be changed by an admin (column-level check in an `update` trigger).
- `access_requests`: a user can select their own rows and insert where `user_id = auth.uid()`. A `before insert` trigger requires `credited_count(auth.uid()) >= 10`, no open pending or approved request, and sets `credited_count_at_request`. Only an admin can update.
- `global_suppression`: any authenticated user can select it. It contains hashes only and is synced to all clients.
- `lib_domains`: any member who opted in to sharing can select it. Patterns are company data and the main reward for contributing.
- RPCs:
- `contribute(contacts jsonb)`: at most 100 per call and 300 per day. It validates server-side:
  - the email domain has MX (a Supabase edge function does the DNS lookup);
  - the domain is not free-mail;
  - the address is not on `global_suppression`;
  - `source_kind` is allowed and `source_url` is on the email's domain, a known ATS host or github.com;
  - name and title are plausible (length, no URLs, no emails in the name);
  - role mailboxes are capped at 3 per domain.

  It upserts by `email_norm`. The first contributor of a new address gets `accepted_new`; a later contributor adding a newer `observed_at` or a different `source_kind` gets `accepted_evidence` (no credit). It updates `lib_domains` pattern evidence and writes `audit_log`.
- `my_contributions()`: the caller's accepted contacts. Users can always see what they contributed.
- `lookup_company(domain text)`:
  - Without access: returns the caller's own contributions for that domain plus `lib_domains`.
  - With an approved, unexpired grant: also returns up to 15 active, non-suppressed `lib_contacts` for the domain, sorted by role.
  - Limits: 30 lookups/day and 300/30 days per user, counted in `lookup_usage`; past the limit it raises `rate_limited`.
  - Logs every call. Returns 1–2 decoy contacts on some domains, unique per user (`is_canary`). Those addresses forward to an admin mailbox, so a leaked list can be traced to one account.
- `request_removal(email)` / `confirm_removal(token)`: public, behind an edge function with an OTP to the address. It inserts into `global_suppression`, sets `lib_contacts.status = 'removed'` and erases name, title and URL.

### E.4 The contribution counting rule

`credited_count(user)` = `count(*) from contributions where user_id = user and outcome = 'accepted_new' and contact is still active` (bounced or removed contacts stop counting).

- Only addresses that were **new to the library** count, so re-uploading a popular list earns nothing.
- Junk is rejected before counting.
- A contact the user received a reply from (`reply_confirmed`) counts even without a URL. Locally this is upload-eligible only if the user ticks share; the reply proves the address works but is not consent. Keeping `reply_confirmed` in v1 is open question 2.

The threshold is **≥ 10**. Renewal after 90 days needs ≥ 5 new credited contributions in that period, which keeps people contributing and limits one-time scrapers.

### E.5 Admin workflow

- **v1: the Supabase dashboard.**
- The view `admin_pending_requests` (joined with member email, credited count, recent contributions, rejection rate, lookups so far) is shown in Table Editor. The admin sets `status = approved | denied`.
- A `before update` trigger fills `decided_by = auth.uid()` and `decided_at`, sets `expires_at = now() + 90 days` on approval, and writes `audit_log`.
- A database webhook calls an edge function that emails the admin when a new request arrives and the user when it is decided (via Resend).
- Revoking means setting `status = 'revoked'`. Suspending means setting `members.status = 'suspended'`, which makes every RPC refuse.
- **Later:** a small admin section in the app, shown only when `members.role = 'admin'`.
- **Automatic flags:** a nightly SQL job flags users at ≥ 80% of the daily lookup limit for 5 consecutive days, users with a > 30% contribution rejection rate, and any decoy address that receives mail. Flags go to `admin_flags` for review.

### E.6 How the local app syncs

1. **Opt in** in Settings ▸ Outreach ▸ Shared library: sign in with email OTP, accept the terms of use, and turn on "Share my contacts".
2. **Eligible to upload:** contacts whose best email evidence has a public source on the company domain, an ATS host or GitHub, or `provider_verified`, or `reply_confirmed`; with `share_ok = 1`; not on the local or global do-not-contact list. Manual contacts default to `share_ok = 0`.
3. **Fields uploaded:** `email, full_name, title, role_category, domain, source_kind, source_url, observed_at`. **Never uploaded:** notes, outreach text, reply content, thread state, the user's profile, LinkedIn URLs.
4. **Signals uploaded anonymously:** hard bounces (`email_hash` → `bounced`) and opt-outs (→ `global_suppression`). This helps everyone and is the least that honouring opt-outs requires.
5. **Schedule:** upload is incremental (`contacts.shared_at`) once a day in maintenance. `global_suppression` is pulled daily: matches are added to the local do-not-contact list, and contacts with `origin = 'shared'` are deleted locally. Lookups happen on demand during a scout, after local sources and before paid providers.
6. **Merge rules:** dedupe by `email_norm`. Local data wins for display, and library data is added as an evidence row (`kind = 'shared_library'`). A conflicting title keeps the newest `observed_at`.

---

## F. LinkedIn referrals

**Candidly:** automating connection requests or messages violates LinkedIn's User Agreement, which forbids bots and automated methods to access the service, send messages or add connections. LinkedIn detects automation, including CDP/Playwright fingerprints and odd timing, and restricts or bans accounts. For a job seeker, losing their LinkedIn account is far worse than any referral is worth. AutoApply never automates LinkedIn, and this plan keeps it that way: the gate in `apply/agentic.py` stays unchanged.

### F.1 Recommended: the referral copilot (human sends)

**Finding referrers** (`outreach/referrals.py`), through Google results only (people-finder budget), never by opening LinkedIn:
- **Alumni:** `site:linkedin.com/in "{company}" "{school}"` for each `profile.education[].school`.
- **Ex-colleagues:** `site:linkedin.com/in "{company}" "{previous employer}"` for each `profile.work_history[].company`.
- **Same team:** `site:linkedin.com/in "{company}" "{function keyword}" "{city}"`.
- **Manual:** the user marks any contact as "could refer me".

The result title is parsed into name, title and company. A **basis** is kept only when the result snippet contains the school or employer text, which is stored as evidence. Ranking: shared employer, then shared school, then same function; within that, peers and seniors rank above executives.

**Drafting:** a connection note of at most 300 characters (grounded: the shared basis plus one line on why) and a later referral message (at most 120 words, with the job link and req ID if known, and the resume headline). Note that free LinkedIn accounts can send only a few personalised invitation notes a month, so the note is optional and the UI says "Send without a note" is fine.

**States:** `suggested → to_connect → requested → connected → asked → referred | declined | no_response`, plus `dismissed`.

**User actions** in the Referrals tab:
- **Copy note & open profile.** The note goes to the clipboard (`NSPasteboard`) and the profile URL opens in the user's **default browser** (`NSWorkspace.open`), not the agent Chrome. Then a prompt "Did you send it?" sets `requested`.
- **Mark connected.** This also happens automatically from LinkedIn's "accepted your invitation" email (C.6).
- **Copy referral message & open messages.** Sets `asked`.
- **Mark referred / declined.** `referred` adds a note on the application and, if the job isn't applied yet, suggests applying through the referral link.
- **Reminders:** `connected` for more than 2 days without `asked` shows "Ask {name} for a referral"; `requested` for more than 14 days becomes `no_response`.

**Pacing guidance (advice, not automation):** the UI suggests no more than 5 connection requests a day and shows "sent this week", because LinkedIn limits weekly invitations.

If a work email is known for the person, "Ask by email instead" turns the referral into a normal outreach thread (kind `referral_email`).

### F.2 "Assisted" mode, described but not recommended

The agent Chrome, which is already logged in for read-only discovery, would open the profile, click Connect, and paste the note, and the user would click Send. **Risks:**
- it is still automated interaction under LinkedIn's terms;
- detection risks the user's real professional account;
- it would need a hole in `BLOCKED_HOSTS` that weakens the guarantee the whole codebase relies on;
- LinkedIn changes its DOM often, so it would be fragile.

**Do not build.** The copilot captures about 90% of the value at no account risk.

---

## G. What we build now (everything except Supabase)

### G.1 Engine modules

New package `engine/autoapply/outreach/`:

| Module | Responsibility |
|---|---|
| `contacts.py` | CRUD, `normalize_email`, dedupe/merge, `recompute_confidence`, `role_category` classification, retention purge |
| `domains.py` | domain resolution (B.2), MX lookup and caching in `domain_patterns` (new dependency `dnspython`) |
| `patterns.py` | pure pattern inference (B.4) |
| `scout.py` | `ContactScout`: source order, budgets (`db.increment_source_sessions(conn, "people_finder")`), early stop, events |
| `sources/posting.py`, `sources/site_pages.py`, `sources/github_org.py`, `sources/google_people.py` | B.3 #2–5 (`google_people` reuses `HumanPacer`, `detect_page_state` and `_unwrap_google` from the discovery modules) |
| `providers/base.py`, `providers/hunter.py` | `EmailProvider` protocol and Hunter (Phase 2) |
| `drafts.py` | grounded drafting per kind, reusing `cover_letter.fact_check`, `allowed_sources`, `candidate_sources`, `profile_facts`, `story_text` |
| `sender.py` | `OutreachSender` loop: due messages, caps, window, spacing, pre-write `sending`, recovery |
| `mailwatch.py` | IMAP reply/bounce/auto-reply/LinkedIn-notification scanning and classification |
| `suppression.py` | checks and writes for the do-not-contact list |
| `prospects.py` | company search (A.3), enrichment, fit scoring |
| `referrals.py` | referrer finding, state machine, drafts |
| `service.py` | `OutreachService` owned by the daemon: scout queue, hooks, loops |

Also `mail/smtp_send.py` (compose the message, send, test send) next to `imap_codes.py`, sharing its Keychain helpers. Move `_login` and `_text` into `mail/common.py`.

### G.2 Schema v10

Added to `contract/schema.sql` and as migration `10: "python:_migrate_v10"` in `db.py`. `SCHEMA_VERSION = 10`.

```sql
CREATE TABLE IF NOT EXISTS contacts (
id INTEGER PRIMARY KEY AUTOINCREMENT,
company_id INTEGER REFERENCES companies(id) ON DELETE CASCADE,
full_name TEXT NOT NULL, first_name TEXT, last_name TEXT,
title TEXT,
role_category TEXT NOT NULL DEFAULT 'other' CHECK (role_category IN ('recruiter','talent_lead','hiring_manager','eng_leader','engineer','founder','role_mailbox','other')),
email TEXT, email_norm TEXT,
email_status TEXT NOT NULL DEFAULT 'none' CHECK (email_status IN ('none','pattern','published','provider_verified','user','delivered','replied','bounced')),
email_confidence INTEGER NOT NULL DEFAULT 0 CHECK (email_confidence BETWEEN 0 AND 100),
role_fit INTEGER CHECK (role_fit IS NULL OR role_fit BETWEEN 0 AND 100),
linkedin_url TEXT, github_login TEXT, location TEXT,
origin TEXT NOT NULL CHECK (origin IN ('scout','user','import','shared')),
relationship TEXT CHECK (relationship IS NULL OR relationship IN ('friend','ex_colleague','alumni','met','other')),
share_ok INTEGER NOT NULL DEFAULT 0 CHECK (share_ok IN (0,1)),
shared_at TEXT,
notes TEXT,
last_contacted_at TEXT,
created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contacts_email ON contacts(email_norm) WHERE email_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_contacts_company ON contacts(company_id);

CREATE TABLE IF NOT EXISTS contact_evidence (
id INTEGER PRIMARY KEY AUTOINCREMENT,
contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
kind TEXT NOT NULL CHECK (kind IN ('user','job_posting','company_page','github','google_serp','pattern','provider','shared_library','reply','bounce')),
field TEXT NOT NULL CHECK (field IN ('name','title','email')),
url TEXT, snippet TEXT, provider TEXT,
observed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS ix_contact_evidence_contact ON contact_evidence(contact_id);

CREATE TABLE IF NOT EXISTS domain_patterns (
domain TEXT PRIMARY KEY,
company_id INTEGER REFERENCES companies(id) ON DELETE SET NULL,
pattern TEXT, confidence INTEGER NOT NULL DEFAULT 0,
samples TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(samples)),   -- [{name,email,source,url}]
mx_provider TEXT CHECK (mx_provider IS NULL OR mx_provider IN ('google','microsoft','other','none')),
bounces INTEGER NOT NULL DEFAULT 0,
checked_at TEXT
);

CREATE TABLE IF NOT EXISTS outreach_threads (
id INTEGER PRIMARY KEY AUTOINCREMENT,
kind TEXT NOT NULL CHECK (kind IN ('application','prospect','referral_email')),
contact_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
company_id INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
job_id INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
application_id INTEGER REFERENCES applications(id) ON DELETE SET NULL,
state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','active','replied','bounced','opted_out','closed','cancelled')),
outcome TEXT CHECK (outcome IS NULL OR outcome IN ('positive','referred','not_interested','question','other')),
subject TEXT, gmail_thread_id TEXT,
next_action_at TEXT, unread_reply INTEGER NOT NULL DEFAULT 0 CHECK (unread_reply IN (0,1)),
created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS ix_outreach_threads_state ON outreach_threads(state);
CREATE INDEX IF NOT EXISTS ix_outreach_threads_application ON outreach_threads(application_id);

CREATE TABLE IF NOT EXISTS outreach_messages (
id INTEGER PRIMARY KEY AUTOINCREMENT,
thread_id INTEGER NOT NULL REFERENCES outreach_threads(id) ON DELETE CASCADE,
seq INTEGER NOT NULL DEFAULT 0,
direction TEXT NOT NULL CHECK (direction IN ('out','in')),
state TEXT NOT NULL CHECK (state IN ('draft','approved','scheduled','sending','sent','failed','unknown','cancelled','received')),
to_email TEXT, subject TEXT, body TEXT NOT NULL,
origin TEXT NOT NULL DEFAULT 'generated' CHECK (origin IN ('generated','user')),
grounded INTEGER NOT NULL DEFAULT 1 CHECK (grounded IN (0,1)),
unsupported_claims TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(unsupported_claims)),
claims_overridden INTEGER NOT NULL DEFAULT 0 CHECK (claims_overridden IN (0,1)),
story_ids TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(story_ids)),
message_id_header TEXT, in_reply_to TEXT,
batch_uid TEXT, approved_at TEXT, send_at TEXT, sent_at TEXT,
classification TEXT, error TEXT,
tokens_in INTEGER NOT NULL DEFAULT 0, tokens_out INTEGER NOT NULL DEFAULT 0,
created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS ix_outreach_messages_due ON outreach_messages(state, send_at);
CREATE UNIQUE INDEX IF NOT EXISTS ux_outreach_messages_mid ON outreach_messages(message_id_header) WHERE message_id_header IS NOT NULL;

CREATE TABLE IF NOT EXISTS suppression (
id INTEGER PRIMARY KEY AUTOINCREMENT,
email_norm TEXT, domain TEXT,
reason TEXT NOT NULL CHECK (reason IN ('opt_out','hard_bounce','user','shared_removal','complaint')),
source TEXT, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
CHECK (email_norm IS NOT NULL OR domain IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_suppression_email ON suppression(email_norm) WHERE email_norm IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_suppression_domain ON suppression(domain) WHERE domain IS NOT NULL;

CREATE TABLE IF NOT EXISTS referrals (
id INTEGER PRIMARY KEY AUTOINCREMENT,
company_id INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
job_id INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
contact_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
person_name TEXT NOT NULL, title TEXT, linkedin_url TEXT,
basis TEXT NOT NULL CHECK (basis IN ('alumni','ex_colleague','same_function','user','other')),
basis_detail TEXT, evidence_url TEXT, evidence_snippet TEXT,
state TEXT NOT NULL DEFAULT 'suggested' CHECK (state IN ('suggested','to_connect','requested','connected','asked','referred','declined','no_response','dismissed')),
connect_note TEXT, referral_dm TEXT,
state_updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_referrals_person ON referrals(company_id, linkedin_url) WHERE linkedin_url IS NOT NULL;

CREATE TABLE IF NOT EXISTS prospects (
id INTEGER PRIMARY KEY AUTOINCREMENT,
company_id INTEGER NOT NULL UNIQUE REFERENCES companies(id) ON DELETE CASCADE,
status TEXT NOT NULL DEFAULT 'suggested' CHECK (status IN ('suggested','shortlisted','contacted','dismissed')),
fit_score INTEGER CHECK (fit_score IS NULL OR fit_score BETWEEN 0 AND 100),
fit_reasons TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(fit_reasons)),
summary TEXT, summary_url TEXT,           -- evidence for drafts
found_via TEXT, search_query TEXT,
cooldown_until TEXT,
created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
```

Preference columns added by the same migration (Python `ALTER`s, as in v9): `outreach_auto_scout` (1), `outreach_auto_draft` (1), `outreach_daily_cap` (10, CHECK 0–40), `outreach_followup_days` (5), `outreach_max_followups` (1, CHECK 0–2), `outreach_send_window` (`'["09:30","17:30"]'`), `outreach_weekdays_only` (1), `outreach_min_email_confidence` (60), `people_finder_visits_per_day` (6). Mirror them in `config.Preferences` and `models.Preferences`.

The `runs.kind` CHECK is **not** changed: outreach work is not a run kind (rebuilding the table isn't worth it). Outreach state changes write `events` rows with `kind = 'outreach'` and `thread_id` in the payload, so the Activity log shows them.

### G.3 Protocol (models.py, generated Swift)

Add `_P` payload models and register them in `COMMAND_PAYLOADS` / `EVENT_PAYLOADS`. Add one example of each to `contract/protocol.examples.ndjson`, document them in `protocol.md` §5/§6, then regenerate (`uv run python -m autoapply.models && uv run python scripts/gen_swift_messages.py`).

Commands:

| type | payload | ack.result |
|---|---|---|
| `scout_contacts` | `company_id?`, `application_id?`, `purpose` (`application`\|`prospect`\|`referral`) | `{company_id, queued_google: bool}`; progress via events |
| `add_contact` | `company_id?`, `company_name?`, `full_name`, `email?`, `title?`, `linkedin_url?`, `relationship?`, `notes?`, `share_ok` (false) | `{contact_id, merged}` |
| `update_contact` | `id` + partial fields | `null` |
| `delete_contact` | `id`, `suppress` (true) | `null` |
| `delete_contacts` | `ids?`, `older_than_days?`, `all` (false), `suppress` (false) | `{deleted, skipped_active}`; typed / imported contacts only by `ids` or `all`; live conversations skipped (protocol.md §5.1) |
| `import_contacts` (P2) | `file_path` | `{added, merged, skipped}` |
| `draft_outreach` | `contact_id`, `kind`, `application_id?`, `instructions?` | `{thread_id, message_id, grounded, unsupported_claims}` |
| `edit_outreach_draft` | `message_id`, `subject?`, `body`, `confirm_claims` (false) | `{grounded, unsupported_claims}` |
| `approve_outreach` | `message_ids[]`, `include_followups` (false) | `{batch_uid, scheduled:[{message_id, send_at}]}`; `unavailable` if sending isn't enabled; `conflict` if a message is ungrounded and unconfirmed |
| `cancel_outreach` | `message_ids[]` | `{cancelled}` (scheduled → draft) |
| `discard_outreach` | `thread_id` | `null` |
| `resolve_outreach_unknown` | `message_id`, `sent` (bool) | `null` |
| `mark_reply_read` | `thread_id` | `null` |
| `set_thread_outcome` | `thread_id`, `outcome`, `close` (bool) | `null` |
| `suppress` / `unsuppress` | `email?`, `domain?`, `reason` | `null` (unsuppress refuses `opt_out`) |
| `enable_sending` | `enabled` | `{send_enabled, test_sent_to}` (sends the test email) |
| `search_prospects` (P2) | `query`, `location?` | `{search_id}` |
| `update_prospect` | `id`, `status` | `null` |
| `suggest_referrers` (P2) | `company_id`, `job_id?` | `{queued_google}` |
| `update_referral` | `id`, `state`, `connect_note?`, `referral_dm?` | `null` |
| `set_provider_key` (P2) | `provider`, `api_key?` (null clears) | `{provider, ok}` (Keychain) |

Events (few, since the app reads tables through GRDB): `outreach_state` (`thread_id`, `message_id?`, `from_state?`, `to_state`, `at`), `outreach_reply` (`thread_id`, `contact_name`, `company`, `label`, `snippet`), `scout_finished` (`company_id`, `found`, `with_email`, `best_confidence?`). `CapReachedPayload.cap` gains `outreach_daily`. `Counts` gains `outreach_drafts` and `outreach_replies_unread`, defaulting to 0.

### G.4 Daemon and pipeline hooks

- `Daemon` creates an `OutreachService(conn, llm, emit, coordinator, notifier)` and spawns `_outreach_sender_loop` (60 s tick) next to `_maintenance_loop`. `_cmd_*` handlers delegate to the service.
- Hook in `Pipeline`, at the place where an application becomes `submitted` (`click_submit`, `mark_applied`, `mark_easy_apply_done`): `service.on_submitted(application_id)`, which queues a scout if `outreach_auto_scout` is on.
- **Full run:** a new final step `_step_outreach` runs the Google parts of queued scouts, referrer searches and prospect searches within the people-finder and prospect-finder budgets, using the same browser factory as `company_finder`.
- `Pipeline.maintenance()` calls `service.maintenance()`: mail watch (every 10 min), follow-up creation, `connected → ask` reminders, retention purge (daily), the ramp counter.
- `db.recover_after_crash()` also moves `outreach_messages.state = 'sending'` to `unknown`. The service resolves these through the Sent Mail check at startup.
- `pause_all` is respected by the sender and the scout.
- Notifications through the existing `Notifier`: "Jane at Acme replied", and "6 drafts ready to review" (at most once a day).

### G.5 Model tasks (structured, not autonomous)

All go through `LLMProvider.complete(prompt, system, schema)`, recorded in token counts: `extract_people(page_text, company)`, `classify_title(title, job)` (role category and fit), `prospect_queries(query, prefs)`, `extract_companies(page_text)`, `prospect_fit(company_summary, profile)`, `classify_reply(text)`, and drafting. **No new tools for the browser agent.** The apply agent's toolbox does not change.

### G.6 App

- **Data:** in `GRDBRepository` and `AppRepository` add `contacts()`, `contactEvidence(contactID)`, `outreachThreads()`, `outreachMessages(threadID)`, `referrals()`, `prospects()`, `suppression()`, plus `InMemoryRepository` and Mock fixtures. Domain types go in `DomainModels.swift`. A new `Core/Store/OutreachStore.swift` holds them, and command wrappers go in `AppStore+Commands.swift`.
- **Cold Email screen** (replace the `ColdEmailView` placeholder; `ColdEmailFeature` registration stays). A segmented control with:
- **Follow-ups:** submitted applications with outreach status (no contact / contacts found / draft / scheduled / sent / replied), best contact and its confidence, and actions Find people, Draft, Open thread.
- **Prospects:** search box (P2), list with fit score, Shortlist / Watch / Dismiss; a detail pane with the company summary (with source link) and contacts.
- **Contacts:** a table (name, title, company, email with tier badge, origin, last contacted), a provenance popover, Add contact, Import (P2), and a Suppress / Delete menu.
- **Outbox:** sections Drafts (multi-select → Send N… sheet), Scheduled (with Cancel), Sent, Replies. The editor shows unsupported claims highlighted, a fact-check status, a contact switcher and the footer preview.
- **Referrals:** grouped by state; buttons "Copy note & open profile" and "Copy message & open", plus state controls.
- **Needs You:** a new **Replies** section (threads with an unread reply; Open in Gmail via `https://mail.google.com/mail/u/0/#search/rfc822msgid%3A<id>`; suggested board move), plus **Possibly sent** items for `unknown` messages.
- **Board / Job inspector:** an envelope badge on `JobCard` (emailed / replied); an Outreach section in `JobInspector` with the thread and a "Reach out" button.
- **Settings ▸ Outreach** (new tab in `SettingsTabs.swift`):
- Sending: the `MailAccountRow` status, the Enable sending toggle with test send, daily cap, window, weekdays only, follow-ups (count and days), minimum email confidence, auto-scout and auto-draft toggles, people-finder budget;
- Providers: Hunter key (P2);
- Do-not-contact list editor;
- Data: delete or retention controls.
- Update the placeholder copy that promises "never a sequence of follow-ups" to "At most one gentle follow-up, only if you approve it."

### G.7 Tests

- **Pure** (`tests/a_core/test_outreach_*.py`):
- pattern inference from sample pairs, including Indian name forms and ambiguous parses;
- the confidence table;
- `normalize_email`;
- checks against the do-not-contact list;
- composing the message (headers, `In-Reply-To` / `References`, footer present, no HTML);
- send-window and spacing scheduler with an injected clock (caps carried over to the next day, ramp);
- message and referral transition tables.
- **Parsers:** HTML fixtures for team pages, JSON-LD, security.txt, Google people result pages (LinkedIn-titled results, CAPTCHA page); GitHub API JSON fixtures via `respx`; DSN bounce fixtures (Gmail 5.1.1, 4.x delay); auto-reply fixtures; LinkedIn notification email fixtures.
- **Anti-hallucination:** `FakeLLMProvider` returns a person not on the page, and the scout drops it. A draft with an invented metric fails `fact_check` and approval is refused.
- **Daemon** (`tests/d_daemon/test_outreach.py`): `approve_outreach` → sender (fake SMTP via a `smtplib.SMTP` double) → `sent`; crash during `sending` → `unknown` → Sent Mail lookup on a fake IMAP resolves it; a reply cancels the follow-up and blocks auto-ghost; an opt-out reply adds to the do-not-contact list; pause stops sending; cap reached emits `cap_reached{outreach_daily}`.
- **Migration:** v9 DB → v10 keeps data; schema.sql and migrations produce the same table definitions (extend the existing test).
- **Protocol:** new examples decode in both Python and Swift test suites; `protocol.schema.json` is regenerated.
- **Swift:** `OutreachStore` and model tests with `InMemoryRepository`; snapshot tests of the Outbox editor states.
- **Safety regression:** referral code never calls a navigate tool with a linkedin.com host. Assert `BLOCKED_HOSTS` is unchanged and that the scout's browser wrapper refuses LinkedIn URLs.

### G.8 Phases

**Phase 1 (shippable, about 2–3 weeks):**
- v10 schema and preferences;
- manual contacts;
- the scout with posting, company pages, GitHub, Google people results, patterns and MX;
- drafting with fact-check for mode (a) and for mode (b) on companies the user picks (watchlist or typed);
- Outbox with batch approval;
- Gmail SMTP sender with caps, window, ramp and crash recovery;
- one follow-up;
- IMAP replies, bounces, auto-replies and opt-outs;
- do-not-contact list;
- Needs You Replies;
- tabs: Follow-ups, Contacts, Outbox, plus Settings ▸ Outreach.

**Phase 2:**
- Prospects tab with company search and fit scoring;
- the referral copilot (plus LinkedIn notification email detection);
- Hunter provider;
- CSV import;
- job-card badges and the inspector section (if not done in Phase 1).

**Phase 3:** the Supabase shared library (E), after the owner settles questions 1, 5 and 6 and gets a legal review.

**Later:** an admin panel in the app; Apollo provider; Outlook sending (only if Microsoft SMTP AUTH with an app password proves workable).

---

## H. Open questions for the owner (only ones that change the design)

1. **Shared library contents:** may it hold pattern-guessed emails, or only published, provider-verified or reply-confirmed contacts plus domain patterns? I recommend the latter, because it is what makes DPDP and GDPR defensible.
2. **Counting rule:** should the 10 count only contacts that are new to the library (recommended; it resists gaming), and do reply-confirmed contacts with no public URL count?
3. **Follow-ups:** the current screen promises none. Is one follow-up by default (recommended, still user-approved) acceptable, or should the default be zero?
4. **Sending providers:** is Gmail and Google Workspace enough for v1? Outlook would need different auth work.
5. **Universal access terms:** time-limited 90-day grants renewed by ongoing contribution (recommended), or permanent until revoked?
6. **Who operates the library:** which legal entity or person is the data fiduciary and grievance contact, and where do removal requests go? This must be settled before Phase 3.
7. **Default automation:** auto-scout and auto-draft after every submitted application (spends Google budget and tokens, but drafts are ready when the user looks), or only on demand?

---

## Decisions (owner, 2026-10-21)

- **Q3 Follow-ups:** one follow-up by default (~5 business days), only sent with the user's approval; stops on reply / opt-out. Update the placeholder copy accordingly.
- **Q7 Default automation:** auto-scout and auto-draft after every submitted application are **on** by default (30-day per-company cache; nothing is sent without approval).
- **Scope of this build:** Phase 1 **and** Phase 2 (company search + fit scoring, referral copilot, Hunter provider, CSV import, job-card badges + inspector section). Phase 3 (Supabase) stays design-only.
- Q1, Q2, Q4, Q5, Q6 are open; they only affect Phase 3 except Q4 (Gmail / Google Workspace only in v1, as recommended).
