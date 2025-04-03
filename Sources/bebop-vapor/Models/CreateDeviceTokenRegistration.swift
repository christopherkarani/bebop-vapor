import Fluent
import Vapor

// Fluent models with the Content protocol inherit Sendable conformance.
// We use @unchecked Sendable because these models are not generally accessed concurrently
// and are primarily used in database operations which are already synchronized.
final class DeviceTokenRegistration: Model, Content, @unchecked Sendable {
    static let schema = "device_token_registrations"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "device_token")
    var deviceToken: String
    
    @Field(key: "stellar_account")
    var stellarAccount: String
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(id: UUID? = nil, deviceToken: String, stellarAccount: String) {
        self.id = id
        self.deviceToken = deviceToken
        self.stellarAccount = stellarAccount
    }
}

struct CreateDeviceTokenRegistration: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DeviceTokenRegistration.schema)
            .id()
            .field("device_token", .string, .required)
            .field("stellar_account", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "device_token", "stellar_account")
            .create()
    }
    
    func revert(on database: any Database) async throws {
        try await database.schema(DeviceTokenRegistration.schema).delete()
    }
} 
