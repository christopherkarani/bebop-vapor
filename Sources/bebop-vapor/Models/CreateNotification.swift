import Fluent
import Vapor

// MARK: - Notification Model
// Fluent models with the Content protocol inherit Sendable conformance.
// We use @unchecked Sendable because these models are not generally accessed concurrently
// and are primarily used in database operations which are already synchronized.
final class Notification: Model, Content, @unchecked Sendable {
    static let schema = "notifications"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "title")
    var title: String

    @Field(key: "body")
    var body: String

    @Field(key: "user_id")
    var userId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "read_at", on: .update)
    var readAt: Date?

    init() { }

    init(id: UUID? = nil, title: String, body: String, userId: UUID) {
        self.id = id
        self.title = title
        self.body = body
        self.userId = userId
    }
}

// MARK: - Migration
struct CreateNotification: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Notification.schema)
            .id()
            .field("title", .string, .required)
            .field("body", .string, .required)
            .field("user_id", .uuid, .required)
            .field("created_at", .datetime)
            .field("read_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Notification.schema).delete()
    }
} 
