import BudgetModels

/// SwiftUI also defines a `Transaction` type (for animations), which makes the
/// bare name ambiguous wherever both modules are imported. In the app module,
/// `Transaction` always means our financial model.
typealias Transaction = BudgetModels.Transaction
