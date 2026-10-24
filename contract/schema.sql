-- =====================================================================================
-- AutoApply SQLite schema — SINGLE SOURCE OF TRUTH for the database.
-- Contract version: schema_version = 13  (keep in sync with autoapply.db.SCHEMA_VERSION)
--
-- Location: ~/Library/Application Support/AutoApply/autoapply.db (AUTOAPPLY_HOME overrides)
--
-- Writers / readers
--   * autoapplyd (Python) is the ONLY writer. It applies this file via autoapply.db.migrate().
--   * AutoApply.app reads it read-only through GRDB (ValueObservation). Every mutation the
--     app wants goes over the socket protocol (contract/protocol.md).
--
-- Connection pragmas (set per connection by autoapply.db.connect(); NOT persisted by this file
-- except journal_mode, which is sticky once set):
--   PRAGMA journal_mode = WAL;      -- readers (the app) never block the writer
--   PRAGMA foreign_keys = ON;       -- FKs below are enforced only when this is on
--   PRAGMA synchronous  = FULL;     -- the `submitting` pre-write must survive power loss
--   PRAGMA busy_timeout = 5000;
--   The app should open with: PRAGMA query_only = ON (GRDB: config.readonly = true).
--
-- Conventions
--   * Timestamps: TEXT, ISO-8601 UTC with millisecond precision and a `Z` suffix,
--     e.g. '2026-10-10T09:00:00.000Z'. Lexicographic order == chronological order.
--   * JSON columns: TEXT holding valid JSON (CHECK json_valid). Default '[]' / '{}'.
--   * Booleans: INTEGER 0/1 with CHECK.
--   * Embeddings: BLOB of little-endian float32, plus *_model TEXT naming the embedder.
--   * Enumerations are enforced with CHECK constraints; the canonical lists live in
--     contract/protocol.md and must stay identical to the CHECKs here.
-- =====================================================================================

PRAGMA foreign_keys = ON;

