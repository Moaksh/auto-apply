# Security policy

## Supported versions

AutoApply is in beta. Only the [latest release](https://github.com/Moaksh/auto-apply/releases) gets
fixes. Installed apps from 0.1.1 onward update themselves.

## Reporting a vulnerability

Please report security issues privately through GitHub:
**[Report a vulnerability](https://github.com/Moaksh/auto-apply/security/advisories/new)**
(the Security tab ▸ Report a vulnerability). Don't open a public issue, and don't include real
credentials, resumes or logs that you haven't redacted.

Include what you found, how to reproduce it, the app version and macOS version, and what an
attacker could do with it. You'll get an acknowledgement as soon as the maintainer sees it, and a
fix or a plan in the advisory. Credit is given in the release notes unless you'd rather not be
named.

## Scope

AutoApply runs entirely on your Mac. Things we especially want to hear about:

- **The local agent socket.** `autoapplyd` listens on a Unix socket (`autoapplyd.sock`) in
  `~/Library/Application Support/AutoApply/`. Another local user or a sandboxed process being able
  to connect to it, or any command that reads or writes outside the AutoApply folder.
- **Credentials.** Job-site account passwords, the mailbox app password and email-finder API keys
  are stored in the macOS Keychain. Anything that writes them to disk, logs, the database,
  screenshots, issue reports or a prompt sent to Claude.
- **Submitting without consent.** Any way to get an application or a cold email sent without
  passing the guardrails: the daily cap, the per-company cooldown, Review approval, or the browser
  agent's submit gate.
- **Prompt injection from web pages.** A job posting, career page or email that makes the agent
  leak your data, click outside the application flow, or submit something you didn't approve.
- **Log redaction.** Personal data that survives the redaction in Report a Bug.
- **Updates.** Anything that lets the self-updater install something other than a release from
  this repository.

Out of scope: problems in Claude Code, Chrome, Playwright or macOS themselves (report those
upstream), and anything that needs an attacker who already has full control of your user account.
