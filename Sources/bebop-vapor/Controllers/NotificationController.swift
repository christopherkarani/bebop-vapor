import Fluent
import Vapor
import APNSCore
import APNS

struct NotificationController: RouteCollection {
    
    
    func boot(routes: any RoutesBuilder) throws {
        let notifications = routes.grouped("notifications")
        
        // Register device token with Stellar account
        notifications.post("register-account", use: registerAccount)
        
        // Delete notification
        notifications.delete(":id", use: delete)
    }
    
    func registerAccount(req: Request) async throws -> Response {
        struct RegisterRequest: Content {
            let deviceToken: String
            let stellarAccount: String
        }
        
        do {
            let request = try req.content.decode(RegisterRequest.self)
            
            // Log the incoming request
            req.logger.info("Received device token registration request for Stellar account: \(request.stellarAccount)")
            
            // Validate Stellar account format
            let accountRegex = try NSRegularExpression(pattern: "^G[A-Z0-9]{55}$")
            let range = NSRange(request.stellarAccount.startIndex..., in: request.stellarAccount)
            guard accountRegex.firstMatch(in: request.stellarAccount, range: range) != nil else {
                req.logger.warning("Invalid Stellar account format: \(request.stellarAccount)")
                return Response(
                    status: .badRequest,
                    body: .init(string: "{\"reason\":\"Invalid Stellar account format. Must start with 'G' and be 56 characters long.\",\"error\":true}")
                )
            }
            
            // Check if device token is already registered
            if let existingRegistration = try await DeviceTokenRegistration.query(on: req.db)
                .filter(\.$deviceToken == request.deviceToken)
                .first() {
                // Update existing registration
                req.logger.info("Updating existing registration for device token: \(request.deviceToken)")
                existingRegistration.stellarAccount = request.stellarAccount
                try await existingRegistration.save(on: req.db)
            } else {
                // Create and save the device registration
                req.logger.info("Creating new registration for device token: \(request.deviceToken)")
                let registration = DeviceTokenRegistration(
                    deviceToken: request.deviceToken,
                    stellarAccount: request.stellarAccount
                )
                try await registration.save(on: req.db)
            }

            // Update in-memory cache for faster lookups
            await StellarNotificationService.shared(app: req.application)
                .cacheDeviceToken(request.deviceToken, for: request.stellarAccount)
            
            // Start monitoring the Stellar account
            do {
                req.logger.info("Starting to monitor Stellar account: \(request.stellarAccount)")
                try await StellarNotificationService.shared(app: req.application).startMonitoring(account: request.stellarAccount)
                
                // Return success response
                return Response(
                    status: .ok,
                    body: .init(string: "{\"message\":\"Device registered successfully\",\"error\":false}")
                )
            } catch StellarError.accountNotFound {
                req.logger.error("Stellar account not found: \(request.stellarAccount)")
                return Response(
                    status: .badRequest,
                    body: .init(string: "{\"reason\":\"Stellar account not found on the network.\",\"error\":true}")
                )
            } catch {
                req.logger.error("Failed to monitor Stellar account: \(error)")
                return Response(
                    status: .internalServerError,
                    body: .init(string: "{\"reason\":\"Failed to monitor Stellar account: \(error.localizedDescription)\",\"error\":true}")
                )
            }
        } catch {
            req.logger.error("Error processing registration request: \(error)")
            return Response(
                status: .internalServerError,
                body: .init(string: "{\"reason\":\"Error processing registration: \(error.localizedDescription)\",\"error\":true}")
            )
        }
    }
    
    func delete(req: Request) async throws -> HTTPStatus {
        guard let notification = try await Notification.find(req.parameters.get("id"), on: req.db) else {
            throw Abort(.notFound)
        }
        
        try await notification.delete(on: req.db)
        return .noContent
    }
} 
