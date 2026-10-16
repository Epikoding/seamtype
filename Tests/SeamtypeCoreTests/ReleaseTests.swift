import Foundation
import Testing
@testable import SeamtypeCore

/// The update check: GitHub's latest-release answer and version order.
@Suite struct ReleaseTests {
    @Test func readsTheInstallerFromGitHubsAnswer() throws {
        let json = #"""
        { "tag_name": "v0.1.6", "html_url": "https://github.com/aimdevlee/seamtype/releases/tag/v0.1.6",
          "assets": [
            { "name": "Seamtype-0.1.6.pkg", "browser_download_url": "https://example.com/Seamtype-0.1.6.pkg" },
            { "name": "Seamtype.pkg", "browser_download_url": "https://example.com/Seamtype.pkg" },
            { "name": "Seamtype.zip", "browser_download_url": "https://example.com/Seamtype.zip" } ] }
        """#
        let release = try #require(Release(gitHubJSON: Data(json.utf8)))
        #expect(release.version == "0.1.6")
        #expect(release.package.absoluteString == "https://example.com/Seamtype.pkg")
        #expect(release.page?.absoluteString == "https://github.com/aimdevlee/seamtype/releases/tag/v0.1.6")
        // No installer, or not a release at all: nothing to offer.
        #expect(Release(gitHubJSON: Data(#"{ "tag_name": "v0.2", "assets": [] }"#.utf8)) == nil)
        #expect(Release(gitHubJSON: Data(#"{ "message": "Not Found" }"#.utf8)) == nil)
    }

    @Test func readsWhatChangedFromTheNotes() throws {
        let body = """
        ## 바뀐 것

        - **입력 중 지우기**: 가나 한 글자씩(`かんこく` → `かんこ`).
        - **텍스트 대치**: 약어를
          두 줄에 걸쳐 씁니다.

        ## 설치·업데이트

        - 설치 파일을 받아 여세요.
        """
        #expect(Release.changes(in: body) == [
            "**입력 중 지우기**: 가나 한 글자씩(`かんこく` → `かんこ`).",
            "**텍스트 대치**: 약어를 두 줄에 걸쳐 씁니다.",
        ])
        #expect(Release.changes(in: "") == [])
        #expect(Release.changes(in: "## Changes\n\nOne paragraph.\n") == ["One paragraph."])

        let json = #"""
        { "tag_name": "v0.2.0", "body": "## 바뀐 것\r\n\r\n- 하나\r\n- 둘\r\n",
          "assets": [ { "name": "Seamtype.pkg", "browser_download_url": "https://example.com/Seamtype.pkg" } ] }
        """#
        #expect(try #require(Release(gitHubJSON: Data(json.utf8))).notes == ["하나", "둘"])
    }

    /// The draft's notes start from this template; published unfilled, About shows nothing.
    @Test func theNotesTemplateListsNothingYet() throws {
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/release-notes.md")
        let body = try String(contentsOf: template, encoding: .utf8)
        #expect(body.contains("## 바뀐 것"))
        #expect(Release.changes(in: body) == [])
        #expect(Release.changes(in: body.replacingOccurrences(of: "## 바뀐 것\n", with: "## 바뀐 것\n\n- **새 기능**: 설명\n"))
            == ["**새 기능**: 설명"])
    }

    @Test func splitsANoteIntoTitleAndDetail() {
        #expect(Release.headline(of: "**텍스트 대치**: 약어를 `ㅈㅅ`처럼") == ("텍스트 대치", "약어를 `ㅈㅅ`처럼"))
        #expect(Release.headline(of: "**짧은 것**") == ("짧은 것", nil))
        #expect(Release.headline(of: "그냥 문장입니다.") == ("그냥 문장입니다.", nil))
    }

    /// A tag that isn't a plain version is no release to offer: it names the downloaded file,
    /// which pkgutil prints above the certificate (v9.9 (2UZ65T3U82) would look like the team).
    @Test func takesOnlyPlainVersions() {
        func release(_ tag: String) -> Release? {
            let json = #"{ "tag_name": "\#(tag)", "assets": [ { "name": "Seamtype.pkg", "browser_download_url": "https://example.com/Seamtype.pkg" } ] }"#
            return Release(gitHubJSON: Data(json.utf8))
        }
        #expect(release("v0.1.12")?.version == "0.1.12")
        #expect(release("0.2")?.version == "0.2")
        #expect(release("v9.9 (2UZ65T3U82)") == nil)
        #expect(release("v0.2.0-beta.1") == nil)
        #expect(release("v0..1") == nil)
        #expect(release("v") == nil)
    }

    /// pkgutil's answer for 0.1.11, and the same with each part that must hold taken away.
    @Test func readsTheSignatureFromPkgutil() {
        let signed = """
        Package "Seamtype-0.1.11.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Signed with a trusted timestamp on: 2026-10-14 12:40:35 +0000
           Certificate Chain:
            1. Developer ID Installer: Dongbin Lee (2UZ65T3U82)
               Expires: 2027-02-01 22:12:15 +0000
               SHA256 Fingerprint:
                   C3 F0 18 AF 01 C2 F8 84 72 39 54 D2 2F 32 08 62 39 5D 52 38 1D 9A
                   0F A1 B5 20 54 57 DA C4 D8 E7
               ------------------------------------------------------------------------
            2. Developer ID Certification Authority
               Expires: 2027-02-01 22:12:15 +0000
               ------------------------------------------------------------------------
            3. Apple Root CA
               Expires: 2035-02-09 21:40:36 +0000
        """
        #expect(Release.isSigned(pkgutilOutput: signed, team: "2UZ65T3U82"))
        #expect(!Release.isSigned(pkgutilOutput: signed, team: "ABCDE12345"))
        // Another team's installer, with Seamtype's team only in the file name.
        let forged = signed
            .replacingOccurrences(of: "Seamtype-0.1.11.pkg", with: "Seamtype-9.9 (2UZ65T3U82).pkg")
            .replacingOccurrences(of: "Dongbin Lee (2UZ65T3U82)", with: "Someone Else (ABCDE12345)")
        #expect(!Release.isSigned(pkgutilOutput: forged, team: "2UZ65T3U82"))
        // Not notarized, or an application certificate rather than an installer one.
        #expect(!Release.isSigned(pkgutilOutput: signed.replacingOccurrences(of: "   Notarization: trusted by the Apple notary service\n", with: ""), team: "2UZ65T3U82"))
        #expect(!Release.isSigned(pkgutilOutput: signed.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application"), team: "2UZ65T3U82"))
        #expect(!Release.isSigned(pkgutilOutput: "Package \"Seamtype.pkg\":\n   Status: no signature\n", team: "2UZ65T3U82"))
    }

    @Test func comparesVersionsByNumber() {
        #expect(Release.isNewer("0.1.10", than: "0.1.9"))
        #expect(Release.isNewer("0.2", than: "0.1.9"))
        #expect(Release.isNewer("1.0.0", than: "0.9"))
        #expect(!Release.isNewer("0.1.5", than: "0.1.5"))
        #expect(!Release.isNewer("0.2", than: "0.2.0"))
        #expect(!Release.isNewer("0.1.4", than: "0.1.5"))
        #expect(!Release.isNewer("0.2.0-beta.1", than: "0.2.0"))
        #expect(!Release.isNewer("0.2.0-beta.1", than: "0.1.9"))
    }

    @Test func updateChecksAreOnUnlessTurnedOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seamtype-release-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "japanese": true }"#.utf8).write(to: url)
        #expect(Settings.load(from: url).checkForUpdates)
        try Settings(checkForUpdates: false).save(to: url)
        #expect(!Settings.load(from: url).checkForUpdates)
    }
}
