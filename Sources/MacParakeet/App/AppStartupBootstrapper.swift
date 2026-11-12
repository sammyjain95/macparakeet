import Foundation
import MacParakeetCore

@MainActor
final class AppStartupBootstrapper {
    func bootstrapEnvironment() async throws -> AppEnvironment {
        let bootstrapTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try AppPaths.ensureDirectories()
            try Task.checkCancellation()

            let manager = try DatabaseManager(path: AppPaths.databasePath)
            try Task.checkCancellation()

            return manager
        }

        let databaseManager = try await withTaskCancellationHandler {
            try await bootstrapTask.value
        } onCancel: {
            bootstrapTask.cancel()
        }

        try Task.checkCancellation()
        return try AppEnvironment(databaseManager: databaseManager)
    }
}
