import BudgetModels

/// SwiftUI also defines a `Transaction` type (for animations), which makes the
/// bare name ambiguous wherever both modules are imported. In the app module,
/// `Transaction` always means our financial model.
typealias Transaction = BudgetModels.Transaction

/// The app module is itself named `Budget`, so the bare type name would
/// otherwise resolve to the module and fail. This alias makes `Budget` mean
/// the monthly-budget model everywhere in the app.
typealias Budget = BudgetModels.Budget
