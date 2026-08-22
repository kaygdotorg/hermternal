import Foundation
import HermternalCore
import Testing

@Test("credential paths use the application-support directory")
func credentialPathComposition() {
    let applicationSupport = URL(fileURLWithPath: "/fixture/application-support", isDirectory: true)

    #expect(
        CredentialStore.credentialsDirectory(applicationSupportDirectory: applicationSupport).path
            == "/fixture/application-support/Hermternal/credentials"
    )
}

@Test("history paths use the caches directory")
func historyPathComposition() {
    let caches = URL(fileURLWithPath: "/fixture/caches", isDirectory: true)

    #expect(
        HistoryCache.historyDirectory(cachesDirectory: caches).path
            == "/fixture/caches/\(AppIdentity.bundleID)/history"
    )
}

@Test("logs use app-owned application support rather than a platform-specific logs root")
func logPathComposition() {
    let applicationSupport = URL(fileURLWithPath: "/fixture/application-support", isDirectory: true)

    let directory = Log.logsDirectory(applicationSupportDirectory: applicationSupport)
    #expect(directory.path == "/fixture/application-support/Hermternal/logs")
    #expect(Log.fileURL(in: directory).path == "/fixture/application-support/Hermternal/logs/hermternal.log")
}
