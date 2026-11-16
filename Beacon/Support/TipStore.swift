import Observation
import StoreKit

enum TipProductCatalog {
    static let identifiers = [
        "com.cybersand.beacon73.tip.small",
        "com.cybersand.beacon73.tip.medium",
        "com.cybersand.beacon73.tip.large"
    ]

    static func order(of product: Product) -> Int {
        identifiers.firstIndex(of: product.id) ?? identifiers.count
    }
}

@MainActor
@Observable
final class TipStore {
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var purchaseInProgressProductID: String?
    private(set) var didAttemptLoad = false
    private(set) var notice: String?

    func loadProducts() async {
        guard !isLoading else { return }

        isLoading = true
        notice = nil
        defer {
            isLoading = false
            didAttemptLoad = true
        }

        do {
            products = try await Product.products(for: TipProductCatalog.identifiers)
                .filter { $0.type == .consumable }
                .sorted { TipProductCatalog.order(of: $0) < TipProductCatalog.order(of: $1) }
        } catch is CancellationError {
            return
        } catch {
            products = []
            notice = String(localized: "Tip options couldn’t be loaded. Please try again.")
        }
    }

    func retryLoadingProducts() async {
        didAttemptLoad = false
        await loadProducts()
    }

    func purchase(_ product: Product) async {
        guard purchaseInProgressProductID == nil else { return }

        purchaseInProgressProductID = product.id
        notice = nil
        defer { purchaseInProgressProductID = nil }

        do {
            switch try await product.purchase() {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    notice = String(localized: "The App Store couldn’t verify this tip. No contribution was recorded.")
                    return
                }

                await transaction.finish()
                notice = String(localized: "Thank you for supporting Beacon 73—73 from K6BAT.")
            case .pending:
                notice = String(localized: "This tip is pending App Store approval.")
            case .userCancelled:
                break
            @unknown default:
                notice = String(localized: "The tip couldn’t be completed. Please try again.")
            }
        } catch is CancellationError {
            return
        } catch {
            notice = String(localized: "The tip couldn’t be completed. Please try again.")
        }
    }

    func observeTransactions() async {
        for await verification in Transaction.unfinished {
            await finishIfVerified(verification)
        }

        for await verification in Transaction.updates {
            await finishIfVerified(verification)
        }
    }

    private func finishIfVerified(_ verification: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = verification else { return }
        await transaction.finish()
    }
}
