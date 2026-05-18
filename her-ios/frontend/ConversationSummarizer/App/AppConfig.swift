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

    static var backendSummaryEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/summaries")
    }

    static var transcriptionEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/transcriptions")
    }

    static var meetingJobsEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/meetings/jobs")
    }

    static var meetingsEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/meetings")
    }

    static var subscriptionEndpoint: URL? {
        backendBaseURL?.appendingPathComponent("v1/subscription")
    }

    static var plusSubscriptionProductID: String {
        guard
            let rawValue = Bundle.main.object(forInfoDictionaryKey: "PlusSubscriptionProductID") as? String,
            !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !rawValue.contains("$(")
        else {
            return "com.ekenesbek.her.plus.monthly"
        }

        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var plusSubscriptionPriceList: [String: String] {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "PlusSubscriptionPriceList") as? [String: String] else {
            return [:]
        }

        return rawValue.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, !value.contains("$(") else {
                return
            }
            result[key] = value
        }
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
