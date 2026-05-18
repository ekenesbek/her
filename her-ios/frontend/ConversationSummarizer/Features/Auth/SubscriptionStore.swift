import Foundation
import StoreKit

enum SubscriptionPlan: String, Codable, Equatable {
    case free
    case plus
    case paid

    var title: String {
        switch self {
        case .free:
            return "free"
        case .plus, .paid:
            return "plus"
        }
    }

    var enablesAskAI: Bool {
        self == .plus || self == .paid
    }
}

enum SubscriptionSource: String, Codable, Equatable {
    case free
    case apple
    case manual
}

struct SubscriptionState: Codable, Equatable {
    let plan: SubscriptionPlan
    let recordingLimitSeconds: Int
    let recordingUsedSeconds: Int
    let recordingRemainingSeconds: Int
    let askAiEnabled: Bool
    let periodStartedAt: Date
    let periodEndsAt: Date
    let source: SubscriptionSource

    static var freeFallback: SubscriptionState {
        let period = currentPeriod()
        return SubscriptionState(
            plan: .free,
            recordingLimitSeconds: 60 * 60,
            recordingUsedSeconds: 0,
            recordingRemainingSeconds: 60 * 60,
            askAiEnabled: false,
            periodStartedAt: period.start,
            periodEndsAt: period.end,
            source: .free
        )
    }

    var limitMinutes: Int {
        max(0, recordingLimitSeconds / 60)
    }

    var usedMinutes: Int {
        max(0, Int(ceil(Double(recordingUsedSeconds) / 60.0)))
    }

    var remainingMinutes: Int {
        max(0, Int(floor(Double(recordingRemainingSeconds) / 60.0)))
    }

    var usageRatio: Double {
        guard recordingLimitSeconds > 0 else {
            return 0
        }
        return min(1, max(0, Double(recordingUsedSeconds) / Double(recordingLimitSeconds)))
    }

    var canStartRecording: Bool {
        recordingRemainingSeconds > 0
    }

    var recordingLimitText: String {
        "\(limitMinutes) min/mo"
    }

    var recordingUsageText: String {
        "\(usedMinutes)/\(limitMinutes) min"
    }

    var recordingRemainingText: String {
        "\(remainingMinutes) min left"
    }

    func applyingLocalUsage(from meetings: [StoredMeeting]) -> SubscriptionState {
        let localUsedSeconds = meetings.reduce(0) { total, meeting in
            guard meeting.createdAt >= periodStartedAt,
                  meeting.createdAt < periodEndsAt,
                  let duration = meeting.durationSeconds,
                  duration.isFinite,
                  duration > 0 else {
                return total
            }
            return total + Int(duration.rounded())
        }
        let used = max(recordingUsedSeconds, localUsedSeconds)
        return SubscriptionState(
            plan: plan,
            recordingLimitSeconds: recordingLimitSeconds,
            recordingUsedSeconds: used,
            recordingRemainingSeconds: max(0, recordingLimitSeconds - used),
            askAiEnabled: askAiEnabled || plan.enablesAskAI,
            periodStartedAt: periodStartedAt,
            periodEndsAt: periodEndsAt,
            source: source
        )
    }

    static func currentPeriod(now: Date = Date()) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: components) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return (start, end)
    }
}

protocol SubscriptionService {
    func load() async throws -> SubscriptionState
    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionState
}

enum SubscriptionServiceFactory {
    static func make() -> SubscriptionService? {
        guard let endpoint = AppConfig.subscriptionEndpoint else {
            return nil
        }
        return BackendSubscriptionService(endpoint: endpoint)
    }
}

struct BackendSubscriptionService: SubscriptionService {
    let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func load() async throws -> SubscriptionState {
        var request = authorizedRequest(url: endpoint)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.decoder().decode(SubscriptionState.self, from: data)
    }

