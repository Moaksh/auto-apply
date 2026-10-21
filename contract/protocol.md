# AutoApply socket protocol (v1)

Frozen contract between **AutoApply.app** (Swift) and **autoapplyd** (Python).
Machine-readable form: [`protocol.schema.json`](protocol.schema.json) (JSON Schema 2020-12,
**generated** from `engine/autoapply/models.py` via `uv run python -m autoapply.models`).
One example of every message: [`protocol.examples.ndjson`](protocol.examples.ndjson)
(both the Python and Swift test suites decode it).

DB schema: [`schema.sql`](schema.sql). Swift mirror: `app/Sources/AutoApply/Core/Protocol/Messages.swift`.

---

## 1. Transport

- Unix domain socket at `<home>/autoapplyd.sock` (`<home>` = `~/Library/Application Support/AutoApply`,
  or `$AUTOAPPLY_HOME`). File mode `0600`. Multiple clients may connect (app + CLI).
- **NDJSON**: one UTF-8 JSON object per line, terminated by `\n`. No embedded newlines
  (JSON-escape them). Max line length 8 MiB (screenshot thumbnails are ≤ 720px JPEG).
- The daemon runs without the app; the app connects/disconnects freely and reconnects with
  backoff (0.5, 1, 2, 5 s).
- **Daemon is the only DB writer.** The app reads SQLite read-only (GRDB) and performs every
  mutation with a command below.

## 2. Envelope

```json
{ "v": 1, "id": "3f9c…", "type": "approve", "payload": { "application_ids": [11] } }
{ "v": 1, "id": "8a1d…", "type": "ack", "reply_to": "3f9c…", "payload": { "ok": true, "result": null } }
```

| field | type | notes |
|---|---|---|
| `v` | int, const `1` | protocol version. Anything else → `error` `unsupported_version`. |
| `id` | non-empty string | unique per message (uuid4 hex recommended). |
| `type` | string | a command type (app → daemon) or event type (daemon → app). |
| `payload` | object | type-specific; **unknown keys are rejected** (`invalid_payload`). |
| `reply_to` | string, events only | the `id` of the command this event answers. Commands never carry it. |

Conventions:
- Timestamps: ISO-8601 UTC strings, millisecond precision, `Z` suffix — `2026-10-10T09:00:00.000Z`.
  Decoders must also accept no fraction / offsets.
- Optional fields: the daemon always emits them (as `null` when empty). Senders may omit them; defaults apply.
- Ids: DB ids are integers (`job_id`, `application_id`, …); `cluster_id` and `run_id` are opaque strings.
- Clients must ignore unknown **event types** (forward compatibility) but the daemon rejects unknown command types.

## 3. Request / response correlation

Every command gets **exactly one** reply event with `reply_to = command.id`:

| command | success reply | failure reply |
|---|---|---|
| `hello` | `snapshot` (with `reply_to`) | `error` |
| every other command | `ack` (`result` per table in §5) | `error` |

Side-effect events caused by a command (e.g. `application_state` after `approve`) are broadcast
to all clients *without* `reply_to`, after the reply. Clients apply optimistic UI and roll back if
no reply arrives within 2 s or an `error` arrives.

### Error shape (`error` event)

```json
{ "v":1, "id":"…", "type":"error", "reply_to":"<cmd id or omitted>",
  "payload": { "code":"illegal_transition", "message":"application 13 is not awaiting review",
               "details": {"state":"queued"}, "job_id": null, "application_id": 13 } }
```

`code` ∈ `bad_request` (unparseable line/envelope), `unsupported_version`, `unknown_type`,
`invalid_payload` (details.errors = pydantic error list), `not_found`, `illegal_transition`,
`conflict` (e.g. a run already in progress), `paused`, `cap_reached`, `unavailable`
(claude CLI not logged in, Chrome missing, …), `internal`.
An `error` without `reply_to` is an unsolicited daemon problem (login expired, CAPTCHA, crash in a run).

## 4. Connection lifecycle

1. App connects and sends `hello {client:"app", client_version, protocol_version:1}`.
2. Daemon replies `snapshot` (`reply_to` = hello id): the complete live state (§6.1).
3. Daemon then streams events. The app may send commands at any time.
4. On reconnect, the app sends `hello` again and replaces its live state with the new snapshot.

## 5. Commands (app → daemon)

