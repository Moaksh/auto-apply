# GitHub repository setup

Settings that live on GitHub rather than in the repo. They help the project show up in topic pages
and on GitHub Explore, and they complete the Community Standards checklist (Insights ▸ Community
Standards).

## Description, website and topics

Description (under 350 characters):

> A local-first Mac app that finds jobs, applies for you, and asks only when it doesn't know the answer. Match scores with evidence, a review queue with Undo, a pipeline board, and cold email to startups near you. Runs on your own Claude login; your data stays on your Mac.

Apply it with the GitHub CLI from the repo folder:

```bash
gh repo edit Moaksh/auto-apply \
  --description "A local-first Mac app that finds jobs, applies for you, and asks only when it doesn't know the answer. Match scores with evidence, a review queue with Undo, a pipeline board, and cold email to startups near you. Runs on your own Claude login; your data stays on your Mac." \
  --homepage "https://github.com/Moaksh/auto-apply/releases" \
  --add-topic macos \
  --add-topic swiftui \
  --add-topic swift \
  --add-topic python \
  --add-topic job-search \
  --add-topic job-application \
  --add-topic automation \
  --add-topic ai-agent \
  --add-topic claude \
  --add-topic llm \
  --add-topic playwright \
  --add-topic local-first \
  --add-topic privacy \
  --add-topic cold-email \
  --add-topic career \
  --add-topic productivity
```

(GitHub allows up to 20 topics; this sets 16.)

## Manual steps (web only)

1. **Social preview image.** Settings ▸ General ▸ Social preview ▸ Edit ▸ Upload an image, and
   choose `docs/media/social-preview.png` (1280×640). This is the card shown when the repo link is
   shared, and on Explore.
2. **Private vulnerability reporting.** Settings ▸ Code security (Security on some accounts) ▸
   Private vulnerability reporting ▸ Enable. `SECURITY.md`, `CODE_OF_CONDUCT.md` and the issue
   form's contact link point to it, so the link 404s until this is on.
3. **Issue labels.** The in-app reporter and the issue forms use the `bug` and `enhancement`
   labels; both exist by default. Keep them.
4. **Discussions** (optional). Settings ▸ General ▸ Features ▸ Discussions, if you want a place for
   questions and ideas outside Issues. Then add a contact link to
   `.github/ISSUE_TEMPLATE/config.yml` pointing to `https://github.com/Moaksh/auto-apply/discussions`.
5. **Check the checklist.** Insights ▸ Community Standards should show description, README, code
   of conduct, contributing, license, security policy, issue templates and pull request template
   as done once this branch is merged.

## Getting onto Explore

GitHub Explore and topic pages are curated and driven by activity; there's no form to submit. What
helps: a clear description and topics (above), a social preview image, a release with a download,
a README that shows the app working (the demo GIF), and stars. Sharing a release on Hacker News
(Show HN), Reddit (r/macapps, r/cscareerquestions) or X is what usually brings the first stars.
