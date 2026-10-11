"""Rendered career pages: posting-link picking and JSON-feed harvesting (pure functions, no browser)."""

from __future__ import annotations

from autoapply.discovery.careers import company_name_from_url, harvest_json_postings, pick_rendered_postings


def test_pick_uses_card_text_when_the_link_is_empty() -> None:
    rows = [
        {"href": "https://x.oraclecloud.com/hcm/sites/CX/job/123", "text": "", "card": "AI Engineer\nBengaluru\nBuild things"},
        {"href": "https://x.oraclecloud.com/hcm/sites/CX/join-talent-community", "text": "JOIN", "card": "JOIN"},
        {"href": "https://x.oraclecloud.com/hcm/sites/CX/job/123", "text": "", "card": "dup"},
    ]
    assert pick_rendered_postings(rows) == [("https://x.oraclecloud.com/hcm/sites/CX/job/123", "AI Engineer", "AI Engineer\nBengaluru\nBuild things")]


def test_harvest_obfuscated_json_feed() -> None:
    feed = {"total": 2, "jobs": [
        {"t": "Lead - BD", "c": "Goa", "u": "https://jobs.smartrecruiters.com/ACME/1-lead-bd?trid=z"},
        {"t": "Data Engineer", "c": "Pune", "u": "https://jobs.smartrecruiters.com/ACME/2-data-engineer"},
    ]}
    out = harvest_json_postings([{"unrelated": [1, 2]}, feed])
    assert [(u.split("/")[-1].split("?")[0], t) for u, t, _ in out] == [("1-lead-bd", "Lead - BD"), ("2-data-engineer", "Data Engineer")]
    assert "Goa" in out[0][2]


def test_harvest_ignores_lists_without_links() -> None:
    assert harvest_json_postings([{"jobs": [{"title": "A job"}, {"title": "Another"}]}]) == []


def test_tenant_name_from_multi_tenant_hosts() -> None:
    assert company_name_from_url("https://jpmc.fa.oraclecloud.com/hcmUI/x") == "Jpmc"
    assert company_name_from_url("https://careers.acme-robotics.com/jobs") == "Acme Robotics"
