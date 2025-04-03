import Foundation
import Vapor
import APNS
import APNSCore
import NIO

enum APNSError: Error {
    case certificateNotFound(String)
    case invalidConfiguration(String)
    case clientNotInitialized
    case invalidTransactionData
    case notImplemented
}

// Custom payload structure for notifications
struct CustomPayload: Codable, Sendable {
    let custom: [String: String]
}

// Simplified APNSService implementation
final class APNSService: @unchecked Sendable {
    private var app: Application?
    private let certificatePath: String?
    private var apnsClient: APNSClient<JSONDecoder, JSONEncoder>?
    
    init(certificatePath: String? = nil) {
        self.certificatePath = certificatePath
        
        print("APNSService initialized")
    }
    
    func configure(app: Application) async throws {
        self.app = app
        print("APNS Service initializing")
        
        // Try to locate the key file
        var keyPath: String?
        
        // Check if environment variable is set
        if let envPath = Environment.get("APNS_KEY_PATH") {
            print("Using APNS key path from environment: \(envPath)")
            keyPath = envPath
        } 
        // Check for manually provided path
        else if let path = certificatePath {
            print("Using provided APNS key path: \(path)")
            keyPath = path
        }
        
        // Check various potential locations
        let potentialPaths = [
            // Manual path provided (already checked)
            keyPath,
            // In the App bundle's Resources directory
            app.directory.resourcesDirectory.appending("APNS.p8"),
            // Directly in Sources/App/Resources
            "Sources/App/Resources/APNS.p8",
            // In project root
            "APNS.p8"
        ].compactMap { $0 }
        
        var keyData: Data?
        var foundPath: String?
        
        for path in potentialPaths {
            print("Checking for APNS key at: \(path)")
            
            if FileManager.default.fileExists(atPath: path) {
                print("✅ APNS key file found at: \(path)")
                foundPath = path
                
                do {
                    keyData = try Data(contentsOf: URL(fileURLWithPath: path))
                    break
                } catch {
                    print("⚠️ Found file but failed to read it: \(error)")
                }
            }
        }
        
        guard let keyData = keyData, let foundPath = foundPath else {
            let errorMessage = "APNS certificate not found at any expected location. Tried: \(potentialPaths.joined(separator: ", "))"
            print("❌ \(errorMessage)")
            throw APNSError.certificateNotFound(errorMessage)
        }
        
        // Get environment variables
        guard let keyId = Environment.get("APNS_KEY_ID") else {
            let errorMessage = "APNS_KEY_ID environment variable not set"
            print("❌ \(errorMessage)")
            print("⚠️ You must set the APNS_KEY_ID environment variable to your Apple Developer key ID")
            throw APNSError.invalidConfiguration(errorMessage)
        }
        
        guard let teamId = Environment.get("APNS_TEAM_ID") else {
            let errorMessage = "APNS_TEAM_ID environment variable not set"
            print("❌ \(errorMessage)")
            print("⚠️ You must set the APNS_TEAM_ID environment variable to your Apple Developer Team ID")
            throw APNSError.invalidConfiguration(errorMessage)
        }
        
        print("APNS_KEY_ID: \(keyId)")
        print("APNS_TEAM_ID: \(teamId)")
        
        do {
            // Convert key data to string
            guard let privateKeyString = String(data: keyData, encoding: .utf8) else {
                throw APNSError.invalidConfiguration("Could not read private key file")
            }
            
            // Check for environment setting
            let isProd = Environment.get("APNS_PRODUCTION")?.lowercased() == "true"
            let environment: APNSEnvironment = isProd ? .production : .development
            
            app.logger.info("Configuring APNS client for \(isProd ? "PRODUCTION" : "DEVELOPMENT") environment")
            
            let config = APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: try .init(pemRepresentation: privateKeyString),
                    keyIdentifier: keyId,
                    teamIdentifier: teamId
                ),
                environment: environment
            )

            // Configure APNS client
            self.apnsClient = APNSClient(
                configuration: config,
                eventLoopGroupProvider: .shared(app.eventLoopGroup),
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder()
            )
            
            print("✅ APNS client initialized successfully using key at: \(foundPath)")
        } catch {
            print("❌ Failed to initialize APNS client: \(error)")
            throw error
        }
    }
    
    func sendNotification(to deviceToken: String, title: String, body: String, payload: [String: String] = [:]) async throws {
        guard let apnsClient = self.apnsClient else {
            throw APNSError.clientNotInitialized
        }
        
        // Get the app bundle ID from environment or use default
        let bundleId = Environment.get("APNS_BUNDLE_ID") ?? "com.bebop.app"
        
        // Build alert notification
        let alert = APNSAlertNotification<CustomPayload>(
            alert: APNSAlertNotificationContent(
                title: .raw(title),
                subtitle: nil,
                body: .raw(body),
                launchImage: nil
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: bundleId,
            payload: CustomPayload(custom: payload)
        )
        
        try await apnsClient.sendAlertNotification(
            alert,
            deviceToken: deviceToken
        )
        
        print("Notification sent to \(deviceToken)")
    }
    
    func sendTransactionNotification(to deviceToken: String, transaction: [String: Any]) async throws {
        guard let stellarAccount = transaction["stellarAccount"] as? String,
              let eventData = transaction["eventData"] as? String else {
            throw APNSError.invalidTransactionData
        }
        
        let payload: [String: String] = [
            "stellarAccount": stellarAccount,
            "eventType": "transaction",
            "eventData": eventData,
            "timestamp": String(Date().timeIntervalSince1970)
        ]
        
        try await sendNotification(
            to: deviceToken,
            title: "Bebop",
            body: "You recieved a payment",
            payload: payload
        )
    }
    
    func shutdown() async throws {
        if let apnsClient = self.apnsClient {
            try await apnsClient.shutdown()
            print("APNS client shut down")
        }
    }
} 
