"""Cold outreach (docs/COLD_EMAIL_PLAN.md): finding people at a company, grounded drafts,
approval, sending from the user's Gmail, follow-ups, replies, and the LinkedIn referral copilot.

Rules this package keeps:

* Nothing is sent without the user's ``approve_outreach``; sending is off until a test email
  to the user's own address succeeds (``enable_sending``); ``pause_all`` stops the sender.
* The model only extracts, classifies and drafts. Every extracted name must appear word for
  word in the page it came from; it never produces an email address.
* Every draft is fact-checked against the profile, stories and job (``answers.cover_letter``);
  unsupported claims block approval unless the user confirms them.
* LinkedIn is never opened: people are found through Google's result pages only, and the
  referral copilot leaves every LinkedIn step to the user's own browser.
* No SMTP ``RCPT`` probing. Bounces are the verifier.
"""
