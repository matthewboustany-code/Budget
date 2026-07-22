import Vapor

/// Root route registration. Feature route groups are added under `/v1` in
/// their own files (auth, household, plaid, accounts, transactions, budgets,
/// bills, goals, reports) as each phase lands.
func routes(_ app: Application) throws {
    app.get { _ in "Budget API" }

    let v1 = app.grouped("v1")
    try registerHealthRoutes(v1)
    registerAuthRoutes(v1)
    registerHouseholdRoutes(v1)
    registerPlaidRoutes(v1)
    registerAccountRoutes(v1)
    registerCategoryRoutes(v1)
    registerTransactionRoutes(v1)
}
