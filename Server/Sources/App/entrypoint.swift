import Vapor
import Logging
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        do {
            try await configure(app)
        } catch let error as AppConfig.ConfigError {
            // A bad .env is an operator error, not a crash. Rethrowing traps at
            // top level, and the backtrace handler then spends ~13s dumping a
            // stack that says nothing useful — once per restart, forever, since
            // compose restarts us. One legible line and EX_CONFIG instead.
            app.logger.critical("Configuration error: \(error.description)")
            try? await app.asyncShutdown()
            exit(78)  // EX_CONFIG
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.execute()
        try await app.asyncShutdown()
    }
}
