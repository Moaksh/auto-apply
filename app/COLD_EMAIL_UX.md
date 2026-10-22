# Cold Email UX: diagnosis and redesign (2026-10-22)

Owner verdict on the old screen: "bad af". This note says why, what replaced it, and what stayed
the same. Code: `Sources/AutoApply/Features/ColdEmail/**`.

## 1. Diagnosis (before)

These come from offscreen renders of every tab with the mock data (`Tests/AutoApplyTests/ColdEmailWindowShots.swift`,
run with `AUTOAPPLY_COLDEMAIL_SHOTS=<dir>`).

1. **Five equal tabs and no home.** Follow-ups, Prospects, Contacts, Outbox and Referrals sat side
   by side in a segmented control. The one thing that needs you (drafts waiting for approval)
   lived on the fourth tab, and the screen opened on a list of every application instead.
2. **No next step.** Follow-ups showed every applied job with the same weight: 88 rows of
   "Open thread", "Draft" and "Find people" links, plus a status badge and a contact badge on every
   row. Nothing said "do this one now".
3. **The job and the email were on different tabs.** "Open thread" jumped from Follow-ups to Outbox.
   Replies, scheduled, sent and "possibly sent" items were in the Outbox list, but the
   applications they came from were somewhere else.
4. **Dense rows with fixed widths.** Follow-ups (220 / 190 / … pt columns) and Contacts
   (220 / 140 / 300 / 130 / 110 pt) were spreadsheet-like. The email address, tier badge, info
   button, origin and "Never" all repeated on every row.
5. **Walls of explanatory text.** Follow-ups opened with a two-line paragraph. Referrals opened with
   a paragraph about LinkedIn limits, and the full note and message wells were expanded inline on
   most rows. The "Sending is off" notice was a full-width banner on two tabs.
6. **The draft didn't look like an email.** The To and Subject labels were in mono, and the body
   sat in a grey well with a separate grey well for the footer. The fact-check verdict was a badge
   floating above, and a claim problem was a separate box above the subject, away from the
   sentence it was about.
7. **Disabled primary at rest.** The only primary action, `Send…`, sat greyed out in the Outbox
   list header until you ticked a checkbox. With sending off it stayed disabled, while the banner
   above it said "Enable sending…" as a link.
8. **Referral status was hidden in a menu.** The state ("Connected", "To connect", …) looked like
   plain text but was a menu. The next step was one of up to three links ("Copy message & open",
   "Notes", "Draft note", "Open profile"), and there was no sense of progress.
9. **Prospects and Contacts were peers of the daily job.** These are occasional, secondary tasks,
   but they got the same prominence as approving drafts.

## 2. The new structure

The surfaces follow the jobs to be done, in this order:

| Job to be done | Where it lives now |
|---|---|
| Someone to contact about a job I applied to | **Up next ▸ Applied, no note yet**: the job, and the people found there with **Draft a note** |
| Drafts waiting for my OK | **Up next ▸ Waiting for your OK**, first in the queue and focused on open |
| Replies | **Up next ▸ Replies**: unread first, read in place, with Open in Gmail and Outcome |
| Companies I'd like to work at | **Companies** (prospects), one click from the header, still visible (owner decision 5) |
| People who could refer me | **People ▸ Could refer you**: a three-step checklist per person |

* **Up next is the screen.** On the left is a queue: *Waiting for your OK*, then *Replies*, then
  *Applied, no note yet* (the newest 5, with "Show all N"), then *Needs a check* (possibly sent or
  not sent), then *Scheduled* (each with Cancel), then *Sent* (folded). On the right is the focused
  item. On open, the first draft is focused. Without drafts, the newest unread reply is focused.
  Without either, the first application with no note yet is focused.
