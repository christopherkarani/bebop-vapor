import Fluent

struct CreateProcessedTransactionRecord: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        return database.schema("processed_transactions")
            .id()
            .field("stellar_account", .string, .required)
            .field("transaction_id", .string, .required)
            .field("processed_at", .datetime, .required)
            .unique(on: "stellar_account", "transaction_id")
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        return database.schema("processed_transactions").delete()
    }
} 
