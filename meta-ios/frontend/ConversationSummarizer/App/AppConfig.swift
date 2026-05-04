import Foundation

enum AppConfig {
    static var hasMetaDATCredentials: Bool {
        guard
            let dat = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any],
            let metaAppID = dat["MetaAppID"] as? String,
            let clientToken = dat["ClientToken"] as? String,
            let teamID = dat["TeamID"] as? String,
            let appLinkURLScheme = dat["AppLinkURLScheme"] as? String
        else {
            return false
        }

        return [metaAppID, clientToken, teamID, appLinkURLScheme].allSatisfy { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.contains("$(")
        }
    }

    static var summaryEndpoint: URL? {
        guard
            let rawValue = Bundle.main.object(forInfoDictionaryKey: "SummaryAPIURL") as? String,
            !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !rawValue.contains("$(")
        else {
            return nil
        }

        return URL(string: rawValue)
    }

    static var backendSummaryEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/summaries")
    }

    static var transcriptionEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/transcriptions")
    }

    static var meetingsEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/meetings")
    }

    static var backendBaseURL: URL? {
        guard
            let rawValue = Bundle.main.object(forInfoDictionaryKey: "BackendAPIURL") as? String,
            !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !rawValue.contains("$(")
        else {
            return nil
        }

        return URL(string: rawValue)
    }

}
