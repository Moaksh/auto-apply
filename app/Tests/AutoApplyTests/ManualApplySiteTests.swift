// ManualApplySiteTests.swift — sites that kept stopping the agent: the same site key as the engine
// (`manual_sites.site_of`) and the reason shown on their Easy Apply rows.
import Testing
@testable import AutoApply

@Suite("Manual apply sites")
struct ManualApplySiteTests {
    @Test func siteKeyMatchesTheEngine() {
        #expect(ManualApplySite.site(of: "https://www.Acme.com/careers/1") == "acme.com")
        #expect(ManualApplySite.site(of: "https://acme.wd5.myworkdayjobs.com/x/job/1") == "acme.wd5.myworkdayjobs.com")
        #expect(ManualApplySite.site(of: "https://boards.greenhouse.io/Stripe/jobs/1") == "boards.greenhouse.io/stripe")
        #expect(ManualApplySite.site(of: "not a url") == nil)
    }

    @Test func decodesTheMetaAndSaysWhy() {
        let sites = ManualApplySite.decode(#"{"acme.wd5.myworkdayjobs.com": {"action": "account", "since": "2026-11-22T00:00:00Z"}}"#)
        let acme = sites["acme.wd5.myworkdayjobs.com"]
        #expect(acme?.action == "account")
        #expect(acme?.reason.contains("sign in") == true)
        #expect(ManualApplySite.decode(nil).isEmpty && ManualApplySite.decode("[]").isEmpty)
    }

    @Test func linkedInRowsAreToldApart() {
        let li = EasyApplyItem(id: 1, jobID: 1, url: "https://www.linkedin.com/jobs/view/1/", createdAt: .now)
        let site = EasyApplyItem(id: 2, jobID: 2, url: "https://acme.wd5.myworkdayjobs.com/x/job/1", createdAt: .now)
        #expect(li.isLinkedIn && !site.isLinkedIn)
    }
}