-- -------------------------------------------------------------------------------------
-- schema_version: one row per applied migration. Current version = MAX(version).
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_version (
    version     INTEGER PRIMARY KEY,
    applied_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- meta: small daemon-owned key/value store (onboarding step, paused flag, last run, ...).
-- Values are JSON.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL CHECK (json_valid(value)),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- profile: single row (id = 1). Structured resume facts, contact, links.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS profile (
    id              INTEGER PRIMARY KEY CHECK (id = 1),
    full_name       TEXT,
    first_name      TEXT,
    last_name       TEXT,
    email           TEXT,
    phone           TEXT,
    location        TEXT,                                   -- "Bangalore, India"
    headline        TEXT,
    summary         TEXT,
    links           TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(links)),        -- {"linkedin": url, "github": url, "portfolio": url, ...}
    work_history    TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(work_history)), -- [{company,title,start,end,location,highlights[]}]
    education       TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(education)),    -- [{school,degree,field,start,end}]
    skills          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(skills)),       -- ["go","python",...]
    years_experience REAL,
    extra           TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(extra)),        -- free-form parsed facts
    raw_text        TEXT,                                   -- concatenated resume text used for parsing
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- never_guess: facts that ONLY ever come from the user. key -> JSON value.
-- A missing key (or JSON null) means "always ask me".
-- Canonical keys (see autoapply.config.NeverGuess):
--   work_auth (object country->status), sponsorship, salary_expectation, salary_negotiable,
--   notice_period, start_date, relocation, eeo_policy, eeo_gender, eeo_race, eeo_veteran,
--   eeo_disability, attest_accuracy, attest_background_check
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS never_guess (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL CHECK (json_valid(value)),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- preferences: single row (id = 1). Defaults mirror autoapply.config.Preferences.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS preferences (
    id                          INTEGER PRIMARY KEY CHECK (id = 1),
    roles                       TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(roles)),
    seniority                   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(seniority)),       -- subset of junior|mid|senior|staff|principal
    locations                   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(locations)),       -- cities / countries
    remote_policy               TEXT NOT NULL DEFAULT '["remote","hybrid"]' CHECK (json_valid(remote_policy)), -- subset of remote|hybrid|onsite
    work_auth_summary           TEXT,
    salary_floor                INTEGER CHECK (salary_floor IS NULL OR salary_floor >= 0),
    salary_currency             TEXT NOT NULL DEFAULT 'USD',
    hide_without_salary         INTEGER NOT NULL DEFAULT 0 CHECK (hide_without_salary IN (0, 1)),
    exclude_companies           TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(exclude_companies)),
    exclude_industries          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(exclude_industries)),
    exclude_keywords            TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(exclude_keywords)),
    daily_cap                   INTEGER NOT NULL DEFAULT 15 CHECK (daily_cap >= 0),
    per_company_cooldown_days   INTEGER NOT NULL DEFAULT 30 CHECK (per_company_cooldown_days >= 0),
    match_threshold             INTEGER NOT NULL DEFAULT 70 CHECK (match_threshold BETWEEN 0 AND 100),
    mode                        TEXT NOT NULL DEFAULT 'review' CHECK (mode IN ('auto', 'review')),  -- v13: new installs start in Review (was 'auto'; stored rows are kept)
    per_ats_mode                TEXT NOT NULL DEFAULT '{"workday":"review"}' CHECK (json_valid(per_ats_mode)), -- {ats: "auto"|"review"}
    per_company_mode            TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(per_company_mode)),            -- {company_id(str): "auto"|"review"}
    schedule                    TEXT NOT NULL DEFAULT '["09:00","13:00","18:00"]' CHECK (json_valid(schedule)), -- local HH:MM
    ask_confidence              TEXT NOT NULL DEFAULT 'balanced' CHECK (ask_confidence IN ('strict', 'balanced', 'lenient')),
    ghost_after_days            INTEGER NOT NULL DEFAULT 21 CHECK (ghost_after_days > 0),
    nudge_days                  TEXT NOT NULL DEFAULT '[7,14]' CHECK (json_valid(nudge_days)),
    linkedin_sessions_per_day   INTEGER NOT NULL DEFAULT 3 CHECK (linkedin_sessions_per_day >= 0),
    glassdoor_sessions_per_day  INTEGER NOT NULL DEFAULT 3 CHECK (glassdoor_sessions_per_day >= 0),
    searches_per_session        INTEGER NOT NULL DEFAULT 3 CHECK (searches_per_session BETWEEN 1 AND 10),   -- v2
    jobs_per_session            INTEGER NOT NULL DEFAULT 30 CHECK (jobs_per_session BETWEEN 1 AND 200),     -- v2
    parallel_applications       INTEGER NOT NULL DEFAULT 3 CHECK (parallel_applications BETWEEN 1 AND 4),   -- v6
    create_accounts             INTEGER NOT NULL DEFAULT 1 CHECK (create_accounts IN (0, 1)),               -- v9
    outreach_auto_scout         INTEGER NOT NULL DEFAULT 1 CHECK (outreach_auto_scout IN (0, 1)),           -- v10
    outreach_auto_draft         INTEGER NOT NULL DEFAULT 1 CHECK (outreach_auto_draft IN (0, 1)),           -- v10
    outreach_daily_cap          INTEGER NOT NULL DEFAULT 10 CHECK (outreach_daily_cap BETWEEN 0 AND 40),    -- v10
    outreach_followup_days      INTEGER NOT NULL DEFAULT 5 CHECK (outreach_followup_days BETWEEN 1 AND 30), -- v10
    outreach_max_followups      INTEGER NOT NULL DEFAULT 1 CHECK (outreach_max_followups BETWEEN 0 AND 2),  -- v10
    outreach_send_window        TEXT NOT NULL DEFAULT '["09:30","17:30"]' CHECK (json_valid(outreach_send_window)), -- v10
    outreach_weekdays_only      INTEGER NOT NULL DEFAULT 1 CHECK (outreach_weekdays_only IN (0, 1)),        -- v10
    outreach_min_email_confidence INTEGER NOT NULL DEFAULT 60 CHECK (outreach_min_email_confidence BETWEEN 0 AND 100), -- v10
    people_finder_visits_per_day INTEGER NOT NULL DEFAULT 6 CHECK (people_finder_visits_per_day BETWEEN 0 AND 30), -- v10
    sources_enabled             TEXT NOT NULL DEFAULT '{"greenhouse":true,"lever":true,"ashby":true,"careers":true,"linkedin":false,"glassdoor":false,"google":true}' CHECK (json_valid(sources_enabled)),
    career_page_urls            TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(career_page_urls)),
    always_ask_patterns         TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(always_ask_patterns)),
    updated_at                  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- resume_variants: user-approved resume PDFs. Never modified by the agent.
-- Replacing a file inserts a new row and points the old row's replaced_by at it.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS resume_variants (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    label           TEXT    NOT NULL,
    file_path       TEXT    NOT NULL,                       -- absolute path under <home>/resumes/
    tags            TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),
    text            TEXT,                                   -- extracted plain text
    embedding       BLOB,
    embedding_model TEXT,
    is_default      INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    enabled         INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    version         INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
    replaced_by     INTEGER REFERENCES resume_variants(id) ON DELETE SET NULL,
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
-- At most one default variant.
CREATE UNIQUE INDEX IF NOT EXISTS ux_resume_variants_default ON resume_variants(is_default) WHERE is_default = 1;

-- -------------------------------------------------------------------------------------
-- stories: STAR story bank. Cover letters / "why" answers may only use these + profile.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stories (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,
    situation   TEXT NOT NULL DEFAULT '',
    task        TEXT NOT NULL DEFAULT '',
    action      TEXT NOT NULL DEFAULT '',
    result      TEXT NOT NULL DEFAULT '',
    tags        TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags)),   -- competency tags
    uses        INTEGER NOT NULL DEFAULT 0 CHECK (uses >= 0),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- -------------------------------------------------------------------------------------