    func submitAppleTransaction(signedTransaction: String) async throws -> SubscriptionState {
        var request = authorizedRequest(url: endpoint.appendingPathComponent("apple-transaction"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AppleTransactionPayload(signedTransaction: signedTransaction))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try Self.decoder().decode(SubscriptionState.self, from: data)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = TokenSource.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionError.backendFailed(
                statusCode: httpResponse.statusCode,
                detail: errorDetail(from: data)
            )
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = isoFormatterWithFractionalSeconds.date(from: rawValue) {
                return date
            }
            if let date = isoFormatter.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
        }
        return decoder
    }

    private static func errorDetail(from data: Data) -> String? {
        struct DetailEnvelope: Decodable { let detail: String? }
        if let envelope = try? JSONDecoder().decode(DetailEnvelope.self, from: data),
           let detail = envelope.detail,
           !detail.isEmpty {
            return detail
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var state: SubscriptionState = .freeFallback
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var plusProductPrice: String?
    @Published private(set) var plusFallbackPrice: String?

    private let service: SubscriptionService?
    private let productID: String
    private var plusProduct: Product?

    init(
        service: SubscriptionService? = SubscriptionServiceFactory.make(),
        productID: String = AppConfig.plusSubscriptionProductID
    ) {
        self.service = service
        self.productID = productID
        plusFallbackPrice = PlusSubscriptionPriceList.displayPrice(
            for: PlusSubscriptionPriceList.localeCountryCode()
        )
    }

    var canStartRecording: Bool {
        state.canStartRecording
    }

    var plusDisplayPrice: String? {
        plusProductPrice ?? plusFallbackPrice
    }

    var purchaseButtonTitle: String {
        if isPurchasing {
            return "opening app store..."
        }
        if let plusDisplayPrice {
            return "buy plus \(plusDisplayPrice)"
        }
        return "buy plus"
    }

    var limitReachedMessage: String {
        "Recording limit reached. \(state.plan.title) includes \(state.limitMinutes) minutes per month."
    }

    func refresh(meetings: [StoredMeeting] = []) async {
        await loadFallbackPrice()
        await loadPlusProduct()
        guard let service else {
            state = SubscriptionState.freeFallback.applyingLocalUsage(from: meetings)
            errorMessage = "Subscription backend is not configured."
            return
        }
        guard !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            state = try await service.load().applyingLocalUsage(from: meetings)
            errorMessage = nil
        } catch {
            state = state.applyingLocalUsage(from: meetings)
            errorMessage = error.localizedDescription
        }
    }

    func purchasePlus(meetings: [StoredMeeting] = []) async {
        guard let service else {
            errorMessage = "Subscription backend is not configured."
            return
        }
        guard !isPurchasing else {
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let product = try await plusProductOrLoad()
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                let verified = try verifiedTransaction(from: verification)
                state = try await service.submitAppleTransaction(
                    signedTransaction: verified.signedTransaction
                ).applyingLocalUsage(from: meetings)
                await verified.transaction.finish()
                errorMessage = nil
            case .userCancelled:
                errorMessage = nil
            case .pending:
                throw SubscriptionError.purchasePending
            @unknown default:
                throw SubscriptionError.purchasePending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases(meetings: [StoredMeeting] = []) async {
        guard let service else {
            errorMessage = "Subscription backend is not configured."
            return
        }
        guard !isPurchasing else {
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            var restored = false
            for await result in Transaction.currentEntitlements {
                let verified = try verifiedTransaction(from: result)
                guard verified.transaction.productID == productID else {
                    continue
                }
                state = try await service.submitAppleTransaction(
                    signedTransaction: verified.signedTransaction
                ).applyingLocalUsage(from: meetings)
                restored = true
            }
            if !restored {
                throw SubscriptionError.noRestorablePurchase
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadFallbackPrice() async {
        let countryCode = await Storefront.current?.countryCode ?? PlusSubscriptionPriceList.localeCountryCode()
        plusFallbackPrice = PlusSubscriptionPriceList.displayPrice(for: countryCode)
    }

    private func loadPlusProduct() async {
        guard plusProduct == nil else {
            return
        }
        do {
            plusProduct = try await plusProductOrLoad()
            plusProductPrice = plusProduct?.displayPrice
        } catch {
            plusProductPrice = nil
        }
    }

    private func plusProductOrLoad() async throws -> Product {
        if let plusProduct {
            return plusProduct
        }
        let products = try await Product.products(for: [productID])
        guard let product = products.first(where: { $0.id == productID }) else {
            throw SubscriptionError.productUnavailable(productID)
        }
        plusProduct = product
        plusProductPrice = product.displayPrice
        return product
    }

    private func verifiedTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> (transaction: Transaction, signedTransaction: String) {
        switch result {
        case let .verified(transaction):
            return (transaction, result.jwsRepresentation)
        case let .unverified(_, error):
            throw SubscriptionError.transactionUnverified(error.localizedDescription)
        }
    }
}

private struct AppleTransactionPayload: Encodable {
    let signedTransaction: String
}

private enum PlusSubscriptionPriceList {
    static func displayPrice(for countryCode: String?) -> String? {
        let priceList = AppConfig.plusSubscriptionPriceList
        guard !priceList.isEmpty else {
            return nil
        }

        for candidate in countryCandidates(from: countryCode) {
            if let price = priceList[candidate] {
                return price
            }
        }

        if countryCandidates(from: countryCode).contains(where: euroCountryCodes.contains),
           let price = priceList["EU"] {
            return price
        }

        return priceList["DEFAULT"]
    }

    static func localeCountryCode(locale: Locale = .current) -> String? {
        locale.regionCode
    }

    private static func countryCandidates(from countryCode: String?) -> [String] {
        guard let countryCode else {
            return []
        }
        let rawValue = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !rawValue.isEmpty else {
            return []
        }
        var candidates = [rawValue]
        if let normalizedRegion = Locale(identifier: "en_\(rawValue)").regionCode?.uppercased(),
           !normalizedRegion.isEmpty,
           normalizedRegion != rawValue {
            candidates.append(normalizedRegion)
        }
        if let iso2 = iso3ToISO2[rawValue] {
            candidates.append(iso2)
        }
        return candidates
    }

    private static let euroCountryCodes: Set<String> = [
        "AT", "BE", "CY", "DE", "EE", "ES", "FI", "FR", "GR", "HR", "IE", "IT",
        "LT", "LU", "LV", "MT", "NL", "PT", "SI", "SK"
    ]

    private static let iso3ToISO2: [String: String] = [
        "ARE": "AE",
        "AUS": "AU",
        "AUT": "AT",
        "BEL": "BE",
        "BRA": "BR",
        "CAN": "CA",
        "CHE": "CH",
        "CYP": "CY",
        "DEU": "DE",
        "ESP": "ES",
        "EST": "EE",
        "FIN": "FI",
        "FRA": "FR",
        "GBR": "GB",
        "GRC": "GR",
        "HRV": "HR",
        "IND": "IN",
        "IRL": "IE",
        "ITA": "IT",
        "JPN": "JP",
        "KAZ": "KZ",
        "KOR": "KR",
        "LTU": "LT",
        "LUX": "LU",
        "LVA": "LV",
        "MEX": "MX",
        "MLT": "MT",
        "NLD": "NL",
        "PRT": "PT",
        "SVK": "SK",
        "SVN": "SI",
        "TUR": "TR",
        "USA": "US"
    ]
}

enum SubscriptionError: LocalizedError {
    case backendFailed(statusCode: Int, detail: String?)
    case invalidResponse
    case productUnavailable(String)
    case purchasePending
    case noRestorablePurchase
    case transactionUnverified(String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(statusCode, detail):
            if let detail, !detail.isEmpty {
                return "Subscription backend failed (\(statusCode)): \(detail)"
            }
            return "Subscription backend failed (\(statusCode))."
        case .invalidResponse:
            return "Subscription backend returned an invalid response."
        case let .productUnavailable(productID):
            return "Plus is not available from App Store yet. StoreKit returned no product for \(productID). Attach it to the first app version or wait for sandbox propagation."
        case .purchasePending:
            return "Purchase is pending App Store approval."
        case .noRestorablePurchase:
            return "No active plus purchase was found to restore."
        case let .transactionUnverified(reason):
            return "App Store transaction could not be verified: \(reason)"
        }
    }
}
