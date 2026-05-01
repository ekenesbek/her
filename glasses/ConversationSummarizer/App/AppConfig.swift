import Foundation

enum AppConfig {
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
}