-- answers: Q->A memory. Templates may contain {company} / {role} tokens.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS answers (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    canonical_question  TEXT NOT NULL,
    answer              TEXT NOT NULL,
    field_type          TEXT NOT NULL DEFAULT 'text'
                        CHECK (field_type IN ('text','textarea','number','boolean','select','multiselect','url','email','phone','date','file')),
    is_template         INTEGER NOT NULL DEFAULT 0 CHECK (is_template IN (0, 1)),
    embedding           BLOB,
    embedding_model     TEXT,
    source              TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('user', 'generated')),
    uses                INTEGER NOT NULL DEFAULT 0 CHECK (uses >= 0),
    last_used_at        TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_answers_question ON answers(canonical_question COLLATE NOCASE);

-- -------------------------------------------------------------------------------------
-- companies: watchlist + cooldown bookkeeping.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS companies (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    normalized_name TEXT NOT NULL,                          -- autoapply.db.normalize_text(name)
    domain          TEXT,
    ats             TEXT CHECK (ats IS NULL OR ats IN ('greenhouse','lever','ashby','workday','linkedin_easy_apply','other')),
    board_token     TEXT,                                   -- GH board token / Lever company / Ashby org slug
    careers_url     TEXT,
    watch           INTEGER NOT NULL DEFAULT 0 CHECK (watch IN (0, 1)),  -- on the discovery watchlist
    last_applied_at TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_companies_normalized_name ON companies(normalized_name);
CREATE INDEX IF NOT EXISTS ix_companies_watch ON companies(watch) WHERE watch = 1;

-- -------------------------------------------------------------------------------------
-- company_suggestions (v7): companies the agent found while browsing (Google results, apply
-- links, the company finder) that are not on the watchlist. One row per company; the user
-- accepts (-> companies.watch = 1) or dismisses (never suggested again). 'auto' = a verified
-- ATS board the agent added to the watchlist by itself (shown so it can be undone).
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS company_suggestions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    company_name    TEXT NOT NULL,
    normalized_name TEXT NOT NULL,                          -- autoapply.db.normalize_text(company_name)
    url             TEXT NOT NULL,                          -- ATS board or career page
    ats             TEXT CHECK (ats IS NULL OR ats IN ('greenhouse','lever','ashby','workday','linkedin_easy_apply','other')),
    board_token     TEXT,
    source          TEXT NOT NULL,                          -- where it was found: google | linkedin | glassdoor | company_finder | careers
    found_via       TEXT,                                   -- human detail (search query, listing title)
    sample_title    TEXT,                                   -- one matching job title
    matching_roles  INTEGER NOT NULL DEFAULT 0 CHECK (matching_roles >= 0),
    open_roles      INTEGER,                                -- all open roles on the board (verified boards)
    verified        INTEGER NOT NULL DEFAULT 0 CHECK (verified IN (0, 1)),  -- board answered its public API
    status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','dismissed','auto')),
    company_id      INTEGER REFERENCES companies(id) ON DELETE SET NULL,
    suggested_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    decided_at      TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_company_suggestions_name ON company_suggestions(normalized_name);
CREATE INDEX IF NOT EXISTS ix_company_suggestions_status ON company_suggestions(status);

-- -------------------------------------------------------------------------------------
-- jobs: every discovered posting. dedupe_key = normalized "company|title|location".
-- apply_url is additionally unique (normalized) so the same posting found via two
-- sources collapses to one row.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS jobs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT NOT NULL CHECK (source IN ('greenhouse','lever','ashby','careers','linkedin','glassdoor','google','manual')),
    source_url      TEXT,
    apply_url       TEXT,
    apply_url_norm  TEXT,                                   -- autoapply.db.normalize_url(apply_url)
    ats             TEXT NOT NULL DEFAULT 'other' CHECK (ats IN ('greenhouse','lever','ashby','workday','linkedin_easy_apply','other')),
    external_id     TEXT,                                   -- ATS posting id
    company_id      INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    title           TEXT NOT NULL,
    location        TEXT,
    remote          TEXT CHECK (remote IS NULL OR remote IN ('remote','hybrid','onsite')),
    salary_min      INTEGER,
    salary_max      INTEGER,
    salary_currency TEXT,
    description     TEXT,                                   -- plain text JD
    posted_at       TEXT,
    discovered_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    easy_apply      INTEGER NOT NULL DEFAULT 0 CHECK (easy_apply IN (0, 1)),
    mode_override   TEXT CHECK (mode_override IS NULL OR mode_override IN ('auto','review')),
    notes           TEXT,
    raw             TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(raw)),
    dedupe_key      TEXT NOT NULL UNIQUE,
    CHECK (salary_min IS NULL OR salary_max IS NULL OR salary_min <= salary_max)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_jobs_apply_url_norm ON jobs(apply_url_norm) WHERE apply_url_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_jobs_company ON jobs(company_id);
