import Foundation
import Vapor
import APNS
import APNSCore
import WebSocketKit

final class NotificationBroadcaster: @unchecked Sendable {
    static let shared = NotificationBroadcaster()
    
    private var connections: [String: WebSocket] = [:]
    private var apnsService: APNSService?
    private var app: Application?
    private var apnsEnabled = false
    
    private init() {}
    
    func initialize(app: Application) async {
        self.app = app
        
        do {
            app.logger.info("Initializing APNS Service...")
            self.apnsService = APNSService()
            try await apnsService?.configure(app: app)
            apnsEnabled = true
            app.logger.info("✅ APNS Service initialized successfully")
        } catch APNSError.certificateNotFound(let message) {
            apnsEnabled = false
            app.logger.error("❌ APNS certificate not found: \(message)")
            app.logger.warning("⚠️ Server will run without APNS capabilities")
        } catch APNSError.invalidConfiguration(let message) {
            apnsEnabled = false
            app.logger.error("❌ APNS configuration error: \(message)")
            app.logger.warning("⚠️ Server will run without APNS capabilities")
            app.logger.warning("⚠️ Check that you have set the required environment variables:")
            app.logger.warning("⚠️ - APNS_KEY_ID: Your Apple Developer Key ID")
            app.logger.warning("⚠️ - APNS_TEAM_ID: Your Apple Developer Team ID")
            app.logger.warning("⚠️ - APNS_BUNDLE_ID: Your app's bundle ID (optional, default: com.bebop.app)")
        } catch {
            apnsEnabled = false
            app.logger.error("❌ Failed to initialize APNS Service: \(error)")
            app.logger.warning("⚠️ Server will run without APNS capabilities")
        }
    }
    
    func addConnection(_ ws: WebSocket, for deviceToken: String) {
        connections[deviceToken] = ws
        print("Added WebSocket connection for device: \(deviceToken)")
    }
    
    func removeConnection(for deviceToken: String) {
        connections.removeValue(forKey: deviceToken)
        print("Removed WebSocket connection for device: \(deviceToken)")
    }
    
    func broadcastNotification(to deviceToken: String, title: String, body: String, payload: [String: String] = [:]) async throws {
        // Try WebSocket first
        if let ws = connections[deviceToken] {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: payload)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    try await ws.send(jsonString)
                    print("Sent notification via WebSocket to device: \(deviceToken)")
                    return
                }
            } catch {
                print("Failed to send WebSocket notification: \(error)")
            }
        }
        
        // Fallback to APNS if enabled
        if apnsEnabled, let apnsService = apnsService {
            do {
                try await apnsService.sendNotification(
                    to: deviceToken,
                    title: title,
                    body: body,
                    payload: payload
                )
                print("Sent notification via APNS to device: \(deviceToken)")
            } catch let apnsError as APNSCore.APNSError {
                let errorMessage = "Failed to send APNS notification: \(apnsError)"
                print("❌ \(errorMessage)")
                
                // Extract reason string
                let reasonString = String(describing: apnsError.reason)
                
                // Provide specific guidance based on error message
                if reasonString.contains("invalidProviderToken") {
                    print("⚠️ Invalid provider token. Check your APNS_KEY_ID, APNS_TEAM_ID, and certificate.")
                    print("⚠️ Also ensure you're using the correct environment (development/production).")
                    print("⚠️ Current environment: \(Environment.get("APNS_PRODUCTION") == "true" ? "PRODUCTION" : "DEVELOPMENT")")
                } else if reasonString.contains("deviceTokenNotForTopic") {
                    print("⚠️ Device token not for topic. Check your APNS_BUNDLE_ID.")
                    print("⚠️ Current bundle ID: \(Environment.get("APNS_BUNDLE_ID") ?? "Not set")")
                } else if reasonString.contains("badDeviceToken") {
                    print("⚠️ Bad device token: \(deviceToken)")
                    print("⚠️ Make sure the device token is valid and formatted correctly.")
                } else {
                    print("⚠️ APNS error reason: \(reasonString)")
                    print("⚠️ Response status: \(apnsError.responseStatus)")
                }
                
                throw apnsError
            } catch {
                print("Failed to send APNS notification: \(error)")
                throw error
            }
        } else {
            print("⚠️ APNS is not enabled. Notification not sent to device: \(deviceToken)")
        }
    }
} 