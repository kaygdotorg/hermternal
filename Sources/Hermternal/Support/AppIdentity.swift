/// Stable application identity shared by persistence and logging.
///
/// Keep this independent from `Bundle` so tests use the same identity as the
/// built app rather than inheriting the test runner's bundle identifier.
enum AppIdentity {
    static let bundleID = "kaygdotorg.hermternal"
}