CREATE INDEX IF NOT EXISTS ix_jobs_discovered_at ON jobs(discovered_at);
CREATE INDEX IF NOT EXISTS ix_jobs_source ON jobs(source);

-- -------------------------------------------------------------------------------------
-- scores: one per job. score NULL when skipped by a hard filter before LLM scoring.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scores (
    job_id      INTEGER PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
    score       INTEGER CHECK (score IS NULL OR score BETWEEN 0 AND 100),
    reasons     TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(reasons)), -- {"summary": str, "factors": {"skills": 95, ...}}
    skip_reason TEXT,                                                   -- e.g. "below_threshold", "excluded_keyword:crypto"
    model       TEXT,
    tokens_in   INTEGER NOT NULL DEFAULT 0,
    tokens_out  INTEGER NOT NULL DEFAULT 0,
    basis       TEXT,                                               -- v5: fingerprint of profile+prefs the score was computed against
    scored_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_scores_score ON scores(score);

-- -------------------------------------------------------------------------------------
-- applications: exactly one per job, created at discovery (state 'discovered').
-- `state` is the agent state machine (contract/protocol.md §State machine).
-- `status` is the MANUAL board status, only meaningful once state = 'submitted'.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS applications (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id              INTEGER NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
    state               TEXT NOT NULL DEFAULT 'discovered'
                        CHECK (state IN ('discovered','scored','skipped','queued','prepping','needs_you',
                                         'filling','awaiting_review','submitting','submitted','failed','unknown_verify')),
    state_reason        TEXT,                               -- skip/fail reason, park reason, ...
    state_updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    mode                TEXT CHECK (mode IS NULL OR mode IN ('auto','review','manual')), -- effective mode once decided
    resume_variant_id   INTEGER REFERENCES resume_variants(id) ON DELETE SET NULL,
    resume_pick_score   REAL,
    cover_letter_path   TEXT,
    screenshot_path     TEXT,                               -- pre-submit full-page screenshot
    confirmation_screenshot_path TEXT,                      -- post-submit page
    submitted_at        TEXT,
    status              TEXT CHECK (status IS NULL OR status IN ('applied','assessment','interview','offer','rejected','ghosted')),
    status_updated_at   TEXT,
    nudges_sent         INTEGER NOT NULL DEFAULT 0 CHECK (nudges_sent >= 0),
    tokens_in           INTEGER NOT NULL DEFAULT 0,
    tokens_out          INTEGER NOT NULL DEFAULT 0,
    notes               TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (status IS NULL OR state = 'submitted'),
    CHECK (state <> 'submitted' OR submitted_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_applications_state ON applications(state);
CREATE INDEX IF NOT EXISTS ix_applications_status ON applications(status) WHERE status IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_applications_submitted_at ON applications(submitted_at) WHERE submitted_at IS NOT NULL;

-- -------------------------------------------------------------------------------------
-- application_answers: full Q&A audit for an application (recorded before submit).
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS application_answers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id  INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    field_key       TEXT,                                   -- form field id/name when known
    question        TEXT NOT NULL,
    answer          TEXT NOT NULL,
    field_type      TEXT NOT NULL DEFAULT 'text'
                    CHECK (field_type IN ('text','textarea','number','boolean','select','multiselect','url','email','phone','date','file')),
    confidence      REAL CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    origin          TEXT NOT NULL CHECK (origin IN ('profile','never_guess','cv','memory','story','generated','user')),
    origin_ref      TEXT,                                   -- e.g. "answers:12", "stories:3", "resume_variants:2"
    bbox            TEXT CHECK (bbox IS NULL OR json_valid(bbox)),  -- {"x","y","w","h"} in screenshot px
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_application_answers_app ON application_answers(application_id);

-- -------------------------------------------------------------------------------------
-- questions: the Needs-You inbox. One row per distinct question wording; rows that are
-- semantically equivalent share a cluster_id. The app answers a whole cluster at once.
-- job_ids: JSON array of job ids blocked on this question.
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS questions (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    canonical_question  TEXT NOT NULL,
    cluster_id          TEXT NOT NULL,                      -- opaque string (uuid4 hex)
    job_ids             TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(job_ids)),
    field_type          TEXT NOT NULL DEFAULT 'text'
                        CHECK (field_type IN ('text','textarea','number','boolean','select','multiselect','url','email','phone','date','file')),
    options             TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(options)),
    never_guess_key     TEXT,                               -- set when the question maps to a never_guess key
    reason              TEXT NOT NULL DEFAULT 'unknown'
                        CHECK (reason IN ('unknown','never_guess','low_confidence','captcha','always_ask')),
    embedding           BLOB,
    embedding_model     TEXT,
    status              TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','skipped')),
    answer_id           INTEGER REFERENCES answers(id) ON DELETE SET NULL,
    answer_text         TEXT,                               -- the answer given (also when not saved to memory)
    suggested_answer    TEXT,                               -- v3: the agent's low-confidence draft, shown in the inbox
    suggested_confidence REAL,                              -- v3
    suggested_note      TEXT,                               -- v4: what the draft could not cover (shown beside it)
    kind                TEXT NOT NULL DEFAULT 'question'    -- v8: 'question' (type an answer) | 'action' (agent blocked: do something, then retry)
                        CHECK (kind IN ('question','action')),
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    resolved_at         TEXT,
    CHECK (status = 'open' OR resolved_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_questions_cluster ON questions(cluster_id);
CREATE INDEX IF NOT EXISTS ix_questions_status ON questions(status);
CREATE UNIQUE INDEX IF NOT EXISTS ux_questions_open_text ON questions(canonical_question COLLATE NOCASE) WHERE status = 'open';

-- -------------------------------------------------------------------------------------
-- easy_apply: LinkedIn Easy Apply jobs the USER applies to manually. Never automated.
-- drafted_answers: [{"question","answer","origin","locked":bool,"ask_me":bool}]
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS easy_apply (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id              INTEGER NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,
    url                 TEXT NOT NULL,
    drafted_answers     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(drafted_answers)),
    resume_variant_id   INTEGER REFERENCES resume_variants(id) ON DELETE SET NULL,
    opened              INTEGER NOT NULL DEFAULT 0 CHECK (opened IN (0, 1)),
    done                INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
    dismissed           INTEGER NOT NULL DEFAULT 0 CHECK (dismissed IN (0, 1)),
    done_at             TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_easy_apply_open ON easy_apply(done, dismissed);

-- -------------------------------------------------------------------------------------
-- runs: one row per pipeline run (scheduled or manual).
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS runs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_uid     TEXT NOT NULL UNIQUE,                       -- uuid4 hex, used in protocol messages
    kind        TEXT NOT NULL CHECK (kind IN ('full','discover','prep','apply')),
    trigger     TEXT NOT NULL DEFAULT 'manual' CHECK (trigger IN ('manual','scheduled','wake','cli')),
    started_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    finished_at TEXT,
    outcome     TEXT CHECK (outcome IS NULL OR outcome IN ('completed','paused','failed','cap_reached')),
    stats       TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(stats)),
    tokens_in   INTEGER NOT NULL DEFAULT 0,
    tokens_out  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS ix_runs_started_at ON runs(started_at);

-- -------------------------------------------------------------------------------------
-- events: append-only activity log. Never UPDATE/DELETE (enforced by triggers).
-- kind examples: state, discover, score, skip, resume, fill, ask, answer, submit, error,
--                status, user, cap, run, log
-- -------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    kind            TEXT NOT NULL,
    actor           TEXT NOT NULL DEFAULT 'agent' CHECK (actor IN ('agent','user','system')),
    level           TEXT NOT NULL DEFAULT 'info' CHECK (level IN ('debug','info','warning','error')),
    run_id          INTEGER REFERENCES runs(id) ON DELETE SET NULL,
    job_id          INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
    application_id  INTEGER REFERENCES applications(id) ON DELETE SET NULL,
    message         TEXT NOT NULL,
    payload         TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(payload))
);
CREATE INDEX IF NOT EXISTS ix_events_ts ON events(ts);
CREATE INDEX IF NOT EXISTS ix_events_job ON events(job_id);
CREATE INDEX IF NOT EXISTS ix_events_application ON events(application_id);
CREATE INDEX IF NOT EXISTS ix_events_kind ON events(kind);

