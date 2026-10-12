import Foundation
import Testing
@testable import WorklensCore

/// #324: how a rule's value is stored and what it matches.
@Suite("Project rules")
struct ProjectRulesTests {
    @Test("a domain is lowercased with any address, scheme, www. and path dropped")
    func domainNormalization() {
        #expect(ProjectRuleKind.domain.normalized("Bob@WWW.Acme.com") == "acme.com")
        #expect(ProjectRuleKind.domain.normalized("https://www.acme.com/deck?x=1") == "acme.com")
        #expect(ProjectRuleKind.domain.normalized(" acme.com. ") == "acme.com")
        #expect(ProjectRuleKind.domain.normalized("localhost") == nil)
        #expect(ProjectRuleKind.domain.normalized("acme corp.com") == nil)
    }

    @Test("a repo is owner/repo from any GitHub spelling")
    func repoNormalization() {
        #expect(ProjectRuleKind.repo.normalized("Acme/Widgets") == "acme/widgets")
        #expect(ProjectRuleKind.repo.normalized("https://github.com/Acme/Widgets.git") == "acme/widgets")
        #expect(ProjectRuleKind.repo.normalized("github.com/acme/widgets/") == "acme/widgets")
        #expect(ProjectRuleKind.repo.normalized("widgets") == nil)
        #expect(ProjectRuleKind.repo.normalized("acme/widgets/pulls") == nil)
    }

    @Test("a URL prefix never keeps a query, a fragment, a scheme or a trailing slash")
    func urlPrefixNormalization() {
        #expect(ProjectRuleKind.urlPrefix.normalized("https://www.Notion.so/Acme/?token=secret#top") == "notion.so/acme")
        #expect(ProjectRuleKind.urlPrefix.normalized("docs.google.com/document/d/abc") == "docs.google.com/document/d/abc")
        #expect(ProjectRuleKind.urlPrefix.normalized("not a url") == nil)
        #expect(ProjectRuleKind.urlPrefix.normalized("/relative/path") == nil)
    }

    @Test("a.example.com matches example.com; notexample.com does not")
    func domainBoundary() {
        let matcher = ProjectRuleMatcher(catalog: [ProjectEntry(key: "acme", name: "Acme", domains: ["example.com"])])
        #expect(matcher.project(forHosts: ["a.example.com"])?.key == "acme")
        #expect(matcher.project(forHosts: ["example.com"])?.key == "acme")
        #expect(matcher.project(forHosts: ["notexample.com"]) == nil)
        #expect(matcher.project(forHosts: ["example.com.evil.org"]) == nil)
        #expect(ProjectRuleMatcher.host("a.example.com", isUnder: "example.com"))
        #expect(!ProjectRuleMatcher.host("notexample.com", isUnder: "example.com"))
    }

    @Test("the most specific domain and the longest URL prefix win")
    func mostSpecificWins() {
        let matcher = ProjectRuleMatcher(catalog: [
            ProjectEntry(
                key: "acme", name: "Acme", domains: ["example.com"],
                rules: ProjectRules(urlPrefixes: ["notion.so/acme"])
            ),
            ProjectEntry(
                key: "labs", name: "Labs", domains: ["labs.example.com"],
                rules: ProjectRules(urlPrefixes: ["notion.so/acme/labs"])
            ),
        ])
        #expect(matcher.project(forHosts: ["x.labs.example.com"])?.key == "labs")
        #expect(matcher.project(forHosts: ["www.example.com"])?.key == "acme")
        #expect(matcher.project(forURLs: ["https://notion.so/acme/labs/plan?x=1"])?.key == "labs")
        #expect(matcher.project(forURLs: ["https://www.notion.so/acme/plan"])?.key == "acme")
        #expect(matcher.project(forURLs: ["https://notion.so/acm", nil]) == nil)
        #expect(matcher.projects(forDomains: ["example.com", "labs.example.com", "example.com"]).map(\.key)
            == ["acme", "labs"])
    }

    @Test("a URL prefix stops at a host or path-segment boundary")
    func urlPrefixBoundary() {
        let matcher = ProjectRuleMatcher(catalog: [
            ProjectEntry(key: "acme", name: "Acme", rules: ProjectRules(urlPrefixes: ["acme.com"])),
            ProjectEntry(key: "gh", name: "GH", rules: ProjectRules(urlPrefixes: ["github.com/acme"])),
        ])
        #expect(matcher.project(forURLs: ["https://acme.com"])?.key == "acme")
        #expect(matcher.project(forURLs: ["https://acme.com/deck"])?.key == "acme")
        #expect(matcher.project(forURLs: ["https://acme.com:8443/deck"])?.key == "acme")
        #expect(matcher.project(forURLs: ["https://acme.com.br/deck"]) == nil)
        #expect(matcher.project(forURLs: ["https://github.com/acme/widgets"])?.key == "gh")
        #expect(matcher.project(forURLs: ["https://github.com/acme?tab=repos"])?.key == "gh")
        #expect(matcher.project(forURLs: ["https://github.com/acmecorp/widgets"]) == nil)
        #expect(matcher.project(forURLs: ["https://notion.so/acme-plan"]) == nil)
    }

    @Test("a repo rule matches any spelling of the repo")
    func repoMatch() {
        let matcher = ProjectRuleMatcher(catalog: [
            ProjectEntry(key: "acme", name: "Acme", rules: ProjectRules(repos: ["acme/widgets"])),
        ])
        #expect(matcher.project(forRepo: "Acme/Widgets")?.key == "acme")
        #expect(matcher.project(forRepo: "https://github.com/acme/widgets.git")?.key == "acme")
        #expect(matcher.project(forRepo: "acme/other") == nil)
        #expect(matcher.project(forRepo: nil) == nil)
    }

    @Test("the house entry's domains are yours and never name a project")
    func houseDomainsNeverMatch() {
        let matcher = ProjectRuleMatcher(catalog: [
            ProjectEntry(key: "halyard", name: "Halyard", kind: .house, domains: ["halyard.example"]),
        ])
        #expect(matcher.project(forHosts: ["halyard.example"]) == nil)
        #expect(matcher.isEmpty)
    }
}
