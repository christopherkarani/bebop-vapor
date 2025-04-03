import Fluent

struct CreateCursorRecord: Migration {
    func prepare(on database: any Database) -> EventLoopFuture<Void> {
        return database.schema("stellar_cursors")
            .id()
            .field("stellar_account", .string, .required)
            .field("cursor", .string, .required)
            .field("updated_at", .datetime)
            .unique(on: "stellar_account")
            .create()
    }

    func revert(on database: any Database) -> EventLoopFuture<Void> {
        return database.schema("stellar_cursors").delete()
    }
} 