-- Append-only: content columns can never change and rows can never be deleted. FK columns
-- (run_id/job_id/application_id) may still be nulled by ON DELETE SET NULL cascades.
CREATE TRIGGER IF NOT EXISTS trg_events_no_update BEFORE UPDATE ON events
WHEN NEW.ts IS NOT OLD.ts OR NEW.kind IS NOT OLD.kind OR NEW.actor IS NOT OLD.actor
  OR NEW.level IS NOT OLD.level OR NEW.message IS NOT OLD.message OR NEW.payload IS NOT OLD.payload
BEGIN
    SELECT RAISE(ABORT, 'events is append-only');
END;
CREATE TRIGGER IF NOT EXISTS trg_events_no_delete BEFORE DELETE ON events
BEGIN
    SELECT RAISE(ABORT, 'events is append-only');
END;

-- =====================================================================================
-- Cold outreach (v10). docs/COLD_EMAIL_PLAN.md. Nothing here is ever sent without the user's
-- approval (outreach_messages.state 'approved' only via the approve_outreach command).
-- =====================================================================================

-- contacts: people at companies (scouted, typed by the user, imported). email_norm is unique.
CREATE TABLE IF NOT EXISTS contacts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id        INTEGER REFERENCES companies(id) ON DELETE CASCADE,
    full_name         TEXT NOT NULL,
    first_name        TEXT,
    last_name         TEXT,
    title             TEXT,
    role_category     TEXT NOT NULL DEFAULT 'other' CHECK (role_category IN ('recruiter','talent_lead','hiring_manager','eng_leader','engineer','founder','role_mailbox','other')),
    email             TEXT,
    email_norm        TEXT,                                 -- lower(trim(nfkc(email)))
    email_status      TEXT NOT NULL DEFAULT 'none' CHECK (email_status IN ('none','pattern','published','provider_verified','user','delivered','replied','bounced')),
    email_confidence  INTEGER NOT NULL DEFAULT 0 CHECK (email_confidence BETWEEN 0 AND 100),
    role_fit          INTEGER CHECK (role_fit IS NULL OR role_fit BETWEEN 0 AND 100),
    linkedin_url      TEXT,                                 -- reference only: never opened by AutoApply
    github_login      TEXT,
    location          TEXT,
    origin            TEXT NOT NULL CHECK (origin IN ('scout','user','import','shared')),
    relationship      TEXT CHECK (relationship IS NULL OR relationship IN ('friend','ex_colleague','alumni','met','other')),
    share_ok          INTEGER NOT NULL DEFAULT 0 CHECK (share_ok IN (0, 1)),
    shared_at         TEXT,
    notes             TEXT,
    last_contacted_at TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contacts_email ON contacts(email_norm) WHERE email_norm IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_contacts_company ON contacts(company_id);