| type | payload | `ack.result` | notes |
|---|---|---|---|
| `hello` | `client` ("app"\|"cli"\|"test"), `client_version?`, `protocol_version` (1) | — (reply is `snapshot`) | |
| `ping` | `{}` | `null` | liveness |
| `run_now` | `kind`: `full`\|`discover`\|`prep`\|`apply` (default `full`) | `{run_id}` | `conflict` if a run is active, `paused` if paused |
| `pause_all` | `{}` | `null` | kill switch; checked between every agent step. Broadcasts `state{paused:true}` |
| `resume` | `{}` | `null` | |
| `answer_question` | `cluster_id`, `answer`, `save_to_memory` (true), `save_to_profile` (false), `per_job_answers` [`{job_id, answer}`] | `{answer_id?, resumed_application_ids}` | answer may contain `{company}`/`{role}`; `save_to_profile` writes the cluster's `never_guess_key`. Emits `question_resolved`, then `application_state` (needs_you → queued) for jobs with no other open questions |
| `skip_question` | `cluster_id`, `reason?` | `{skipped_application_ids}` | "Skip these jobs": parked jobs → skipped |
| `approve` | `application_ids` [int, ≥1] | `{application_ids}` | awaiting_review → submitting (actor user); daemon submits in background |
| `reject` | `application_id`, `reason` | `null` | awaiting_review → skipped (actor user) |
| `set_status` | `application_id`, `status` (board status) | `null` | only when state = submitted; emits `application_status` |
| `update_preferences` | `preferences`: partial `Preferences` (only keys present are applied) | `{preferences}` (full) | validated; `invalid_payload` on bad values |
| `update_never_guess` | `values`: partial `NeverGuess`; `null` value = "always ask me" (row deleted) | `{never_guess}` (full) | |
| `update_profile` | `profile`: partial `Profile` | `{profile}` | |
| `add_resume_variant` | `file_path`, `label`, `tags`, `is_default` | `{resume_variant_id}` | daemon copies the PDF into `<home>/resumes/` and extracts text |
| `update_resume_variant` | `id`, `label?`, `tags?`, `enabled?`, `is_default?` | `null` | |
| `upsert_story` | `id?` (omit = create), `title`, `situation`, `task`, `action`, `result`, `tags` | `{story_id}` | |
| `delete_story` | `id` | `null` | |
| `update_answer` | `answer_id`, `answer`, `canonical_question?` | `null` | memory editing (Profile ▸ Memory) |
| `delete_answer` | `answer_id` | `null` | |
| `edit_application_answer` | `application_answer_id`, `answer` | `null` | Review ✎: origin becomes `user` |
| `set_job_mode` | `job_id`, `mode` (`auto`\|`review`\|`null` = inherit) | `null` | per-job override |
| `retry_application` | `application_id` | `null` | failed → queued (actor user) |
| `resolve_unknown` | `application_id`, `submitted` (bool) | `null` | unknown_verify → submitted \| failed (actor user) |
| `queue_application` | `application_id`, `apply_now` (default true) | `{state, started}` | board: card dropped on Queued. discovered / scored / skipped / failed → queued (reason `user_queued`, exempt from hard filters) and starts filling unless paused. `conflict` for Easy Apply / LinkedIn-only jobs (no form to fill) and from other states |
| `mark_applied` | `application_id`, `status` (default `applied`) | `{application_id, status}` | board: "I applied myself" — a job the agent never submitted (discovered, scored, skipped, queued, needs_you) dropped on Applied or a later column: state `submitted`, mode `manual`, reason `user_applied`, board `status`; its Needs-You questions and Easy Apply row close |
| `apply_anyway` | `application_id` | `null` | skipped → queued (actor user): override a filter / threshold skip |
| `add_job_url` | `url`, `title?`, `company?`, `apply_now` (default true) | `{job_id, application_id, created, state, title, company, started}` | paste a job link: reads title/company from the page (JSON-LD / Rippling API / `<title>`), inserts it as source `manual`, queues it (reason `user_added_link`, exempt from hard filters) and starts filling unless paused. A link already stored is re-queued if skipped/failed. LinkedIn/Glassdoor links → `invalid_payload` |
| `update_job_notes` | `job_id`, `notes?` (null/empty clears) | `null` | free-form notes on Job detail (`jobs.notes`) |
| `set_application_resume` | `application_id`, `resume_variant_id` | `{requeued}` | swap the resume (Review ↻). Allowed before filling / while parked / awaiting review / failed / skipped; `conflict` while filling, submitting or after submit. awaiting_review → queued (reason `resume_swapped`) so the form is re-filled |
| `mark_easy_apply_done` | `job_id` | `{application_id}` | user applied manually; records state submitted, mode `manual`, status `applied` |
| `mark_easy_apply_opened` | `job_id` | `null` | |
| `dismiss_easy_apply` | `job_id` | `null` | |
| `open_agent_chrome` | `url?` | `null` | brings the visible agent Chrome window forward |
| `onboarding_system_check` | `{}` | `SystemCheckResult` `{items:[{name, ok, required, version?, detail?, fix_command?}], all_required_ok}` | names: `claude_cli`, `uv`, `node`, `autoapplyd`, `chrome` |
| `onboarding_parse_resume` | `file_path`, `label?` | `ParseResumeResult` `{resume_variant_id, profile, uncertain_fields}` | adds the variant and pre-fills the profile |
| `set_mail_account` | `email`, `app_password` | `{email, connected, error}` | logs in over IMAP to check; password → macOS Keychain only; used to read emailed security codes |
| `get_mail_account` | `test` (bool) | `{email, connected, error}` | `test` re-checks the login |
| `suggest_preferences` | — | `SuggestedPreferences` `{roles, seniority, locations, years_experience}` | from the stored profile; nothing is saved |
| `clear_mail_account` | — | `{email: null, connected: false}` | removes the Keychain item |
| `list_site_accounts` | — | `{accounts: [{host, email, company?, status, created_at, updated_at, job_id?}], enabled}` | job-site accounts the agent created (`preferences.create_accounts` + a connected mailbox = `enabled`); status `creating` \| `resetting` \| `active` \| `unconfirmed`. Never includes passwords |
| `reveal_site_account_password` | `host` | `{host, password}` | reads the macOS Keychain (service `AutoApply Accounts`); `not_found` if none |
| `delete_site_account` | `host` | `null` | forgets the saved login (Keychain + index); the account on the site itself stays |
| `reset_source_cap` | `source`: `linkedin`\|`glassdoor` | `{used: 0, limit}` | Settings: zero today's browsing-session counter; emits `cap_reached` (used 0) so the UI updates |
| `accept_company_suggestion` | `suggestion_id` | `{company_id}` | Settings ▸ Sources ▸ Suggested companies "Add": watches the company (its ATS board when known, else its career page as `careers_url`); suggestion → `accepted` |
| `dismiss_company_suggestion` | `suggestion_id` | `null` | "Dismiss": suggestion → `dismissed`; the company is never suggested or auto-watched again. A company the agent watched by itself (`auto`) is unwatched |
| `check_source_login` | `source`: `linkedin`\|`glassdoor` | `{connected: bool}` | "Check now": looks at the saved agent-Chrome login in a headless window (no login prompt); updates `source_status` |
| `onboarding_connect_source` | `source`: `linkedin`\|`glassdoor` | `null` | opens agent Chrome on the login page; progress via `source_status` events |
| `onboarding_set_step` | `step` (0–7) | `null` | persisted so quitting resumes the same step |
| `onboarding_complete` | `run_prep` (false) | `{run_id?}` | marks onboarding done; optionally starts a Prep pass |

