"""Contact sources for the scout (plan §B.3), each small and testable with fixtures:

* :mod:`posting`: contact lines in the job description we already stored;
* :mod:`site_pages`: the company's own pages (team / about / leadership / security.txt / JSON-LD);
* :mod:`github_org`: the company's GitHub org (public members, commit author emails);
* :mod:`google_people`: Google result pages read in the agent Chrome (LinkedIn result
  *titles* only; a LinkedIn URL is stored as a reference and never opened).

Shared helpers live in :mod:`extract`. The model never invents a person: every name it
returns must appear word for word in the page text, or it is dropped.
"""