-- contact_evidence: one row per observation (provenance shown in the UI).
CREATE TABLE IF NOT EXISTS contact_evidence (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    contact_id  INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL CHECK (kind IN ('user','job_posting','company_page','github','google_serp','pattern','provider','shared_library','reply','bounce')),
    field       TEXT NOT NULL CHECK (field IN ('name','title','email')),
    url         TEXT,
    snippet     TEXT,                                       -- <= 280 chars
    provider    TEXT,
    observed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_contact_evidence_contact ON contact_evidence(contact_id);

-- domain_patterns: per email domain, the inferred address pattern and MX provider.
CREATE TABLE IF NOT EXISTS domain_patterns (
    domain      TEXT PRIMARY KEY,
    company_id  INTEGER REFERENCES companies(id) ON DELETE SET NULL,
    pattern     TEXT,                                       -- first.last | first | flast | ...
    confidence  INTEGER NOT NULL DEFAULT 0,
    samples     TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(samples)),   -- [{name,email,source,url}]
    mx_provider TEXT CHECK (mx_provider IS NULL OR mx_provider IN ('google','microsoft','other','none')),
    bounces     INTEGER NOT NULL DEFAULT 0,
    checked_at  TEXT
);

-- outreach_threads: one conversation with one contact.
CREATE TABLE IF NOT EXISTS outreach_threads (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    kind              TEXT NOT NULL CHECK (kind IN ('application','prospect','referral_email')),
    contact_id        INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
    company_id        INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    job_id            INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
    application_id    INTEGER REFERENCES applications(id) ON DELETE SET NULL,
    state             TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','active','replied','bounced','opted_out','closed','cancelled')),
    outcome           TEXT CHECK (outcome IS NULL OR outcome IN ('positive','referred','not_interested','question','other')),
    subject           TEXT,
    gmail_thread_id   TEXT,
    next_action_at    TEXT,                                 -- earliest follow-up (pushed back by an out-of-office reply)
    unread_reply      INTEGER NOT NULL DEFAULT 0 CHECK (unread_reply IN (0, 1)),
    followup_approved INTEGER NOT NULL DEFAULT 0 CHECK (followup_approved IN (0, 1)),  -- pre-approved in the first batch
    suggested_status  TEXT CHECK (suggested_status IS NULL OR suggested_status IN ('assessment','interview','offer','rejected')),  -- v12: board move a reply suggests
    suggestion_state  TEXT NOT NULL DEFAULT 'none' CHECK (suggestion_state IN ('none','pending','accepted','dismissed')),  -- v12
    suggestion_decided_at TEXT,                             -- v12: when the user accepted / dismissed it
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_outreach_threads_state ON outreach_threads(state);
CREATE INDEX IF NOT EXISTS ix_outreach_threads_application ON outreach_threads(application_id);

-- outreach_messages: drafts, sent mail and inbound replies / bounces. The footer is stored
-- apart from the editable body and always appended when sending.
CREATE TABLE IF NOT EXISTS outreach_messages (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id          INTEGER NOT NULL REFERENCES outreach_threads(id) ON DELETE CASCADE,
    seq                INTEGER NOT NULL DEFAULT 0,
    direction          TEXT NOT NULL CHECK (direction IN ('out','in')),
    kind               TEXT CHECK (kind IS NULL OR kind IN ('application_followup','prospect','followup','referral_email')),
    state              TEXT NOT NULL CHECK (state IN ('draft','approved','scheduled','sending','sent','failed','unknown','cancelled','received')),
    to_email           TEXT,
    from_email         TEXT,
    subject            TEXT,
    body               TEXT NOT NULL,
    footer             TEXT,
    origin             TEXT NOT NULL DEFAULT 'generated' CHECK (origin IN ('generated','user')),
    grounded           INTEGER NOT NULL DEFAULT 1 CHECK (grounded IN (0, 1)),
    unsupported_claims TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(unsupported_claims)),
    claims_overridden  INTEGER NOT NULL DEFAULT 0 CHECK (claims_overridden IN (0, 1)),
    story_ids          TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(story_ids)),
    message_id_header  TEXT,
    in_reply_to        TEXT,
    batch_uid          TEXT,
    approved_at        TEXT,
    send_at            TEXT,
    sent_at            TEXT,
    classification     TEXT,
    error              TEXT,
    tokens_in          INTEGER NOT NULL DEFAULT 0,
    tokens_out         INTEGER NOT NULL DEFAULT 0,
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS ix_outreach_messages_due ON outreach_messages(state, send_at);
CREATE INDEX IF NOT EXISTS ix_outreach_messages_thread ON outreach_messages(thread_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_outreach_messages_mid ON outreach_messages(message_id_header) WHERE message_id_header IS NOT NULL;

-- suppression: the do-not-contact list (an address or a whole domain). Checked when drafting,
-- approving and immediately before sending. Opt-outs are never removed by the UI.
CREATE TABLE IF NOT EXISTS suppression (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    email_norm  TEXT,
    domain      TEXT,
    reason      TEXT NOT NULL CHECK (reason IN ('opt_out','hard_bounce','user','shared_removal','complaint')),
    source      TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    CHECK (email_norm IS NOT NULL OR domain IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_suppression_email ON suppression(email_norm) WHERE email_norm IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_suppression_domain ON suppression(domain) WHERE domain IS NOT NULL;

-- referrals: the LinkedIn referral copilot. The USER does every LinkedIn step in their own
-- browser; AutoApply only finds people through Google results and drafts the notes.
CREATE TABLE IF NOT EXISTS referrals (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id         INTEGER NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    job_id             INTEGER REFERENCES jobs(id) ON DELETE SET NULL,
    contact_id         INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
    person_name        TEXT NOT NULL,
    title              TEXT,
    linkedin_url       TEXT,
    basis              TEXT NOT NULL CHECK (basis IN ('alumni','ex_colleague','same_function','user','other','same_city')),
    basis_detail       TEXT,
    evidence_url       TEXT,
    evidence_snippet   TEXT,
    state              TEXT NOT NULL DEFAULT 'suggested' CHECK (state IN ('suggested','to_connect','requested','connected','asked','referred','declined','no_response','dismissed')),
    connect_note       TEXT,
    referral_dm        TEXT,
    grounded           INTEGER NOT NULL DEFAULT 1 CHECK (grounded IN (0, 1)),
    unsupported_claims TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(unsupported_claims)),
    state_updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_referrals_person ON referrals(company_id, linkedin_url) WHERE linkedin_url IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_referrals_state ON referrals(state);

-- prospects: companies to reach out to without an application (company search, watchlist).
CREATE TABLE IF NOT EXISTS prospects (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    company_id      INTEGER NOT NULL UNIQUE REFERENCES companies(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'suggested' CHECK (status IN ('suggested','shortlisted','contacted','dismissed')),
    fit_score       INTEGER CHECK (fit_score IS NULL OR fit_score BETWEEN 0 AND 100),
    fit_reasons     TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(fit_reasons)),
    summary         TEXT,                                   -- homepage description: evidence drafts may cite
    summary_url     TEXT,
    matching_roles  INTEGER,
    found_via       TEXT,                                   -- search | watchlist | user
    search_query    TEXT,
    cooldown_until  TEXT,                                   -- no new prospect thread before this
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    -- v14: the deterministic startup score (outreach/startup_score.py) and the rank it makes
    -- with fit_score. startup_reasons = [{key, label, points, max, reason, known}].
    startup_score      INTEGER CHECK (startup_score IS NULL OR startup_score BETWEEN 0 AND 100),
    startup_confidence INTEGER CHECK (startup_confidence IS NULL OR startup_confidence BETWEEN 0 AND 100),
    startup_reasons    TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(startup_reasons)),
    rank_score         INTEGER CHECK (rank_score IS NULL OR rank_score BETWEEN 0 AND 100)
);
CREATE INDEX IF NOT EXISTS ix_prospects_status ON prospects(status);

-- company_facts (v14): what public sources say about a company (YC's directory, funding news).
-- Every fact has its source in `sources` ({fact: {url, quote?, observed_at}}); a fact with no
-- source is left NULL, never guessed. Amounts are as reported; last_round_usd converts them
-- at fixed, documented rates (outreach/startups.py USD_RATES).
CREATE TABLE IF NOT EXISTS company_facts (
    company_id          INTEGER PRIMARY KEY REFERENCES companies(id) ON DELETE CASCADE,
    hq_city             TEXT,
    hq_country          TEXT,
    yc_batch            TEXT,                               -- short code: W24, S25, X25 (spring), F24 (fall)
    yc_url              TEXT,
    yc_status           TEXT,                               -- Active | Public | Acquired | Inactive (YC's label)
    industry            TEXT,
    last_round_stage    TEXT CHECK (last_round_stage IS NULL OR last_round_stage IN
                          ('pre_seed','seed','series_a','series_b','series_c','series_d_plus','other')),
    last_round_amount   REAL CHECK (last_round_amount IS NULL OR last_round_amount >= 0),
    last_round_currency TEXT,                               -- ISO 4217 (USD, INR, EUR, ...)
    last_round_usd      REAL CHECK (last_round_usd IS NULL OR last_round_usd >= 0),
    last_round_date     TEXT,                               -- YYYY-MM-DD (the announcement's date)
    total_raised_usd    REAL CHECK (total_raised_usd IS NULL OR total_raised_usd >= 0),
    investors           TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(investors)),
    team_size           INTEGER CHECK (team_size IS NULL OR team_size >= 0),
    is_hiring           INTEGER CHECK (is_hiring IS NULL OR is_hiring IN (0, 1)),
    open_roles          INTEGER CHECK (open_roles IS NULL OR open_roles >= 0),
    founders            TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(founders)),  -- [{name, title, url}] from YC's page
    sources             TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(sources)),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- =====================================================================================
-- Employer replies (v11). engine/autoapply/mail/replywatch.py reads the connected mailbox
-- (read-only) for emails from a company's domain or its ATS about a submitted application.
-- A board move is only suggested; the user accepts or dismisses it. Any row means the
-- employer wrote ("heard back"): such an application is never auto-ghosted.
-- =====================================================================================

CREATE TABLE IF NOT EXISTS application_replies (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    application_id    INTEGER NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
    message_id        TEXT NOT NULL UNIQUE,
    from_email        TEXT NOT NULL,
    from_name         TEXT,
    subject           TEXT NOT NULL DEFAULT '',
    snippet           TEXT NOT NULL DEFAULT '',
    received_at       TEXT NOT NULL,
    label             TEXT NOT NULL CHECK (label IN ('interview_invite','assessment','rejection','offer','received_ack','other')),
    classified_by     TEXT NOT NULL DEFAULT 'rules' CHECK (classified_by IN ('rules','model')),
    match_basis       TEXT NOT NULL CHECK (match_basis IN ('domain','ats')),
    ambiguous         INTEGER NOT NULL DEFAULT 0 CHECK (ambiguous IN (0, 1)),
    suggested_status  TEXT CHECK (suggested_status IS NULL OR suggested_status IN ('assessment','interview','offer','rejected')),
    suggestion_state  TEXT NOT NULL DEFAULT 'none' CHECK (suggestion_state IN ('none','pending','accepted','dismissed')),
    tokens_in         INTEGER NOT NULL DEFAULT 0,
    tokens_out        INTEGER NOT NULL DEFAULT 0,
    read_at           TEXT,                                 -- v12: NULL = unread (mark_application_reply_read)
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    decided_at        TEXT
);
CREATE INDEX IF NOT EXISTS ix_application_replies_app ON application_replies(application_id, received_at);
CREATE INDEX IF NOT EXISTS ix_application_replies_suggestion ON application_replies(suggestion_state);

-- -------------------------------------------------------------------------------------
-- updated_at maintenance is done by autoapply.db (explicit), not triggers, to keep the
-- app's GRDB observation cheap and predictable.
-- -------------------------------------------------------------------------------------

-- Seed singleton rows with defaults.
INSERT OR IGNORE INTO preferences (id) VALUES (1);
INSERT OR IGNORE INTO profile (id) VALUES (1);

INSERT OR IGNORE INTO schema_version (version) VALUES (1);
INSERT OR IGNORE INTO schema_version (version) VALUES (2);
INSERT OR IGNORE INTO schema_version (version) VALUES (3);
INSERT OR IGNORE INTO schema_version (version) VALUES (4);
INSERT OR IGNORE INTO schema_version (version) VALUES (5);
INSERT OR IGNORE INTO schema_version (version) VALUES (6);
INSERT OR IGNORE INTO schema_version (version) VALUES (7);
INSERT OR IGNORE INTO schema_version (version) VALUES (8);
INSERT OR IGNORE INTO schema_version (version) VALUES (9);
INSERT OR IGNORE INTO schema_version (version) VALUES (10);
INSERT OR IGNORE INTO schema_version (version) VALUES (11);
INSERT OR IGNORE INTO schema_version (version) VALUES (12);
INSERT OR IGNORE INTO schema_version (version) VALUES (13);
INSERT OR IGNORE INTO schema_version (version) VALUES (14);
