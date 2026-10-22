# AutoApply: the design vision for an Apple Design Award

Written 2026-10-22. This is a strategy document. It doesn't change app code; it says what to build, in what order, and why. It builds on `app/DESIGN_REDESIGN_PLAN.md` (already landed in `92fc4d5`), the Rams audit in `DESIGN-IS-2026-10-22/` (11/30), the live Dashboard hero (`a2edab8`), `docs/COLD_EMAIL_PLAN.md` §A and `docs/CAREER_OPS_REVIEW.md`. Paths are under `app/Sources/AutoApply/` unless they say otherwise.

Each decision has one recommendation. Where the owner has to choose, it's listed in §13.

---

## 0. Where we are, honestly

The redesign fixed the foundations. There's one `Surface` and one `Well` (`DesignSystem/Materials.swift`), glass sits on the control layer, there's one primary action per screen, `textTertiary` passes 4.5:1, and the glossary is in place. The Dashboard hero is now alive (`Features/Dashboard/Hero/*`), and Interview prep, Insights, score evidence, reply-watch and Cold Email have all shipped since the audit.

Three things still stand between AutoApply and a juror's shortlist:

1. **It reads as a capable tool, not a point of view.** Every screen is competent, but nothing tells the story "this app understands what job hunting feels like". The Dashboard still stacks 4 KPI tiles, a 30-day chart, 4 analysis charts, Insights and a GitHub-style heatmap under the hero (`Features/Dashboard/DashboardView.swift:25-50`). That's a control room, and job seekers don't want a control room.
2. **Its delight isn't yet tied to meaning.** Confetti belongs to easter eggs, celebrations fire on agent volume (`LiveAgentCard.swift:77-85` celebrates every submission), and the hero breathes coral at idle (`DashboardHero.swift:38`). A juror will ask what the motion is for.
3. **It isn't yet deep in the platform.** There are no widgets, App Intents, Spotlight, actionable notifications or localisation. The app icon is still the purple gradient the owner rejected (`app/scripts/make_icon.swift:10`).

There is also a structural risk that no amount of design fixes, covered in §13 decision 1: historically the ADA is given to App Store apps. AutoApply ships as an ad-hoc-signed DMG that installs a Python agent and drives Chrome.

---

## 1. The award thesis

### Categories

**Primary: Interaction.** Supervising an agent is a new interaction problem, and AutoApply has already solved parts of it better than anyone. Answer once and many jobs move. Approve with the page-as-sent beside every answer. Drag to Queued to delegate, or drop on Applied to say "I did this myself". Jurors in Interaction reward an interface that makes a hard thing feel obvious and native. Delegating a high-stakes task to an AI, and staying in control of it, is the hard thing of 2026.

**Secondary: Social Impact.** Job hunting is one of the most anxious things people do, and the users are often first-job seekers in India, applying to hundreds of postings, facing scams and silence. An app that takes the drudgery away, refuses to lie on your behalf, and treats rejection kindly is a social-impact story with a human face.

**Not targeted:**
- **Innovation.** The intelligence runs through Claude Code in a terminal, not Apple's on-device frameworks. Jurors in Innovation look for novel uses of Apple technology.
- **Visuals and Graphics.** The app should be beautiful, but beauty isn't the reason it should win.
- **Delight and Fun.** It's a job hunt; fun is seasoning, not the meal.
- **Inclusivity.** Pursue it seriously (§9), but don't pitch it as the headline.

### The sentence a juror remembers

> **"AutoApply takes the dread out of job hunting: an agent does the drudgery in plain sight, asks you only what only you know, and never sends a word you wouldn't stand behind."**

The demo version, for a 90-second video: *ten calm minutes a day, then you're done.*

### What follows from the thesis

- **Fewer, better applications, not more.** An auto-apply bot is the thing recruiters hate. Our framing has to be quality and honesty: the match evidence, the review step, the daily limit and the scam signals. We never celebrate volume (§2, principle 4).
- **The user is the protagonist, the agent is the colleague.** Every signature moment celebrates something the *user* did, or something that happened *to* the user. None of them celebrate the agent's throughput.
- **A finish line.** Anxiety comes from work that never ends. The app has to say, every day, "you're done for today."

---

## 2. Design principles

These seven principles are ranked. When two conflict, the higher one wins. They replace the five rules in `docs/UI_UX_PLAN.md` §0 and absorb the Rams audit's ranking (honest > understandable > as little as possible > unobtrusive).

1. **Honest before impressive.** Every number, claim and action can be opened to show where it came from. If we can't show the receipt, we don't make the claim. *(The audit gave Honest 0/3. This principle is the one that must never regress.)*
2. **The user is the hero; the agent is a colleague.** Copy speaks to the user in the second person. The agent speaks in the first person, in SF Mono (§5). Wins are the user's: "your answer moved 14 jobs", not "AutoApply applied to 14 jobs".
3. **One thing at a time, with a finish line.** Each screen has one primary action and each day has one short list. Every list can be emptied, and emptying it is acknowledged.
4. **Delight rewards effort, never volume.** We celebrate an answer that unblocked many jobs, an interview, and the first application in onboarding. We never celebrate the 40th auto-submission, a streak, or a count going up on its own.
5. **Motion is a receipt.** Continuous motion is allowed only when a real event stream drives it, or for a few seconds after the user arrives. When nothing is happening, nothing moves.
6. **Kind about outcomes.** Rejection is never red, never a notification and never a total on the home screen. Silence (ghosting) is named gently and closed automatically.
7. **Native to the bone.** Use system controls, a keyboard path for everything, the menu bar, notifications, Spotlight and Shortcuts. If Apple has a pattern for it, we use Apple's pattern.

### Calm versus alive

The audit asks for calm; the owner asks for liveliness. Both are right about different moments. The resolution is a **motion budget in four tiers**, enforced in code (each tier is a modifier and a test):

| Tier | What | Where allowed | Limits |
|---|---|---|---|
| **0 · Still** | Nothing moves | Every reading surface: lists, Job detail, Settings, Profile, Library | Default for everything |
| **1 · Response** | Feedback to a user action: hover, press, selection, a row leaving, a number rolling | Everywhere | ≤ 300 ms, one element leads, no loops |
| **2 · Live** | Continuous motion driven by real events: pipeline particles, the live Chrome frame, the step ticker, the countdown ring | Dashboard hero, menu-bar panel, Over the shoulder (§3.1) | Only while the agent works **and** the window is visible; ≤ 30 fps; stops on pause |
| **3 · Moment** | A choreographed, sometimes audible event | The six signature moments in §3, onboarding, easter eggs | ≤ 3 per day outside onboarding and eggs; skippable; ≤ 2.5 s |

**The owner's "alive" is kept, and given a rule: wake on arrival.** When the Dashboard appears, or the window becomes key after more than 10 minutes away, the brand field and glows drift for **8 seconds** and then ease to a still frame over 1.2 s. Any real event (a step, a submission, a question arriving) wakes the field again for 8 seconds. While the agent works, Tier 2 runs continuously. The Dashboard always feels alive when you look at it and is still while you read it. It also stops costing energy when you've walked away with the window still open.

- **Today:** `DashboardHero.motionActive` (`Hero/DashboardHero.swift:17-23`) returns true for `.idle`, so the field drifts at 10 fps indefinitely and `HeroBreath` (coral, 11 s period) breathes forever.
- **Change:** add a `HeroWake` state (arrived / event / settled) to `Hero/HeroStyle.swift`. `motionActive` then becomes `windowVisible && !reduceMotion && (state.isRunning || wake.isAwake)`. It's a pure function, so it can be unit-tested like the current one.

---

## 3. Signature moments

These are the things people screenshot. Each one does a job, and each has a Reduce Motion form (§6) and an accessible form (§9).

### 3.1 "Over the shoulder": the agent at work

**What it is.** While the agent fills an application, you can watch it the way you'd watch a colleague's screen. Open it from the hero's live frame, the menu bar thumbnail, or ⌥⌘L. A large live Chrome frame sits on the left. On the right is the form's field list, filling in as the agent goes. Each answer arrives with a **provenance chip**: "from your profile", "from your story *Payments migration*", "drafted · medium confidence", "you answered this on 12 Oct". A low-confidence field glows coral and is pinned to the top.