* **People and Companies are doors, not tabs.** They appear as two quiet links with counts in the
  header. Opening one shows "‹ Cold Email" (⌘[) and its own title. People merges Contacts and
  Referrals: the *Everyone* / *Could refer you* filter replaces two tabs.
* **The draft is shown the way the email will look.** A headline names the job ("Email Priya at
  Figma about Backend Engineer, Payments"), with "Next up · 1 of 3" and **Next draft ›** (⌘]).
  Below that is a single card with From, To (confidence badge, provenance and "Someone else"
  re-draft) and Subject. The body comes next, with any unsupported claim given a coral dotted
  underline and a callout right under the text: **Edit** or **It's true**. The locked footer sits
  at the bottom of the same card with a lock and one line: "Added to every email: where the address
  came from and how to opt out. It can't be removed." Under the card are *Include in this batch*,
  the fact-check badge, Edit and Discard.
* **The floating send bar holds the one primary action.** It's a Liquid Glass `GlassBar`, the only
  glass on the screen, and it's shown only while drafts wait:
  * Sending on: "Tick the drafts you're happy with" or "2 of 3 drafts ticked", then **Send N…**.
  * Sending off: "One-time setup: turn on sending. A test email goes to you first." with
    **Turn on sending…**. That's the whole nag: a calm setup step where the Send button would be.
  * No mailbox: one line and "Open Settings" (a link; there's no primary).
* **The send sheet** is unchanged in behaviour. It adds a **schedule ribbon**: the send window as a
  track, with a mark per email, and Weekdays only.
* **Referral checklist.** Each person is a card: their name, their basis badge and the job, then
  ① Connect on LinkedIn, ② Ask for a referral, ③ Hear back. Done steps show an accent check, the
  current step shows its one or two actions ("Copy note & open profile", "They accepted",
  "Copy message & open", "They referred me / They declined"), and later steps are dimmed. Every
  other state change, "Show note and message" and "Draft again" are in the ⋯ menu. Cards are
  grouped *In progress* and *Done*.
* **First run** (nothing to show): one calm surface with three steps: you apply, the agent finds
  someone and drafts a note, you read it and press Send. It adds "Nothing is sent without your OK"
  and two links (Add someone you know · Find companies). It has no primary action.

### Primary action per screen

| Screen | The one primary |
|---|---|
| Up next (drafts, sending on) | **Send N…** (floating bar) |
| Up next (drafts, sending off) | **Turn on sending…** (floating bar, one-time) |
| Up next (no drafts / first run) | none |
| People ▸ Everyone | **Add contact** |
| People ▸ Could refer you | **Add referral** |
| Companies | **Search** |
| Send N… sheet | **Send N emails** |
| Enable sending sheet | **Send test email** → **Done** |
| LinkedIn import sheet | **Choose Connections.csv…** → **Show referrals** / **Done** |

## 3. What did not change (safety)

* Nothing is sent without approval. **Send N…** is still the only path, per batch, through
  `approve_outreach`, and its sheet still lists every conflict (claim to check → Review; below the
  confidence bar → Send anyway; do-not-contact; closed conversation) with Leave out.
* The footer is stored apart from the body and can't be edited.
* LinkedIn is never automated. The copilot copies text and opens the profile in the user's own
  browser, then asks "Did you send it?".
* Do-not-contact: People ▸ ⋯ ▸ "Never email …", and Delete ▸ "Delete and never email".
* "Possibly sent" emails are never resent. They sit under *Needs a check* with "It was sent" /
  "It wasn't sent".
* Store and command APIs are unchanged. The model gained `peopleFilter`, `focusedJobID`,
  `jobsAwaitingNote`, `draftPosition` / `nextDraftID`, `isFirstRun` and `showPeople(_:)`.
  `ReferralState` gained `checklistStep` / `isOpen`.

## 4. Before / after notes

| Before | After |
|---|---|
| Opens on Follow-ups: 88 equal rows | Opens on the first draft, as an email |
| 5 segmented tabs | 1 screen + 2 doors (People, Companies) |
| `Send…` disabled in the Outbox list header | Floating bar: `Send N…`, or the one-time setup |
| "Sending is off" banner on two tabs | One line in the floating bar, only while drafts wait |
| Claim warning box above the subject | Dotted coral underline in the text, with Edit / It's true right under it |
| Footer in a separate grey well | Part of the email card, with a lock and one line |
| Contacts: 5 fixed-width columns | Two-line rows: name · title / company · email, then tier, origin, ⋯ |
| Referrals: state hidden in a menu, notes expanded | 3-step checklist, notes behind ⋯ |
| No first-run explanation | A three-step "what happens" card |

Screenshots: `…/scratchpad/coldemail/before/*.png` and `…/scratchpad/coldemail/after/*.png`
(from `ColdEmailWindowShots`).
