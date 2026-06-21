import Foundation

/// Minimal configuration seam for reaching the Talkeo backend.
///
/// Today this only carries the base URL (self-hosted users point it at their own
/// instance; the default targets a local dev server). It deliberately does *not*
/// model a settings system or the BYO ↔ Talkeo Cloud provider switch — those are
/// separate scope. The `schemaVersion` is the migration anchor (repo rule:
/// settings carry a schema version from day 1), mirroring `AppExclusionList`.
struct TalkeoConfig {
    /// Bump when the shape of persisted config changes, to drive migrations.
    static let schemaVersion = 1

    /// Root of the Talkeo API (e.g. `http://localhost:8000`). Endpoints are
    /// appended as `/api/v1/...` by the clients.
    var baseURL: URL

    /// Default config. The base URL is overridable via the `TALKEO_API_BASE_URL`
    /// environment variable so dev/CI can retarget without code changes; it falls
    /// back to the local dev server.
    static let `default` = TalkeoConfig(
        baseURL: URL(
            string: ProcessInfo.processInfo.environment["TALKEO_API_BASE_URL"]
                ?? "http://localhost:8000"
        )!
    )
}