At the bottom there's one button: **Take over** (⌘T). It pauses after the current step and brings the real Chrome window forward.

**Why it's useful.** It builds trust in the agent in under a minute. The rest of the app runs on that trust: Auto mode, the daily limit, everything else.

**What exists.**
- `LiveBrowserThumb.swift`, `StepTicker.swift` and `LiveRunStore`.
- The provenance tags in `JobDetail/QATable.swift`.
- `agent_step` events carry `action / detail / confidence / screenshot_thumb` (`contract/protocol.md:266`).

**What's missing.**
- `agent_step` needs `field_label?` and `source?` (`profile|cv|memory|story|generated|user`) so the chips can be live. That's a protocol and engine change.
- A new view, `Features/LiveAgent/OverTheShoulderView.swift`. It's a window scene, so it works in Stage Manager and on a second display.

**Screenshot moment.** A real Greenhouse form, half filled, with green chips streaming down the right edge.

### 3.2 "One answer, many doors": the cascade

**What it is.** In Needs You, the composer shows who's waiting: a row of company monograms ("14 jobs are waiting on this answer") above the field. When you press ⌘↵:

1. The monograms lift and fly one by one (30 ms stagger, at most 8 animated and the rest as a "+6" chip) into the sidebar's **Pipeline** row.
2. The Pipeline row's badge rolls up.
3. The cluster collapses into "Answered today".
4. The toast reads **"14 jobs back in the queue · Undo"**, with a ring draining for the 10-second undo window.
5. One `levelChange` haptic plays at the end, not one per monogram.

**Why it's useful.** It makes the product's best idea, answer once and unblock many, visible and physical. It also teaches the user to clear the highest-impact cluster first, since the list is already sorted by impact (`InboxModel.clusters`).

**What exists.** The undo window (`InboxModel.swift:540-590`), auto-advance, `Sounds.play(.pop)` and `inboxZeroTrigger`.

**What changes.**
- The monogram row and the flight overlay are new. Implement the flight with anchor preferences at the `RootView` level, because it crosses the split view.
- The toast's undo ring is new (`ToastCenter`).
- Fix the audit's bug where the undo toast waits in a queue while its timer is already running (`ToastCenter.swift:39-46`). The undo toast jumps the queue.

**Inbox zero.** When the last cluster clears, the list area shows a still, typographic end card: "That's everything. Your answers moved 31 jobs today." It plays the single `celebrate` sound and no confetti. `InboxZeroCelebration` (`DesignSystem/Components/Celebration.swift:102`) becomes this card.

### 3.3 "Today's ten minutes": the morning briefing with a finish line

**What it is.** The first time you open the app each day, the Dashboard's greeting becomes a briefing written in plain sentences:

> **Good morning, Moaksh.**
> While you were away the agent found 38 jobs; 6 are worth your time. 2 questions need you (about 3 min) and 4 applications are ready to look over (about 6 min).
> **[ Start · 9 min ]**

**Start** (⌘↵) enters a **session**. A slim glass bar pins to the top of the window ("2 of 6 · Needs You"). It walks you through each item in place: the Needs You clusters, then Review, then any replies that suggest a board move. When you finish, the bar morphs (`glassEffectID`) into **"Done for today. The agent takes it from here."** The briefing card on the Dashboard then reads "Done for today ✓" until tomorrow.

**Why it's useful.** It's the anti-anxiety feature: a bounded, estimated amount of work that ends. It also replaces the "focus hour" idea. A focus hour is a timer; this is a list that finishes.

**Estimates.** These come from data we already have: question kind (yes/no ≈ 10 s, short text ≈ 30 s, long text ≈ 90 s), flagged answers in Review (≈ 40 s each) and clean reviews (≈ 15 s). Round up, and say "about".

**Files.**
- New `Features/Dashboard/Briefing/` (model plus view).
- New `Features/Session/SessionBar.swift`, a `GlassBar` variant.
- `Router` gains a session queue.

### 3.4 "It landed": an interview

**What it is.** Reply-watch (`7d03c20`) classifies an employer email as an interview. The suggestion goes to Needs You ▸ Replies, as it does today. When the user confirms **Move to Interview**:

- The job card flies (matched geometry) into the Interview column and settles in blue.
- The one real celebration in the app plays: a soft bloom of the card's colour behind it and the two-note `landed` sound (§7).
- A sheet slides up: **"You have an interview with Acme."** It offers three things: **Add to Calendar** (EventKit, from the email's date if it was parsed), **Prepare** (opens Job detail ▸ Interview prep and generates the pack), and **Tell me later**.

**Why it's useful.** This is the moment the whole funnel exists for, and today the app drops it. The status changes and nothing else happens. Prep and the calendar are the next actions anyway.

**Rules.** The celebration only plays on a user-confirmed move, because the board never moves by itself (`RepliesSection.swift`). It plays once per application, and an Offer gets the same treatment in gold.

### 3.5 "A kind no": rejection handling

**What it is.**
- **No notifications.** Rejections never notify. Today `AppNotifier` posts every reply that has a suggested status, including Rejected (`Core/System/AppNotifier.swift:52-55`); change that to skip rejections.
- **A quiet line in Replies.** "Acme replied: not moving forward." The actions are **Close it** and **Keep it open**. Closing moves the card to a collapsed **Closed** drawer on the Pipeline (§4.4) with a gentle fold, not a red flash.
- **One closing card in Job detail.** It reads: "This one's closed. That's normal: most applications at this stage end here." Under that are two optional links: **Draft a thank-you and ask for feedback** (grounded and never sent, same rules as the debrief thank-you), and **Find roles like this**, which seeds the search planner with the role and drops the company.
- **Patterns go to the weekly recap (§3.6), never to the moment.** "What keeps blocking you" already exists in Insights.

**Why it's useful.** Rejection is the most common event in a job hunt, and how an app handles it says the most about who it was designed for. It's also a story a juror can tell.

### 3.6 "Your week": the Sunday recap

**What it is.** Once a week, on Sunday evening or on the first open after it, a single page covers four things:

1. **Effort.** "You spent 47 minutes supervising this week," taken from session time.
2. **What happened.** 22 applied · 3 replies · 1 interview.
3. **What's working.** One sentence from Insights, e.g. "Your *Platform* résumé gets twice the replies of *General*."
4. **One suggestion with one button,** e.g. "Raise your match bar to 75: about 20% fewer applications, same reply rate. [Preview]".

Rejections show up only as part of a rate ("replies: 3 of 22"), never as a list.

**Why it's useful.** It turns data into one decision a week. It answers "is this working?", the question anxious job seekers ask most.

**Form.** A sheet on the Dashboard, the same content as a notification ("Your week is ready") and as a large widget (§8). It uses the Insights data (`Features/Dashboard/Insights/InsightsModel.swift`) with no extra model call unless the user presses Summarize.

**Not chosen:** a "focus hour" mode (replaced by the session in §3.3) and streaks of any kind (principle 4).

---

## 4. Per-screen concepts

### 4.1 Dashboard → "Today"

- **Job to be done:** "Is anything wrong, what needs me, and am I done?"
- **Layout:** the hero stays, with the briefing as its first line. Below it is a single **"This week"** strip. Everything else moves to **Insights**, which becomes a sidebar item under Library and is renamed **"What's working"**.

```
┌──────────────────────────────────────────────────────────────────────┐
│ ░ brand field (wakes on arrival, still while you read) ░░░░░░░░░░░░░ │
│ WEDNESDAY 22 OCTOBER                              ● Review · waits   │
│ Good morning, Moaksh.                                                │
│ 38 found overnight, 6 worth your time. 2 questions (~3 min) and      │
│ 4 to look over (~6 min).                       [ Start · 9 min ⌘↵ ]  │
│                                                                      │
│  Discovered ─── Scored ─── Queued ─── Filling ─── Applied            │
│      38           6          4    ◉      1           22 this week    │
│                                                                      │
│ ┌ glass ─────────────────────┐  ┌ glass ────────────────────────────┐│
│ │ ◔ Next run in 42 min       │  │ Last applied · Razorpay · SDE II  ││
│ │   at 11:30 · daily 12/20   │  │ [page thumb]  09:58  Over the ⤢   ││
│ └────────────────────────────┘  └───────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────┘
 THIS WEEK   22 applied · 3 replies · 1 interview      Reply rate 14% ▁▂▄▃▅
```

- **Primary action:** **Start** while there's work, nothing when you're done ("Done for today ✓"), and **Run now** only on first run (as today).
- **Hero detail:** the pipeline flow, unchanged in spirit (`PipelineFlowView.swift`), with real transitions flying as particles. The briefing sentence numbers roll (`numericRoll`) when the overnight run lands.
- **States:** first run ("Your agent hasn't run yet. [Run now]"); loading (still field, two-line skeleton); agent unreachable (field desaturates as for pause; "The agent isn't running on this Mac. [Start agent]", said once, in one place); done ("Done for today ✓ · next run 11:30", nothing moves).
- **Differs from today:**
  - The KPI tiles and every chart leave the Dashboard (`DashboardView.swift:31-50`). Funnel, variants and calibration go to What's working; the histogram's threshold drag moves to Settings ▸ Preferences ▸ Match bar, where the decision is made; the heatmap and Sources chart are cut (§12).
  - The idle coral `HeroBreath` goes; coral moves to the briefing's "need you" numbers (§5.2).
  - The greeting's gradient text fill (`DashboardHero.swift:62`) becomes solid white. Gradient text still reads as generated.

### 4.2 Needs You

- **Job to be done:** "Answer what only I know, as few times as possible."
- **Layout:** a list on the left in three sections: **Do this first** (agent blockers: CAPTCHA, account, verify), **Questions** (impact-sorted), and **Replies**. The composer is on the right.

```
┌ Needs You ─ 2 to do · 7 questions · 31 jobs waiting ─────────────────┐
│ DO THIS FIRST          │  What is your notice period?                │
│ ▸ Verify email · Ashby │  ┌───────────────────────────────────────┐  │
│ QUESTIONS              │  │ ⓐ ⓡ ⓢ ⓒ ⓩ ⓕ ⓘ ⓜ  +6   14 jobs waiting │  │
│ ● Notice period   14   │  └───────────────────────────────────────┘  │
│ ● Expected CTC     9   │  ┌ well ─────────────────────────────────┐  │
│   Relocate to Pune 3   │  │ 30 days, negotiable to 15             │  │
│ REPLIES                │  │ ╌ draft · from your profile: "30 days"│  │
│   Acme replied         │  └───────────────────────────────────────┘  │
│                        │  ☑ Remember for future jobs                 │
│ ▾ Answered today (4)   │                      [ Answer  ⌘↵ ]         │
└────────────────────────┴─────────────────────────────────────────────┘
```

- **Primary action:** Answer (⌘↵), or Done, try again for a task.
- **Hero detail:** the monogram row and the cascade (§3.2).
- **The AI draft (in progress):** the draft appears as **ghost text inside the well**, never pre-filled as if the user typed it. A dashed rule and a chip sit under it: "draft · from your profile" / "from your story *Payments migration*" / "drafted · not from your facts". **Tab** accepts the draft and **Esc** clears it. A draft that isn't grounded in the user's facts says so in coral and can't be accepted with Tab alone: the user must edit it or press ⌥Tab. This reuses `StorySuggester` and `memorySuggestion` (`InboxModel.swift:288-460`). It's the same honesty contract as the outreach `grounded / unsupported_claims` (`protocol.md:147`).
- **Time estimates** per cluster sit in the list's trailing column on hover ("~30 s"), which feeds the briefing.
- **States:** empty (the §3.2 end card, or "Nothing needs you. The agent will ask here when a form wants something only you know."); loading (skeleton rows); disconnected (Answer becomes "Save. Sends when the agent is back"); send error (inline under the composer, keeping the text).
- **Differs from today:**
  - The monogram row, ghost-text drafts and time estimates are new.
  - LinkedIn **Easy Apply moves in here** as a "Do it yourself" section (§12). It's a list of tasks only you can do, which is exactly what Needs You means.

### 4.3 Review

- **Job to be done:** "Check it before it goes, quickly, and trust what I don't check."
- **Layout:** as today (`Features/Review/ReviewView.swift`): flagged items first, then the page-as-sent screenshot beside every answer, hover-linked. Two additions:
  - **Confidence lens.** Flagged fields glow coral *on the screenshot*. Pressing **N** jumps to the next flagged field.
  - **Earned trust.** After you approve 10 applications on one application site with no edits, a quiet line appears under the header: "You've approved 10 Greenhouse applications without changes. Let Greenhouse jobs send on their own? [Turn on] [Not now]". The mode stays per site, which `SettingsTabs` already models.
- **Primary action:** **Approve & send** (⌘↵). It changes from "Approve & submit" to match the glossary's "Applied / send".
- **Hero detail: the send hold.** Approving doesn't send straight away. The row compresses into a capsule reading "Sending in 5 s · Undo". The paper-plane symbol draws on with SF Symbols 7 *Draw* (`.symbolEffect(.drawOn)`), then flies right off the row. This closes the audit's finding that Approve, the irreversible action, has no undo (`ReviewModel.swift:280`). The hold is client-side, like the Needs You undo: the command is only sent when the window closes.
- **States:** empty ("Nothing to look over. In Review mode, filled applications wait here for your OK."); loading (skeleton list, grey page); disconnected (Approve disabled: "The agent isn't running, so nothing can send."); in flight ("Sending…" badge).
- **Differs from today:** the send hold, the confidence lens, earned trust, and N for the next flagged field.

### 4.4 Pipeline

- **Job to be done:** "Where does everything stand, and can I move things myself?"
- **Layout:** the kanban stays (`Features/Board/*`), with three changes:
  1. **Closed drawer.** Rejected and Ghosted fold into one narrow trailing column, **Closed (23)**, collapsed to a vertical label by default. Click it to expand. This stops the board becoming "a wall of failure", which `Palette.rejected` already tries to soften by desaturating.
  2. **Card patina.** A card's age shows as a hairline that slowly fills along the card's bottom edge over 21 days, the auto-ghost horizon. That's honest time without a red "7 days" badge. "Heard back?" stays as a text badge on days 7 and 14.
  3. **The "I applied myself" slot.** When dragging a card the agent never submitted over Applied, the insertion slot already says what the drop does (`KanbanColumn.swift`). Give it a person symbol and the words "You applied". The user's actions are coral-adjacent (`person.fill`); the agent's are green (`cpu`). Same rule as the timeline icons (`JobTimeline.swift`).
- **Primary action:** none (drag), as today.
- **Hero detail:** a matched-geometry flight from card to Job detail header (monogram, company, title). It's the app's one navigation flight (§6.3).
- **States:** empty ("No jobs yet. The agent fills this in as it finds them. [Add a job by link ⌘N]"); disconnected (drag off, with a line saying why; exists); filtered-empty ("No jobs match these filters. [Clear filters]").

### 4.5 Job detail

- **Job to be done:** "Why this job, what did the agent do, and what's next?"
- **Layout:** 6 tabs become 4: **Why** (match evidence plus description), **Questions** (only while open), **Record** (answer log, page as sent, screenshots and timeline in one chronological scroll) and **Prep** (Assessment / Interview / Offer, or once a pack exists). Merging Application, Screenshots and Timeline (`JobDetailView.swift:17-27`) fixes the "where did it go?" problem: it's all one record, in order.

```
┌ ⓡ Razorpay · Senior Software Engineer          Applied ▾  [ Prepare ] ┐
│ Bengaluru · Greenhouse · found 3 Oct · applied 4 Oct 09:58            │
├ Why │ Record │ Prep ──────────────────────────────────────────────────┤
│ 82  Strong match                                                      │
│ ✓ Go, distributed systems       "4 yrs Go at Juspay" — your profile   │
│ ◐ Payments domain               "UPI reconciliation" — story          │
│ ✕ Kubernetes in production      not in your profile                   │
│ Dealbreakers: none · Posting checked live 4 Oct 09:41                 │
└───────────────────────────────────────────────────────────────────────┘
```

- **Primary action:** state-dependent, as today (Approve & send / Answer / Queue / Prepare).
- **Hero detail:** **"Explain why"**, the requirements table from `MatchBreakdown.swift` promoted to the top of the first tab, with quotes from the user's own profile. Every score in the app (card, inspector, palette) links here.
- **States:** loading (header placeholders, tabs disabled); posting closed (a quiet banner, "This posting closed on 9 Oct (checked automatically)", from the liveness work in `991f1b8`); load error (inline, Try again).
- **Differs from today:** 4 tabs instead of 6, Why first, "Record" as the honest single history, and the posting's liveness timestamp shown.

### 4.6 Cold Email

- **Job to be done:** "Reach the people behind the jobs I've applied to, without being spammy or fake."
- **Layout:** 5 tabs become 3: **Outbox** (drafts, scheduled, sent, with replies inline), **People** (Contacts plus Referrals; "who could refer you" is a filter, not a tab) and **Prospects**. Follow-ups aren't a separate tab: they're the Outbox's "Follow-ups due" section.
- **Primary action:** **Send N…** (Outbox), the only path to sending, as today (`OutboxTab.swift`).
- **Hero detail: the fact-check underline.** In the draft editor, claims the fact check couldn't find get a coral dotted underline. Hovering one says "Not found in your profile or stories" and offers **Remove** or **It's true**. The send sheet shows a **schedule ribbon**: a 09:30–17:30 timeline with 6 small marks spaced along it ("6 emails over about 40 minutes"). The pacing promise becomes a picture.
- **States:** sending off (one calm notice: "Sending is off until a test email to yourself goes through. [Send test]"); empty Outbox ("No drafts. After each application the agent can draft a short note for you to check."); bounces live in the contact row, not as alerts.
- **Award build:** Prospects (Google search for companies) is hidden behind Settings ▸ Labs for the award build (§12). Outreach to people about jobs you applied to is defensible in front of a juror; cold prospecting at scale is a harder story.

### 4.7 Onboarding

- **Job to be done:** "Trust this enough to let it act for me, in under ten minutes."
- **Layout:** Ignition stays (`Onboarding/Ignition/IgnitionView.swift`), recoloured to the trail motif (§5.6). The 7 steps become 5:
  1. Check this Mac
  2. Your résumé, read back as a profile you correct
  3. What you want
  4. Facts only you set
  5. How it should work: Review or Auto, plus the account-creation consent row, sources and mailbox

  The Story bank moves out of onboarding. It's asked for the first time a behavioural question arrives in Needs You ("Add a story once, use it everywhere").
- **Primary action:** Continue (⌘↵).
- **Hero detail: "Watch it work".** The last screen picks the best-scoring discovered job and offers **"Fill this one while you watch"**. Over the shoulder (§3.1) opens in Review mode, so nothing sends. The user ends onboarding having *seen* the agent fill a real form and having approved, or not, their first application. That's the most persuasive minute in the app.
- **Demo path for jurors and the curious:** on the welcome screen, a secondary link: **"Explore with sample data"**. It launches the app on the existing `MockDaemon` (`App/AppBootstrap.swift`, `Mock/MockScenario.swift`) with a clear "Sample data" capsule in the toolbar and a "Set up for real" button. A juror who won't install Claude Code, uv, Node and Chrome still sees every signature moment.
- **States:** system check failure (an Install row with the exact terminal line in a well, as today); résumé parse failure ("We couldn't read this PDF. Try another, or paste your résumé text."); quit mid-way (resumes at the same step; exists).

### 4.8 Menu bar

- **Job to be done:** "Supervise without opening the app."
- **Layout:** today's panel (`Features/MenuBar/MenuBarExtraViews.swift`), with three changes:
  - **Answer inline.** The top Needs You question appears with a compact composer: yes/no and short choices as buttons, and short text in a one-line field. ⌘↵ answers, and the panel says "14 jobs back in the queue".
  - **The briefing line.** "6 to do · ~9 min · [Start]" opens the main window straight into the session.
  - **The glyph.** It becomes the custom `aa.plane` symbol (§5.5) with four states: outline when idle, filled with *variable draw* progress while applying (the plane's trail draws as `dailyUsed/limit`), a coral dot for "needs you", and slashed when paused. No pulse; the draw progress is the motion, so it is honest and Reduce Motion safe.
- **Primary action:** the inline Answer when a question is shown, otherwise Open AutoApply.
- **States:** agent down ("The agent isn't running. [Start]"); paused ("Paused · [Resume]"); nothing to do ("All clear · next run 11:30").

---

## 5. Visual language

### 5.1 Type

- **SF Pro, with Display sizes for anything 20 pt and up.** Keep `Typography` (`DesignSystem/Tokens.swift`). The greeting stays at 46 semibold with −1.4 tracking, as a solid colour.
- **Two voices.** This is the typographic idea that carries principle 2:
  - **The user and the app speak in SF Pro.** Headings, copy and buttons.
  - **The agent speaks in SF Mono.** Step ticker, live narration, timestamps, the Activity log and provenance chips.

  Today SF Mono is also used for every uppercase eyebrow (`Typography.caption`, 108 uses, per the audit). That makes the app read like a developer tool and dilutes the agent's voice. **Change `eyebrowStyle()` to SF Pro Text 11 semibold, sentence case, `textSecondary`.** Reserve mono for the agent.
- **Rounded only for numerals that are the subject** (hero counts, metric tiles, the countdown): `Typography.metric*`. Never for words.
- **Numerals:**
  - Tabular (`monospacedDigit`) wherever a number can change.
  - Indian digit grouping when the locale is `en_IN` or `hi_IN` (12,00,000), via `formatted(.number)` with the user's locale. Never hand-format.
  - Salary shows "₹18 L CTC", using lakh and crore abbreviations in Indian locales.
- **Line length:** reading text is capped at 72 characters (`.frame(maxWidth: 560)` on Why, Record and Prep prose).

### 5.2 Colour

The palette stays: ink, stone, deep green (accent `#0F5C4F` / `#29AB8B`) and coral (`#C2461F` / `#FF7759`). What changes is that **each colour gets a job.**

| Colour | Means | Used for | Never |
|---|---|---|---|
| **Ink / white** | You decide | The one primary pill (`primaryFill`) | Decoration |
| **Deep green** | The agent and its good work | Selection, toggles, links, agent status, the trail, "Applied" | Warnings |
| **Coral** | A human is needed | Needs You badge and markers, flagged fields, unsupported claims, the "you" person glyph | Surfaces, large fills, errors |
| **Stone** | Paper | Wells, inputs, the page-as-sent mat | Text |
| **Status hues** | Pipeline stages only | Card bars, column headers, funnel | Outside Pipeline, Job detail and charts |
| **Error red** | Something broke | Errors only | Rejections, ever |

The rule a designer can repeat: **green is the agent, coral is you.** If coral appears, the user has something to do. The current idle coral breath (`DashboardHero.swift:38`) breaks the rule, because coral there means nothing, so it goes.

Also:
- **Two greens:** `Palette.applied` (`0x2F8F46`) and the brand accent compete (audit §2). Keep applied's yellower green for the status hue only, and use the brand accent for every non-status "done" check.
- **Dark mode is first-class.** The brand field is already always dark media. Every screenshot in the award submission should exist in both appearances.

### 5.3 Liquid Glass rules

1. **The system's glass is free:** toolbar, sidebar, inspector column, sheets, menus, menu-bar panel chrome.
2. **In-window glass floats over content and controls it:** `GlassBar` (bulk, session, paused), toasts, ⌘K, the send-hold capsule. Use `glassChrome` (`DesignSystem/Materials.swift`).
3. **The brand field is media, and glass on it is allowed:** hero panels via `heroGlass`, Dashboard only (the existing lint allowlist). The Over the shoulder window and the onboarding canvas join the allowlist, since they sit on the same brand media.
4. **Glass never sits on reading content.** No lists, prose, forms or charts.
5. **Morph, don't swap.** When one glass element becomes another (the session bar becomes "Done for today"; the bulk bar's actions become the safeguard question; a toast becomes the undo ring), put them in a `GlassEffectContainer` with `glassEffectID` so Liquid Glass morphs between them. That's the one Liquid Glass behaviour jurors will notice, and today it's unused.
6. **Reduce Transparency:** every glass element has the opaque fallback that `glassChrome` and `heroGlass` already provide.

### 5.4 Depth

Flat content with hairlines, as today. Depth comes from exactly three things: the system's glass layer, the brand field behind the hero, and the 1.03 drag lift (`dragLift`). Nothing else gets a shadow.

### 5.5 Iconography and the app icon

**SF Symbols everywhere, plus a small custom set of 6** drawn in the SF Symbols app with all weights and *Draw* annotations (SF Symbols 7):

| Symbol | Meaning |
|---|---|
| `aa.plane` | The agent and the app: a paper plane folded from a form, with two field lines on the wing |
| `aa.plane.trail` | Variable-draw progress (menu bar, daily limit) |
| `aa.onetomany` | Answer once, many jobs (Needs You, the briefing) |
| `aa.takeover` | Take over (a hand on the plane) |
| `aa.record` | The record or receipt |
| `aa.closed` | The Closed drawer: a soft fold, not an X |

**The app icon** (built with Icon Composer for macOS 26's layered Liquid Glass icons; replace `app/scripts/make_icon.swift`, which still paints the rejected purple gradient):
- **Back layer:** a deep-green field (`#003C33` → `#0F5C4F`, top-left light).
- **Middle layer:** a stone-white paper plane, folded visibly from an application form, with two faint ink field lines across the wing.
- **Front layer:** a small coral dot at the plane's nose. That's "you", the human it flies for.
- **Glass:** specular highlight on the plane only.
- **Variants:** Light, Dark (ink field, stone plane), Tinted (monochrome plane) and Clear all come from the same layers.
- **Test:** it should read at 16 px as "a pale plane on green with a warm dot".

### 5.6 Illustration and 3D

**No 3D, no stock illustration, no mascots.** The one illustrative motif is **the trail**: the line a paper plane leaves. It already exists in Ignition's canvas trail and the hero's flow edges. Reuse it:

- as the edges of the pipeline flow;
- as the cascade's flight paths;
- as the week recap's single chart (one line, your week);
- as empty-state art: a short trail ending in the `aa.plane` symbol, drawn on once with *Draw*, then still.

One motif, used everywhere, is what makes a visual language recognisable.

### 5.7 Data visualisation

- **Swift Charts only.** Direct labels and no legends, as `SourcesChart` does today. Every chart answers one question, written as its title ("Do your scores predict replies?").
- **Small samples are said out loud:** hatched bars and "n = 6, too few to tell", as `VariantChart` does today. Extend it to every rate.
- **No cumulative failure.** No "total rejections" anywhere. Rates are shown against applied.
- **Indian number formatting**, and axis labels in the user's locale.
- **Colour:** single-series charts use `accentRamp`. Status charts use status hues, each with a label (never colour alone).
- **Charts live in What's working, not on the home screen** (§4.1). The Dashboard keeps only the one-line "This week" strip with a sparkline.

---

## 6. Motion language

### 6.1 Named curves

Keep `DesignSystem/Motion.swift` as the only place curves are defined, and add three:

| Name | Definition | Use |
|---|---|---|
| `snappy` | spring 0.28 s, bounce 0 | Hover, selection, toggles (Tier 1) |
| `settle` | spring 0.45 s, bounce 0.12 | Cards entering, drops landing, sheets |
| `flow` | spring 0.70 s, bounce 0 | Stage-to-stage movement, particles |
| `celebrate` | spring 0.55 s, bounce 0.32 | Moments only (interview bloom, inbox-zero card) |
| `gentle` | smooth 0.9 s | Chart data, field drift easing to rest |
| **`flight`** *(new)* | spring 0.55 s, bounce 0.05 | Matched geometry and the cascade monograms |
| **`hold`** *(new)* | linear, duration = the undo window | Undo rings and send-hold countdowns, which must be linear to be honest |
| **`settleField`** *(new)* | easeOut 1.2 s | The brand field coming to rest after wake |
| `reducedFade` | easeInOut 0.18 s | The Reduce Motion substitute |

### 6.2 Choreography rules

1. **One leader.** Each moment has one element that moves first. Followers start 30 ms apart, at most 8 staggered, and the rest move together (`Motion.staggerDelay`).
2. **Direction has meaning.** The agent's work moves left to right, the direction of the pipeline. The user's answers move toward the agent: the cascade flies toward the sidebar's Pipeline row. Closing things moves down and folds.
3. **Never block input.** Every Tier 3 moment is non-modal and skippable with any key or click, as `EasterEggOverlay` is today.
4. **One moment at a time.** If two moments collide (for example a submission celebration during a cascade), the later one waits or is dropped. `CelebrationGate` already does this for submissions; generalise it into `MomentGate` in `DesignSystem/Components/Celebration.swift`.
5. **Numbers roll, words cross-fade.** `numericRoll` for numbers and `.contentTransition(.interpolate)` for sentences. Never slide text.

### 6.3 Matched-geometry flights

There are only three, so that each one means something:

1. **Pipeline card → Job detail header** (the monogram, company and title) when Job detail is pushed in the same window. This uses `matchedGeometryEffect` with a namespace on `RootView`'s detail stack.
2. **Needs You monograms → sidebar Pipeline row.** This crosses the split view, so it's an overlay at the root using anchor preferences, not `matchedGeometryEffect`.
3. **The Review row → send-hold capsule → off-screen right.**

Opening a job in its own window (`WindowID.job`) doesn't fly; it uses the system window animation.

### 6.4 Physics

Springs only for movement, and linear only for time (countdowns). Drag uses the existing lift and ±1.5° rotation from pointer velocity (`dragLift`). Confetti physics stays closed-form and reserved for easter eggs (`EasterEggs/Confetti.swift`).

### 6.5 Reduce Motion counterparts

| Moment | Full | Reduce Motion |
|---|---|---|
| Brand field wake | 8 s drift, then settle | Still frame, always |
| Pipeline particles | Flying particles, flowing edges | Lit static diagram; counts cross-fade |
| Cascade | Monograms fly to the sidebar | Monogram row cross-fades out; badge number cross-fades; toast text says "14 jobs back in the queue" |
| Send hold | Plane draws on and flies | Capsule shows "Sending in 5 s" with a numeric countdown and no plane flight |
| Interview landed | Card flight and bloom | Card appears in Interview; sheet fades in; sound still plays if sounds are on |
| Session bar morph | Glass morph | Cross-fade |
| Menu-bar glyph | Variable-draw progress | Same; it's a value change, not a loop |
| Easter eggs | Card and confetti | Card cross-fades, no confetti (as today) |

### 6.6 CPU and energy budget

Measured with Instruments (Time Profiler plus Animation Hitches) and Activity Monitor's Energy Impact on an M1 Air, in release builds.

| Situation | Budget |
|---|---|
| App open, agent idle, window visible, after the 8 s wake | **0 animation frames.** < 1 % CPU averaged over 60 s. Energy Impact < 1 |
| Agent working, Dashboard visible | ≤ 30 fps flow, ≤ 20 fps field; < 8 % of one core; no hitches > 1 frame |
| Window hidden or occluded | 0 frames (`WindowVisibility.swift` already gates this) |
| Menu-bar panel closed | Glyph changes only on state changes; no `TimelineView` |
| The two 500 ms polls (`GRDBRepository.swift:26`, `AppStore.swift:131`) | Document them; drop to 2 s while the window is hidden |

**Enforce it in tests.** `DashboardHero.motionActive` and a new `HeroWake` are pure functions with unit tests. A render test asserts that no `TimelineView` is unpaused in the settled idle state.

---

## 7. Sound and haptics

### 7.1 The palette

Replace the system sounds in `DesignSystem/Sounds.swift` (Tink, Pop, Purr, Glass, Basso) with **five custom sounds** that share one material: **paper**. They're short, dry and warm, so they fit the paper-plane mark. Each is under 400 ms, except `landed` (about 900 ms), mastered around −24 LUFS and played at 0.35–0.5 volume.

| Cue | Sound | Plays on | Default |
|---|---|---|---|
| `answer` | A soft paper slide | Answering a Needs You cluster | Off |
| `send` | A light fold and a short air release | The send hold completing (the application actually goes) | Off |
| `clear` | Two soft paper taps, rising | Inbox zero; session "Done for today" | **On** |
| `landed` | Two warm notes (a major third), wooden, with a paper rustle tail | Interview or Offer confirmed | **On** |
| `egg` | A playful pluck | Easter eggs only | **On** |

**Removed:** `denied` (Basso). No sound in the app signals failure, error or rejection. Errors are visual and announced to VoiceOver; they're never sonic.

### 7.2 On or off by default

**Default: "Moments only".** `clear`, `landed` and `egg` are on; routine cues are off. Settings ▸ General ▸ Sounds becomes a three-way choice: **Off · Moments only · All**.

Why: today every answer plays `pop` and every inbox zero plays `celebrate` (`InboxModel.swift:566-570`). For an anxious user working through 20 questions, 20 sounds is noise, while one sound at the end is a reward. Routine sounds also break the respect for a quiet Mac that jurors expect. The app also honours the system's **Play user interface sound effects** setting: when that's off, AutoApply plays nothing except `landed`.

### 7.3 Haptics

These are Force Touch trackpad only. Keep `DesignSystem/Haptics.swift` and its default (on): haptics only follow the user's own gestures, so they're never intrusive.

| Pattern | When |
|---|---|
| `alignment` | Snapping: chart scrub to a day, match-bar drag every 5 points, kanban insertion slot changing |
| `levelChange` | A drop landing in a new column; the end of a cascade (once); Pause toggled; send hold completing |
| `generic` | A drag entering a legal drop zone |

Never: a haptic per monogram, per particle, or on anything the agent did by itself.

---

## 8. Platform depth

Apple rewards apps that feel as if Apple built them into the OS. Effort is S = days, M = 1–2 weeks, L = more. Priority is P1 (award-critical), P2 (strong) or P3 (nice).

**A build-system prerequisite.** The app is a SwiftPM executable packaged by `app/scripts/make_app.sh`, so app extensions (widgets, Quick Look, Focus filter extension) can't be built today. Add an Xcode project, or an `xcodebuild` workspace that wraps the package, with an App Group container for the read-only DB snapshot. That's **M, P1**, and a dependency for every row marked ⚑. App Intents, Spotlight, notifications and NSUserActivity live in the main app and don't need it.

| Capability | Value for this app | Effort | Priority |
|---|---|---|---|
| **Actionable notifications** (UNNotificationCategory and `UNTextInputNotificationAction`) | Answer a yes/no or short question from the notification banner: "Notice period? [30 days] [Other…]". Approve from a "Ready for review" notification via **Open**, never with blind approval. Today notifications only route (`Core/System/AppNotifier.swift`) | S | **P1** |
| **App Intents and Shortcuts** | `PauseAgentIntent`, `RunNowIntent`, `WhatNeedsMeIntent` (returns the briefing sentence, so Siri can read "2 questions, about 3 minutes"), `AddJobFromURLIntent` (also the Share menu target from Safari), `AnswerQuestionIntent` (parameterised by a `QuestionEntity`). App Shortcuts phrases: "Pause AutoApply", "What does AutoApply need?" | M | **P1** |
| **Spotlight** (Core Spotlight plus `IndexedEntity`) | Index jobs (company, title, status), open questions and stories. Typing "Razorpay" in Spotlight opens Job detail. In macOS 26, Spotlight can also run our App Intents as actions ("Pause AutoApply") with no window | S–M | **P1** |
| **Desktop widgets** (WidgetKit) ⚑ | Small: Needs You count, coral, tap to open. Medium: the briefing sentence with an interactive **Pause/Resume** button (`Button(intent:)`). Large: Your week (§3.6). Read from an App Group DB snapshot written by the app; never talk to the daemon | M (after the build prerequisite) | **P1** |
| **Menu bar as our Live Activity** | macOS 26 shows *iPhone* Live Activities in the Mac menu bar; as far as we know there's no ActivityKit for Mac-native apps, so verify against the current SDK. Our `MenuBarExtra` with the variable-draw glyph is the Mac-native equivalent, and §4.8 makes it fully live and answerable | S (part of §4.8) | **P1** |
| **Full keyboard support** | Already strong (about 30 shortcuts, `Core/Keyboard/ShortcutRegistry.swift`). Add: session navigation (⌘↵ next, ⌘[ back), N for the next flagged field in Review, ⌘T Take over, Tab/⌥Tab for drafts. Restore visible focus on every screen (audit §2). Publish a ⌘/ shortcut sheet | S | **P1** |
| **Focus filters** (`SetFocusFilterIntent`) ⚑ | A Work focus or a custom "Job hunt" focus can pick "notify for Needs You and interviews only" or "silence everything; queue for the briefing". When a Sleep focus is on, the agent applies but holds notifications for the morning briefing | S–M | P2 |
| **NSUserActivity and Handoff** | Advertise the current Job detail, Needs You cluster and Review item, so state restoration, Siri suggestions and (later) Handoff to an iPhone work. Cheap and correct | S | P2 |
| **Quick Look** | Already: Space on screenshots (`ScreenshotViewer.swift`). Add: Space on a résumé variant (PDF) and on any job row, which previews the page-as-sent. A Quick Look extension for exported application records isn't worth it | S | P2 |
| **Stage Manager and windows** | Job detail and Over the shoulder are separate window scenes with sensible `defaultSize`, so they tile beside the agent's Chrome in Stage Manager. Restore open job windows across launches. Ensure the onboarding window (`.hiddenTitleBar`) behaves in Stage Manager sets | S | P2 |
| **Calendar** (EventKit, write-only, on demand) | "Add to Calendar" from the interview moment (§3.4) | S | P2 |
| **Share extension** ⚑ | Share a job posting from Safari or Chrome → "Add to AutoApply". Covered first by the App Intent in the Share menu; build the extension only if that isn't enough | M | P3 |
| **iPhone companion** | High value for Indian users, who are mobile-first: answer questions on the bus. But it needs sync for a local-first app (CloudKit private DB with encrypted fields), a second UI and review. **Not this cycle.** Actionable notifications and widgets cover 70% of it | L | P3 (next year) |

---

## 9. Inclusivity and accessibility

### 9.1 VoiceOver narrative for the live agent

The agent is a moving system; VoiceOver users need a narrator, not a firehose.

- **Announce state changes, not steps:** "Agent is filling an application for Razorpay, Senior Software Engineer." / "Application sent to Razorpay." / "Agent needs you: 1 new question." `AnnouncementThrottle` (`LiveAgentCard.swift:35`) exists; extend it to the state machine with one announcement per state change and at most one every 10 s.
- **Steps are available on demand.** In Over the shoulder, the field list is an accessibility container with a **custom rotor, "Filled fields"**. Each element reads "Notice period: 30 days, from your profile" or "Expected CTC: 18 lakh, drafted, medium confidence, flagged".
- **The pipeline flow canvas** exposes one element per stage ("Queued, 4 jobs") and one summary ("4 queued, 1 filling, 22 applied this week"). The counts are already real `Text` overlays (`PipelineFlowView.swift`), so make sure they're ordered and labelled.
- **The cascade** announces "14 jobs back in the queue. Undo available for 10 seconds," and Undo is reachable with ⌘Z (exists).
- **The 12 icon-only buttons** without labels (audit §2) get labels. A lint test asserts every `Image`-only `Button` has `.accessibilityLabel`.

### 9.2 Text size on macOS

macOS doesn't scale `Font.system(size:)` with the system text-size setting, and the type tokens use fixed sizes.

- Map every token to a text style (`.body`, `.callout`, `.title2`…) with `relativeTo:`, so the system's text-size setting applies where macOS supports it.
- Add an in-app **Text size** setting (Settings ▸ General: Default, Large, Larger) that scales `Typography` through an environment multiplier. The hero, lists and composer must reflow at Larger without truncating questions.

### 9.3 Colour-blind-safe status

Every status already pairs a hue with a symbol (`DesignSystem/StatusStyle.swift`). Keep it that way. Verify that Applied (green), Rejected (rose), Interview (blue) and Offer (gold) differ in **luminance** as well as hue under deuteranopia and protanopia, using the Sim Daltonism app. Coral "needs you" always comes with the hand or person glyph. Charts never encode by colour alone (direct labels, hatch for low samples).

### 9.4 Cognitive load for anxious users

- **A finish line every day** (§3.3) and **time estimates** on every to-do.
- **Never show totals of bad news** (§3.5, §5.7).
- **Progressive disclosure:** Technical details stay behind disclosures (already done for tokens and the pick score).
- **One question per screen** in the session; no list of 30 to scan.
- **A pause that feels allowed:** "Take a break", the existing Pause, also offers "for 3 days / a week". On return, the briefing says "Welcome back. Here's what changed while you were away," and never "You missed 40 jobs".
- **Plain words** (the glossary in `app/DESIGN_REDESIGN_PLAN.md` §3). Target a reading age of about 12 for all user-facing copy. Short sentences and no idioms, which also helps the Hindi translation.

### 9.5 Localisation readiness: Hindi and other Indian languages

- **Infrastructure.** Add a String Catalog (`Localizable.xcstrings`) and `defaultLocalization: "en"` to `app/Package.swift`, so SwiftPM bundles resources. Move interpolated strings to `String(localized:)` with plural variants: "14 jobs" and "1 job" are hand-pluralised today, e.g. `C3Format.plural`.
- **Languages.** English (India) first, with the lakh/crore and ₹ formats, CTC wording, and notice-period terms. Then **Hindi**. Then Tamil, Telugu, Bengali, Marathi and Kannada as community translations.
- **Devanagari layout.** Taller line height (+20%), no forced uppercase (eyebrows are already moving to sentence case, §5.1), and no tracking on non-Latin scripts.
- **What doesn't translate.** Job descriptions and form answers stay in the job's language (usually English). Only the UI is localised. Say so in onboarding.

### 9.6 Plain language and honesty in copy

Every string passes the glossary. The 14 inflated claims from the audit are fixed, and new copy goes through a "could a juror call this a lie?" review. For example, the DMG's "READ ME FIRST.txt" still says "Everything stays on your Mac; only…" (`app/scripts/make_dmg.sh`). Rewrite it to the honest version already used in the app.

---

## 10. Honesty and trust as design

Jurors in 2026 will look hard at any app where AI acts for the user. These are the features that make AutoApply's honesty *visible*.

1. **The Record (Job detail ▸ Record).** One chronological history per job: found, scored (with evidence), posting checked live, questions asked, each answer with provenance, the page as sent, submitted (with the confirmation evidence `submit_gate` already requires), and replies. Agent entries use the green `cpu` glyph and user entries the coral `person` glyph (`JobTimeline.swift`). Copy all exports it as text.
2. **"Explain why" on every score.** Any score, anywhere (card, inspector, palette, menu bar), opens the requirements table with quotes from the user's own profile and the job's own words for dealbreakers (`MatchBreakdown.swift`). A score with no evidence (older scores) says "Scored before evidence was recorded. [Re-score]".
3. **Undo windows on everything reversible, and a hold before the irreversible:**
   - 10 s on answers (exists);
   - 5 s send hold on Approve (new, §4.3);
   - undo on every board move (exists in `BoardModel`);
   - Cancel on scheduled outreach (exists).
4. **What left this Mac.** Settings ▸ Privacy ▸ **Data ledger**. It's a plain list of every Claude request, Gmail read and site-account creation over the last 30 days: what was sent (field names, not values), when, and for which job. "Your data stays on this Mac. Form text goes to Claude to draft answers; Gmail is read only for codes." becomes something you can check, not something you have to believe.
5. **Consent at the point of consequence.** Account creation stays a visible toggle next to the mailbox (the owner's decision in `app/DESIGN_REDESIGN_PLAN.md`). Every site account the agent created is listed with Forget (`SiteAccountsSection.swift`).
6. **Earned autonomy, not assumed autonomy.** First-run default is **Review**. Auto is offered per application site after a track record (§4.3). That gives a juror a one-sentence answer to "isn't this a spam bot?"
7. **Scam and legitimacy signals are shown, not hidden.** A "Looks risky" badge with the reason ("asks candidates to pay a registration fee") forces review. Its framing is "signals, never accusations" (`docs/CAREER_OPS_REVIEW.md` §4.3).
8. **The agent admits uncertainty.** "Check if applied" (`unknown_verify`) is a first-class state with **It was sent / It wasn't sent**. The agent never retries it silently (the existing rule).

---

## 11. Phased roadmap

Each deliverable lists the files or folders it owns, so parallel agents don't collide. "Shared" files have to be done by one agent, or sequenced.

### Phase 1: the award story (about 2 weeks)

| # | Deliverable | Owns | Notes |
|---|---|---|---|
| 1A | **Today Dashboard and morning briefing**: briefing model and view, "Done for today" state, "This week" strip; move the charts to What's working; cut the heatmap and Sources chart from the Dashboard; remove the idle coral breath and gradient text | `Features/Dashboard/**` (except `Hero/HeroStyle.swift`) | Briefing estimates come from `InboxStore` and `ReviewModel` counts, read-only |
| 1B | **Wake on arrival**: the `HeroWake` state, the new `motionActive`, `settleField`; energy test | `Features/Dashboard/Hero/HeroStyle.swift`, `DesignSystem/Components/BrandGradient.swift`, a new test | Coordinate the `DashboardHero.swift` call site with 1A (one line) |
| 1C | **Session bar**: walk-through of Needs You → Review → Replies, morphing into "Done for today" | new `Features/Session/**`; `Core/Navigation/Router.swift` (session queue) | Router is shared: 1C owns it this phase |
| 1D | **The cascade and ghost-text drafts in Needs You**: monogram row, flight overlay, undo ring on toasts, Tab/⌥Tab drafts with provenance chips, inbox-zero end card | `Features/Inbox/**`, `Core/Store/ToastCenter.swift`, `DesignSystem/Components/Celebration.swift` | The flight overlay host goes in `App/RootView.swift`: 1D owns RootView this phase |
| 1E | **Send hold and confidence lens in Review**; "Approve & send" copy; N for the next flagged field | `Features/Review/**` | Client-side hold, like `InboxModel`'s pending pattern |
| 1F | **Kind rejection**: no rejection notifications, Close it / Keep it open, the Closed drawer on the Pipeline, the closing card in Job detail | `Core/System/AppNotifier.swift`, `Features/Board/**`, `Features/Inbox/RepliesSection.swift` (coordinate with 1D), `Features/JobDetail/JobDetailView.swift` (header card only) | Job detail is touched only for the card; 2-tab merge is Phase 3 |
| 1G | **The app icon** (Icon Composer, 4 appearances) and **the `aa.plane` symbol family**; retire `make_icon.swift` | `app/scripts/`, new `app/Resources/Assets.xcassets` / `.icon` | Needs `Package.swift` resources: coordinate with 2A |
| 1H | **Actionable notifications** with inline answers for yes/no and short text | `Core/System/AppNotifier.swift` (after 1F's change, same agent recommended) | Uses the existing answer command; same undo semantics, so post the confirmation notification after the window closes |
| 1I | **Explore with sample data** in onboarding (MockDaemon) and the "Sample data" toolbar capsule | `Features/Onboarding/**`, `App/AppBootstrap.swift` | Gives jurors and press a zero-install path |
| 1J | **Sounds "Moments only"** setting and the `denied` cue removed (system sounds until the custom ones in 3A) | `DesignSystem/Sounds.swift`, `Features/Settings/SettingsView.swift` (General tab only) | |

The Phase 1 exit test is a 90-second screen recording, starting in Sample data mode, that shows the briefing, Start, the cascade, the send hold, "Done for today", and the interview moment (via a mock reply).

### Phase 2: platform depth (about 2–3 weeks)

| # | Deliverable | Owns |
|---|---|---|
| 2A | **Build prerequisite**: an Xcode project or workspace wrapping the package, App Group, entitlements, asset catalog; `make_app.sh` becomes an `xcodebuild` call | `app/*.xcodeproj`, `app/scripts/**`, `app/Package.swift` |
| 2B | **App Intents and App Shortcuts**: Pause, Run now, What needs me, Add job from URL, Answer question (with `JobEntity` and `QuestionEntity`) | new `App/Intents/**` |
| 2C | **Spotlight**: Core Spotlight indexing of jobs, questions and stories, `IndexedEntity` conformance, index updates on store change | new `Core/System/SpotlightIndexer.swift`; entities shared with 2B (2B owns them) |
| 2D | **Widgets** (small, medium with interactive Pause, large "Your week") plus the App Group DB snapshot writer | new `Widgets/**` target; new `Core/System/WidgetSnapshot.swift` |
| 2E | **Menu bar**: inline answer, briefing line, variable-draw glyph | `Features/MenuBar/**` |
| 2F | **Over the shoulder** window, Take over (⌘T), live provenance chips (needs `agent_step.field_label/source` in `contract/protocol.md`, `engine/autoapply/…`, generated `Core/Protocol/Messages.swift`) | new `Features/LiveAgent/OverTheShoulder/**`; protocol files (one owner) |
| 2G | **Focus filter, NSUserActivity, state restoration, Quick Look on résumés and job rows, Calendar for interviews** | new `App/Platform/**`; small hooks in `Features/JobDetail/**` (after 1F) |
| 2H | **Interview moment** (§3.4): confirmed-move flight, bloom, sheet with Calendar and Prepare | `Features/Inbox/RepliesSection.swift` (after 1D/1F), `Features/JobDetail/InterviewPrep*` |
| 2I | **App Store feasibility spike** (only if §13 decision 1 says go): sandboxed app, agent via `SMAppService` login item, Chrome automation outside the sandbox | spike branch only |

### Phase 3: craft (about 2–3 weeks)

| # | Deliverable | Owns |
|---|---|---|
| 3A | **Custom sound palette** (5 paper sounds), respecting the system UI-sounds setting | `DesignSystem/Sounds.swift`, `Resources/Sounds/**` |
| 3B | **Typography pass**: two voices (mono for the agent only, eyebrows to SF Pro), text styles with `relativeTo:`, in-app Text size, Indian number formatting | `DesignSystem/Tokens.swift`, plus a mechanical sweep of `eyebrowStyle()` callers (one agent, last, to avoid conflicts) |
| 3C | **Job detail 6 → 4 tabs** (Why, Questions, Record, Prep) | `Features/JobDetail/**` |
| 3D | **Cold Email 5 → 3 tabs**, fact-check underline polish, schedule ribbon; Prospects behind Labs | `Features/ColdEmail/**`, `Features/Settings/OutreachSettingsTab.swift` |
| 3E | **Your week recap** sheet and notification | new `Features/Dashboard/Week/**` (after 1A lands) |
| 3F | **Localisation**: String Catalog, plurals, en-IN formats, Hindi translation, Devanagari layout checks | `Resources/Localizable.xcstrings`; string sweep across features (last, coordinated) |
| 3G | **Accessibility audit**: VoiceOver narrative, rotors, labels lint, focus rings on every screen, deuteranopia check | tests plus small edits across features (last) |
| 3H | **Data ledger** (Settings ▸ Privacy) | `Features/Settings/**`, `contract/protocol.md` (a `get_data_ledger` command), engine |
| 3I | **Onboarding 7 → 5 steps** and "Watch it work" (depends on 2F) | `Features/Onboarding/**` |
| 3J | **Earned autonomy** prompt in Review | `Features/Review/**`, `ReviewModel` counters |
| 3K | **Empty-state trail art** (drawn on once) and the easter eggs moved to the new sound and symbol set | `DesignSystem/Components/States.swift`, `Features/EasterEggs/**` |

---

## 12. What to cut

Cutting is part of the design. Each of these dilutes the story.

| Cut | Why | Where |
|---|---|---|
| **Activity heatmap** on the Dashboard | It's a GitHub contribution graph for job hunting: streak pressure and guilt on empty days. Principle 4 | `Features/Dashboard/Widgets/ActivityHeatmap.swift` (delete; Activity log keeps the day filter) |
| **Sources chart, score histogram, funnel, variants and the 4 KPI tiles on the Dashboard** | A control room on the home screen. Funnel and variants move to What's working; the histogram's threshold drag moves to Settings ▸ Preferences | `DashboardView.swift:31-50` |
| **Idle coral breath and gradient greeting text** | Coral that means nothing; gradient text reads as generated | `Hero/DashboardHero.swift:36-40, 62` |
| **Per-submission celebration** in the live agent | It celebrates volume. Keep the quiet check (`SubmittedCheck`) and drop `RadialBurst` | `LiveAgentCard.swift:67-76` |
| **Routine sounds** (pop on every answer, Basso) | Noise for anxious users; failure should never be a sound | `DesignSystem/Sounds.swift` |
| **Easy Apply as its own sidebar item** | It's a list of tasks only you can do: a Needs You section | `Features/EasyApply/**` moves under Needs You; sidebar item removed |
| **Prospects in the award build** | Cold prospecting at scale is the hardest part of the app to defend to a juror | Behind Settings ▸ Labs |
| **Cold Email Follow-ups and Referrals as tabs** | Follow-ups are an Outbox section; referrals are a People filter | `Features/ColdEmail/ColdEmailView.swift` |
| **Job detail's separate Application, Screenshots and Timeline tabs** | One honest Record | `JobDetailView.swift:17-27` |
| **Story bank in onboarding** | Ask for it when it's needed | `Onboarding/Steps/PreferenceSteps.swift` |
| **The purple icon** | Rejected by the owner, and still shipping | `app/scripts/make_icon.swift` |
| **SF Mono eyebrows** | They dilute the agent's voice and read as a developer tool | `Typography.caption` / `eyebrowStyle()` |

---

## 13. Decisions needed from the owner

1. **The App Store question.** Historically, Apple Design Awards go to apps on the App Store; check the current year's eligibility rules before investing. AutoApply today is an ad-hoc-signed DMG that installs a Python agent and drives Chrome, which is hard to fit in the Mac App Store sandbox. Choose one:
   - fund a sandboxing spike (2I) and accept engineering cost and possible feature limits; or
   - treat the ADA as the quality bar rather than a submission, and aim for press and Apple editorial recognition instead.

   **Recommendation:** run the spike for one week in Phase 2 before committing.
2. **Dashboard: "Today" over "control room".** Approve moving the charts, KPI tiles and heatmap off the Dashboard, and the "wake on arrival, still while reading" rule instead of perpetual ambient drift. The Dashboard stays beautiful and alive when you arrive, but it stops moving on its own after 8 seconds.
3. **Default to Review mode with earned autonomy**, and lower the default daily limit, so the story is "fewer, better applications". This changes first-run behaviour for new users.
4. **Sound defaults and budget.** Approve "Moments only" as the default (most routine sounds off), and a small budget to commission five custom paper sounds and the Icon Composer icon. Both are the kind of craft jurors notice and generated assets can't fake.
5. **Scope for this cycle.** Confirm:
   - no iPhone companion this year;
   - Hindi localisation in Phase 3;
   - Prospects hidden behind Labs in the award build;
   - Easy Apply folded into Needs You.

---

## Owner decisions (2026-10-22): these override the recommendations above

1. **Eligibility:** build award-quality design anyway. No App Store spike now.
2. **Dashboard:** keep it **lively all the time**, as in today's living hero. Add the morning briefing ("Today's ten minutes") to it rather than replacing the control room. Charts and tiles stay. The "wake 8 s then rest" rule (1B) is **dropped**; the CPU safeguards stay: pause when hidden or paused, frame-rate caps, Reduce Motion.
3. **Autonomy:** earn it per application site (offer Auto after ~10 approvals without edits), **and the user can always choose any mode for anything** (global, per site, per company, per job), with no locks. Existing users keep their current settings.
4. **Scope:** all of Phase 1 (1A–1J, with 1A adjusted as in decision 2), plus a **Cold Email UX overhaul**. The owner rates the current UX very poor.
5. **Not cut:** Prospects stays visible, and Easy Apply stays its own screen.