#### 5.1 Cold outreach commands (schema v10; docs/COLD_EMAIL_PLAN.md)

Nothing is ever sent without `approve_outreach`. Sending stays off until `enable_sending` succeeds (a test email to the user's own address). `pause_all` stops the sender before the next email. Failures use the usual error codes: `unavailable` (sending off / no mailbox / no model / bad key), `conflict` (do-not-contact, ungrounded draft, guardrail; `details` names the message ids per problem), `illegal_transition` (wrong message / referral state), `not_found`.

| type | payload | ack.result | notes |
|---|---|---|---|
| `scout_contacts` | `company_id?`, `application_id?`, `purpose` (`application`\|`prospect`\|`referral`, default `application`) | `{company_id, queued_google}` | finds people in the background (posting, company pages, GitHub, patterns, MX now; Google results when the browser is free); result via `scout_finished` |
| `add_contact` | `company_id?`, `company_name?`, `full_name`, `email?`, `title?`, `linkedin_url?`, `relationship?` (`friend`\|`ex_colleague`\|`alumni`\|`met`\|`other`), `notes?`, `share_ok` (false) | `{contact_id, merged}` | a typed email is status `user`, confidence 100 |
| `update_contact` | `id` + any of `company_id`, `full_name`, `email`, `title`, `linkedin_url`, `relationship`, `notes`, `share_ok` (only keys present; null clears) | `null` | |
| `delete_contact` | `id`, `suppress` (true) | `null` | with `suppress` the address goes on the do-not-contact list; its pending drafts are cancelled |
| `import_contacts` | `file_path` (CSV `name,email,company,title,linkedin_url,notes`) | `{added, merged, skipped}` | deduplicated by normalized email |
| `draft_outreach` | `contact_id`, `kind` (`application`\|`prospect`\|`referral_email`), `application_id?` (required for `application`), `instructions?` | `{thread_id, message_id, grounded, unsupported_claims}` | grounded + fact-checked; re-drafting / switching contact replaces the open draft |
| `edit_outreach_draft` | `message_id`, `subject?`, `body`, `confirm_claims` (false) | `{grounded, unsupported_claims}` | re-checked; `confirm_claims` ("These are true") allows approval despite unsupported claims |
| `approve_outreach` | `message_ids[]`, `include_followups` (false), `send_anyway[]` (message ids OK'd below the confidence bar) | `{batch_uid, scheduled: [{message_id, send_at}], days: [{date, count}]}` | the only path to sending; never fails because of caps (spills to later days) |
| `cancel_outreach` | `message_ids[]` | `{cancelled}` | approved / scheduled → draft |
| `discard_outreach` | `thread_id` | `null` | only before anything was sent |
| `resolve_outreach_unknown` | `message_id`, `sent` | `null` | `unknown` → `sent` / `failed` (never resent automatically) |
| `mark_reply_read` | `thread_id` | `null` | clears `unread_reply` |
| `set_thread_outcome` | `thread_id`, `outcome?` (`positive`\|`referred`\|`not_interested`\|`question`\|`other`), `close` (false) | `null` | closing cancels pending follow-ups; an unanswered prospect thread starts a 60-day cooldown |
| `suppress` | `email?` \| `domain?`, `reason` (`opt_out`\|`hard_bounce`\|`user`\|`shared_removal`\|`complaint`, default `user`) | `null` | cancels pending emails to it |
| `unsuppress` | `email?` \| `domain?` | `null` | `conflict` for an opt-out (never removable) |
| `enable_sending` | `enabled` | `{send_enabled, test_sent_to}` | `true` sends a test email to yourself first (Gmail / Workspace only) |
| `search_prospects` | `query`, `location?` | `{search_id}` | company search on Google when the browser is free; results land in `prospects` |
| `add_prospect` | `company_name?`, `url?` | `{prospect_id, company_id}` | a typed company: enriched, scored and scouted in the background |
| `update_prospect` | `id`, `status?` (`suggested`\|`shortlisted`\|`contacted`\|`dismissed`), `watch` (false) | `null` | `shortlisted` starts a scout; `watch` adds it to the job watchlist |
| `suggest_referrers` | `company_id`, `job_id?` | `{queued_google}` | alumni / ex-colleagues / same function via Google results only (LinkedIn is never opened) |
| `add_referral` | `company_id?`, `job_id?`, `contact_id?`, `person_name?`, `title?`, `linkedin_url?`, `basis` (`alumni`\|`ex_colleague`\|`same_function`\|`user`\|`other`, default `user`), `basis_detail?` | `{referral_id, created}` | "could refer me" |
| `draft_referral` | `id`, `instructions?` | `{connect_note, referral_dm, grounded, unsupported_claims}` | note ≤ 300 characters, message ≤ 120 words; stored on the referral |
| `update_referral` | `id`, `state?`, `connect_note?`, `referral_dm?` | `null` | states per §7.2; `referred` adds a note to the application |
| `set_provider_key` | `provider` (`hunter`\|`github`), `api_key?` (null removes) | `{provider, ok}` | checked with the provider, then stored in the Keychain only |

#### 5.2 Employer reply commands (schema v11; `engine/autoapply/mail/replywatch.py`)

| type | payload | ack `result` | notes |
|---|---|---|---|
| `accept_reply_suggestion` | `reply_id` | `{reply_id, application_id, status}` | applies the reply's `suggested_status` through `set_status` (actor `user`; emits `application_status`). `conflict` when there is no pending suggestion (already accepted or dismissed, or nothing suggested) |
| `dismiss_reply_suggestion` | `reply_id` | `null` | keeps the board as it is; idempotent. The reply stays as evidence and still counts as "heard back" |

#### 5.3 Insights: learning from outcomes (`engine/autoapply/insights.py`)

An advisory report computed from the user's own data. It never changes a threshold or any other setting. No schema change: the result is cached as JSON in `meta` (key `insights_cache`) for 6 hours.

| type | payload | ack `result` | notes |
|---|---|---|---|
| `get_insights` | `force` (false), `summarize` (false) | `Insights` `{computed_at, cached, calibration, skip_blockers, upskill, variants, tokens_in, tokens_out}` | served from the 6-hour cache unless `force` (`cached` says which). `summarize` also asks the fast model for a short `upskill.summary`; its tokens land in `tokens_in` / `tokens_out` and an `insights` event, and the summary is cached with the report |

- **`calibration`** (`ScoreCalibration`): scored, submitted applications in bands `<60`, `60–69`, `70–79`, `80–89`, `90+`, with `applications`, `responses`, `interviews` and the matching rates per band. A **response** is board status `assessment` / `interview` / `offer` / `rejected`, or any `application_replies` row except `received_ack`. An **interview** is `assessment` / `interview` / `offer` (status or reply label). Applications submitted under 14 days ago with no reply are **in flight** and not counted (`in_flight`); unscored ones are counted in `unscored`. Below 8 applications in a band, `response_rate` / `interview_rate` are `null` and `enough_data` is false. `verdict`: `insufficient` (fewer than two bands at the floor), `separating` (highest rated band ≥ 10 points above the lowest), `inverted` (≥ 10 points below) or `flat`; `finding` is one plain sentence (a flat result at or near `match_threshold` says the threshold may be higher than needed).
- **`skip_blockers`** (`SkipBlockers`): jobs skipped in the last 30 days, `reasons[]` `{reason, label, count, examples}` (the stored `state_reason`, else `scores.skip_reason`; up to 8, examples are "Title · Company", newest first), and `requirements[]` `{label, kind: skill|theme|requirement, count, wordings, examples}`: the scorer's `scores.reasons.concerns` on those jobs, grouped by skill, then theme, then wording, listed once 2 jobs share one.
- **`upskill`** (`UpskillHints`): skills (fixed vocabulary) named in the descriptions of jobs skipped after scoring or rejected (status `rejected` or a rejection reply) in the last 90 days, that the profile does not mention anywhere (skills, headline, summary, roles, resume text). Listed from 3 jobs, up to 10: `hints[]` `{skill, jobs, skipped, rejected, examples}`, plus `note` (advisory wording) and the optional `summary`.
- **`variants`** (`VariantInsights`): `variants[]` `{resume_variant_id, label, applications, responses, interviews, response_rate, low_sample (< 10)}`, the dashboard's "By resume variant" shape counted with the response rule above, and a one-line `finding`.

## 6. Events (daemon → app)

| type | payload | when |
|---|---|---|
| `ack` | `ok` (true), `result` (object\|null) — **always has `reply_to`** | command succeeded |
| `error` | `code`, `message`, `details?`, `job_id?`, `application_id?` | command failed (`reply_to`) or unsolicited problem |
| `snapshot` | see §6.1 | reply to `hello` |
| `state` | `daemon` (`idle`\|`discovering`\|`scoring`\|`prepping`\|`applying`), `paused`, `run_id?`, `progress?` `{done,total}`, `message?`, `active_application_id?`, `active_job_id?` | activity changes; progress ticks |
| `run_started` | `run`: `RunInfo` | a run begins |
| `run_finished` | `run`: `RunInfo` (with `finished_at`, `outcome`, `stats`, tokens) | a run ends (→ `RUN_SUMMARY` notification) |
| `job_discovered` | `job`: `JobSummary`, `run_id?` | new (deduped) job persisted |
| `job_scored` | `job_id`, `application_id`, `score?` (0–100, null if hard-filtered), `reasons`, `skip_reason?`, `queued`, `run_id?` | scoring result |
| `application_state` | `application_id`, `job_id`, `from_state?`, `to_state`, `reason?`, `actor` (`agent`\|`user`\|`system`), `at` | **every** state-machine transition |
| `application_status` | `application_id`, `job_id`, `previous_status?`, `status`, `actor`, `at` | board status changed (user, auto-ghost) |
| `question_opened` | `cluster`: `QuestionCluster` | new inbox cluster **or** an existing cluster grew (same `cluster_id`, replace it) |
| `question_resolved` | `cluster_id`, `status` (`answered`\|`skipped`), `answer_id?`, `resumed_application_ids` | cluster closed |
| `agent_step` | `application_id`, `job_id`, `run_id?`, `index` (0-based), `total?`, `action`, `detail?`, `confidence?` (0–1), `screenshot_thumb?` (base64 JPEG ≤ 720 px wide), `at` | each agent step; a frame every ~2 s while filling |
| `cap_reached` | `cap` (`daily`\|`company_cooldown`\|`linkedin_budget`\|`glassdoor_budget`\|`google_budget`\|`outreach_daily`), `used`, `limit`, `resets_at?`, `company_id?` | a guardrail cap blocked work (`outreach_daily`: emails moved to the next day) |
| `source_status` | `source`: `SourceStatus` `{source, enabled, connected, checked_at?, detail?}` | login detection / session health |
| `nudge_due` | `application_id`, `job_id`, `day`, `company`, `title` | day-7 / day-14 "Heard back?" |
| `outreach_state` | `thread_id`, `message_id?`, `entity` (`message`\|`thread`), `from_state?`, `to_state`, `reason?`, `at` | a cold-email message or thread changed state (states per §7.1); re-read the tables |
| `outreach_reply` | `thread_id`, `message_id?`, `contact_name`, `company`, `label` (`positive`\|`referred`\|`not_interested`\|`opt_out`\|`question`\|`other`\|`ooo`\|`bounce`), `snippet`, `application_id?`, `suggested_status?` (`interview`\|`rejected`) | someone replied (Needs You ▸ Replies); a board move is only suggested |
| `application_reply` | `reply_id`, `application_id`, `job_id`, `company`, `title?`, `label` (`interview_invite`\|`assessment`\|`rejection`\|`offer`\|`received_ack`\|`other`), `suggested_status?` (`interview`\|`assessment`\|`rejected`\|`offer`), `ambiguous`, `from_email`, `from_name?`, `subject`, `snippet`, `received_at`, `message_id` | an employer / ATS email about a submitted application was read (§6.2.3). A board move is only suggested; the user accepts or dismisses it |
| `scout_finished` | `company_id`, `purpose`, `application_id?`, `found`, `with_email`, `best_confidence?`, `queued_google`, `thread_id?` | a scout's HTTP phase ended (`thread_id`: the automatic draft) |
| `log` | `level` (`debug`\|`info`\|`warning`\|`error`), `message`, `logger?`, `job_id?`, `application_id?`, `at` | human-readable daemon log line |

### 6.1 Snapshot

```json
{
  "protocol_version": 1,
  "daemon_version": "0.1.0",
  "state": { "daemon": "applying", "paused": false, "run_id": "a1b2…", "progress": {"done": 3, "total": 12},
             "message": "Filling Stripe · Backend Engineer", "active_application_id": 11, "active_job_id": 11 },
  "mode": "auto",
  "next_run_at": "2026-10-10T13:00:00.000Z",
  "current_run": { "run_id": "a1b2…", "kind": "full", "trigger": "scheduled", "started_at": "…", "finished_at": null,
                   "outcome": null, "stats": {"discovered": 40, "scored": 40, "skipped": 27, "queued": 12,
                   "needs_you": 0, "awaiting_review": 0, "submitted": 9, "failed": 0}, "tokens_in": 0, "tokens_out": 0 },
  "last_run": null,
  "counts": { "queued": 12, "needs_you_clusters": 1, "needs_you_jobs": 2, "awaiting_review": 0, "easy_apply_open": 0,
              "unknown_verify": 0, "failed": 0, "submitted_today": 9, "discovered_today": 41, "submitted_total": 98,
              "suggestions_pending": 2, "outreach_drafts": 3, "outreach_replies_unread": 1, "outreach_unknown": 0,
              "application_replies_unread": 1 },
  "caps": { "daily_used": 9, "daily_limit": 15, "companies_cooling_down": 2, "linkedin_sessions_used": 1,
            "linkedin_sessions_limit": 3, "glassdoor_sessions_used": 0, "glassdoor_sessions_limit": 3,
            "outreach_sent_today": 2, "outreach_daily_limit": 5, "people_finder_used": 1, "people_finder_limit": 6 },
  "open_clusters": [ /* QuestionCluster, sorted by job_count desc */ ],
  "sources": [ /* SourceStatus */ ],
  "onboarding": { "completed": true, "step": 7 },
  "preferences": { /* full Preferences */ }
}
```

The snapshot carries **live** state. Durable data (jobs, applications, Q&A audit, stats,
events) is read from SQLite by the app; the DB always wins over optimistic event-driven UI.

### 6.2 Shared payload types

- `JobSummary`: `id, application_id?, company_id, company, title, location?, remote?, source, ats, apply_url?, source_url?, easy_apply, salary_min?, salary_max?, salary_currency?, discovered_at`
- `QuestionCluster`: `cluster_id, canonical_question, field_type, options[], never_guess_key?, reason, question_ids[], variants[], job_ids[], job_count, companies[], created_at, suggested_answer?, suggested_confidence?, suggested_note?, kind, action_type?`
  - `kind` (string, default `"question"`): `"question"` = a value for a form field; `"action"` = the agent is blocked and the user must do something (create an account / sign in, solve a CAPTCHA, finish a verification). An action is completed with `answer_question` (`save_to_memory` false; the text is ignored and never stored): it resolves and re-queues its jobs. `skip_question` skips them. Actions are never saved to answer memory and never share a cluster with questions. Unknown kinds must be treated as `"question"`.
  - `action_type` (string, actions only): `account | captcha | verification | other` (unknown -> `other`).
  - Choices: a question with non-empty `options` is a choice whatever its `field_type` (the engine stores text+options as `select`).
- `RunInfo`: `run_id, kind, trigger, started_at, finished_at?, outcome?, stats{discovered, scored, skipped, queued, needs_you, awaiting_review, submitted, failed}, tokens_in, tokens_out`
- `Preferences` / `NeverGuess` / `Profile`: see `protocol.schema.json` `$defs` (field names = DB columns).

### 6.2.1 Company suggestions

Companies the agent found while browsing (Google Jobs / LinkedIn / Glassdoor apply links, the
company finder's Google searches for public ATS boards) live in the `company_suggestions` table
(schema v6), read by the app directly. `status`: `pending` (shown with Add / Dismiss), `auto` (a
verified ATS board the agent watched by itself; Dismiss unwatches it), `accepted`, `dismissed`.
`counts.suggestions_pending` in the snapshot is the badge count.

### 6.2.2 Cold outreach tables (schema v10, read by the app through GRDB)

`contacts`, `contact_evidence`, `domain_patterns`, `outreach_threads`, `outreach_messages`,
`suppression`, `referrals`, `prospects` (columns in `schema.sql`). Notes for readers:

- `outreach_messages.body` is the user-editable text; `footer` is stored apart and always appended
  when sending (what was sent = `body` + blank line + `footer`). `direction = 'in'` rows are replies,
  auto-replies (`classification = 'ooo'`) and bounces (`'bounce'`).
- Email confidence tiers: Verified ≥ 90, Likely 70–89, Guess 40–69, Unknown < 40.
- `meta.mail_account.send_enabled` (bool) says whether sending is on.
- Open in Gmail: `https://mail.google.com/mail/u/0/#search/rfc822msgid%3A<message_id_header without <>>`.

### 6.2.3 Employer replies (schema v11, table `application_replies`)

The daemon reads the connected mailbox (read-only IMAP, INBOX, last 7 days, at most 100 messages
every 10 minutes; never while paused; nothing without a mailbox) for emails about **submitted
applications**. Replies to cold-outreach threads are not included (they are `outreach_reply`).

- **Matching** (deterministic): the sender's domain is the company's domain, or the sender is an
  ATS mailer (greenhouse-mail.io, lever.co, ashbyhq.com, myworkday.com, smartrecruiters.com,
  workable, icims, …) and the company's name is in the subject, sender name, sender address or
  body. Only messages received after the application's `submitted_at`. Several applications at
  that company: the job title in the subject (then the body) decides; otherwise the most
  recently submitted one is used, `ambiguous = 1` and nothing is suggested.
- **Classification**: phrase rules first; the fast model only when the rules are unsure
  (`classified_by = 'model'`, tokens in `tokens_in/out` and added to the application).
  `interview_invite` → `interview`, `assessment` → `assessment`, `rejection` → `rejected`,
  `offer` → `offer`; `received_ack` and `other` suggest nothing. No suggestion either when the
  application already has that status.
- One row per Message-ID (`message_id`, dedupe). `suggestion_state`: `none` \| `pending` \|
  `accepted` \| `dismissed`. `counts.application_replies_unread` = rows with `pending`.
- Evidence: `from_email`, `from_name`, `subject`, `snippet` (≤ 240 characters), `received_at`.
  Open in Gmail: `https://mail.google.com/mail/u/0/#search/rfc822msgid%3A<message_id without <>>`.
- Any row means the employer wrote ("heard back"): the application is never auto-ghosted and gets
  no more "Heard back?" nudges.

### 6.3 Enumerations (identical to `schema.sql` CHECK constraints)

| enum | values |
|---|---|
| application state | `discovered, scored, skipped, queued, prepping, needs_you, filling, awaiting_review, submitting, submitted, failed, unknown_verify` |
| board status | `applied, assessment, interview, offer, rejected, ghosted` |
| mode | `auto, review` (application mode additionally `manual`) |
| ats | `greenhouse, lever, ashby, workday, linkedin_easy_apply, other` |
| job source | `greenhouse, lever, ashby, careers, linkedin, glassdoor, manual` |
| field type | `text, textarea, number, boolean, select, multiselect, url, email, phone, date, file` |
| answer origin (provenance) | `profile, never_guess, cv, memory, story, generated, user` |
| question reason | `unknown, never_guess, low_confidence, captcha, always_ask` |
| actor | `agent, user, system` |

## 7. Application state machine

```
discovered → scored ─┬─ skipped(reason)
                     └─ queued → prepping → needs_you ⇄ queued
                                  → filling → awaiting_review (Review mode)
                                  → submitting → submitted
                                  → failed(reason) | unknown_verify
```

Enforced by `autoapply.db.transition()` (raises `IllegalTransition`; the daemon replies
`error` `illegal_transition`). Every transition writes an `events` row and is broadcast as
`application_state`. **Allowed transitions (exhaustive):**

| transition | who | meaning |
|---|---|---|
| discovered → scored | any | LLM scored, at/above threshold or pending queue decision |
| discovered → skipped | any | hard filter (location, salary, excludes, cooldown…) |
| discovered → failed | any | could not fetch/parse the posting |
| scored → queued | any | score ≥ threshold |
| scored → skipped | any | below threshold |
| queued → prepping | any | Prep pass harvesting questions |
| queued → filling | any | apply directly (questions already resolved) |
| queued → skipped | any | cap/cooldown decided at queue time, user removal |
| queued → failed | any | adapter unavailable |
| prepping → queued | any | all questions resolved |
| prepping → needs_you | any | unresolved questions parked in inbox |
| prepping → filling | any | prep + apply in one go |
| prepping → skipped | any | form reveals a hard blocker |
| prepping → failed | any | harvest failed |
| needs_you → queued | any | user answered every blocking cluster |
| needs_you → skipped | any | "Skip these jobs" |
| needs_you → failed | any | posting closed while parked |
| filling → needs_you | any | unknown/never-guess/low-confidence field, CAPTCHA |
| filling → awaiting_review | any | effective mode = review |
| filling → submitting | any | auto mode, guardrails passed — **pre-write before the click** |
| filling → queued | any | paused / interrupted mid-fill (nothing submitted) |
| filling → failed | any | adapter error |
| awaiting_review → submitting | **user only** | `approve` |
| awaiting_review → skipped | **user only** | `reject` |
| awaiting_review → queued | any | re-fill (e.g. `set_application_resume`, answers edited) |
| submitting → submitted | any | confirmation verified |
| submitting → failed | any | form rejected the submission (definitely not sent) |
| submitting → unknown_verify | any | outcome ambiguous / crash during submit |
| unknown_verify → submitted | **user only** | `resolve_unknown{submitted:true}` |
| unknown_verify → failed | **user only** | `resolve_unknown{submitted:false}` |
| failed → queued | **user only** | `retry_application` |
| skipped → queued | **user only** | `apply_anyway` |
| skipped → discovered | agent | re-judged after the threshold, preferences or profile changed (never `user_*` skips); `autoapply.reconsider` |
| submitted → (none) | — | terminal (board status takes over) |

Special path (not an edge): `mark_easy_apply_done` records a **manual** application from
`discovered`, `scored`, `skipped`, `queued` or `needs_you` straight to `submitted`
(`mode = manual`, `state_reason = manual_easy_apply`). The agent never applies via LinkedIn.

**Double-apply protection**
- `submitting` is committed (`synchronous=FULL`) **before** the adapter clicks submit (`db.begin_submit`).
- On daemon start, `db.recover_after_crash()` moves every `submitting` row to `unknown_verify`
  (reason `crash_during_submit`) and `prepping`/`filling` rows back to `queued`.
- `unknown_verify` is **never retried automatically**; only the user can resolve it.
- Caps, cooldown and pause are checked immediately before `begin_submit`.

**Board statuses** (manual, only when `state = submitted`): `applied` (set automatically on
submit), `assessment`, `interview`, `offer`, `rejected`, `ghosted` (auto after
`ghost_after_days` = 21 with no change). The user may move between any of them (`set_status`).
An application whose outreach thread got a reply, or that the employer wrote about
(`application_replies`, §6.2.3), is never auto-ghosted.

### 7.1 Cold-email message and thread states

Enforced by `db.transition_outreach` (`models.MESSAGE_TRANSITIONS`); each change writes an `events`
row (kind `outreach`) and is broadcast as `outreach_state`.

| message state | next states | meaning |
|---|---|---|
| draft | approved, cancelled | written (fact-checked); waiting for the user |
| approved | scheduled, draft, cancelled | `approve_outreach` (user only) |
| scheduled | sending, draft, cancelled | has `send_at` inside the send window; `cancel_outreach` → draft |
| sending | sent, failed, unknown | committed (`synchronous=FULL`) **before** the SMTP conversation, after a final check of pause, window, caps, do-not-contact and the thread |
| unknown | sent, failed | crash / timeout during DATA. **Never resent automatically**: the Sent Mail check or `resolve_outreach_unknown` |
| failed | draft, cancelled | refused before DATA: definitely not sent |
| sent, cancelled, received | — | terminal (`received` = inbound) |

Thread states: `draft` (nothing sent) → `active` (sent, waiting) → `replied` \| `bounced` \| `opted_out` \|
`closed` (by the user); `cancelled` = discarded before sending. A reply, bounce, opt-out, the
application moving to `rejected` / `offer`, or the address going on the do-not-contact list cancels
pending follow-ups. At most `outreach_max_followups` (default 1) follow-up per thread, drafted after
`outreach_followup_days` business days; it is scheduled without asking only if the first batch was
approved with `include_followups`.

### 7.2 Referral states

`suggested → to_connect → requested → connected → asked → referred | declined | no_response`, plus
`dismissed` (`models.REFERRAL_TRANSITIONS`). The user performs every LinkedIn step in their own
browser; AutoApply only moves `requested → connected` when LinkedIn's "accepted your invitation"
email arrives, and `requested → no_response` after 14 days.
