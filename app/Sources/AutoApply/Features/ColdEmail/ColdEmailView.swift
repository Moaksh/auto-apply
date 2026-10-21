// ColdEmailView.swift — Cold Email: a preview of a planned feature (reach the hiring manager with a
// short note next to the application). Not built yet: nothing is sent, and there is no waitlist.
import SwiftUI

@objc(ColdEmailFeature)
final class ColdEmailFeature: NSObject, FeatureRegistrant {
    static func register(in registry: ScreenRegistry) {
        registry.register(.coldEmail) { ColdEmailView() }
    }
}

struct ColdEmailView: View {
    @Environment(AppStore.self) private var store

    /// A real job from the pipeline to make the preview concrete (submitted first, else best queued).
    private var sample: JobItem? {
        let order: [AppState] = [.submitted, .awaitingReview, .queued]
        return order.lazy.compactMap { state in store.jobs.all.first { $0.state == state } }.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                header
                HStack(alignment: .top, spacing: Space.xl) {
                    steps.frame(maxWidth: 360, alignment: .topLeading)
                    preview.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(Space.contentPadding)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .background(Palette.windowBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text("Cold Email").font(Typography.title1)
                Badge("Not built yet")
            }
            Text("A planned feature: for roles you apply to, find the hiring manager or a teammate and draft a short note from your resume, for you to send from your own Gmail. Nothing here works yet, and nothing is sent.")
                .font(Typography.body).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("How it's planned to work").eyebrowStyle()
            step(1, "person.crop.circle.badge.magnifyingglass", "Find the right person",
                 "Hiring manager or a team member for the role, from the posting and public profiles.")
            step(2, "text.quote", "Draft a 90-word note",
                 "Drawn from your profile and stories, tied to what the team builds.")
            step(3, "hand.raised", "You approve every email",
                 "Nothing is sent without your click. One email per company, never a sequence of follow-ups.")
            step(4, "paperplane", "Sent from your Gmail",
                 "Uses the inbox you connected for security codes. Replies land in your inbox, not ours.")
        }
    }

    private func step(_ n: Int, _ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol).foregroundStyle(Palette.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(n). \(title)").font(Typography.bodyEmph)
                Text(detail).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var preview: some View {
        let company = sample?.company ?? "Observe.AI"
        let role = sample?.title ?? "AI Agent Engineer"
        let me = store.library.profile.fullName ?? "Your Name"
        let firstName = me.split(separator: " ").first.map(String.init) ?? me
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Preview").eyebrowStyle()
                Spacer()
                Text("sample · not sent").font(Typography.monoSmall).foregroundStyle(Palette.textTertiary)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                field("To", "Hiring manager · \(company)")
                field("Subject", "\(role) — applied today, quick note")
                Divider()
                Text("""
                Hi there,

                I just applied for the \(role) role at \(company). I build production agent systems: at my current team I rebuilt a claims engine into an agentic architecture with guardrails and an evaluation suite, which took end-to-end accuracy from 30% to 70%.

                If the role is still open, I'd love 15 minutes to hear what the team is shipping next.

                Thanks,
                \(firstName)
                """)
                .font(Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
            Text("Sending isn't available. This sample only shows what a note could look like.")
                .font(Typography.callout).foregroundStyle(Palette.textTertiary)
        }
    }

    private func field(_ k: String, _ v: String) -> some View {
        HStack(spacing: Space.s) {
            Text(k).font(Typography.monoSmall).foregroundStyle(Palette.textTertiary).frame(width: 56, alignment: .leading)
            Text(v).font(Typography.body)
        }
    }
}
