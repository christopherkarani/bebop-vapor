import Foundation
import Vapor
import AsyncHTTPClient
import NIOCore
import NIOWebSocket
import WebSocketKit
import APNS
import APNSCore
import Fluent
import NIOHTTP1

// Database models for tracking cursors and processed transactions - Placed outside the actor to avoid Sendable issues
// These models need @unchecked Sendable because they're referenced from an actor but have mutable properties.
// Their usage pattern ensures they're not accessed concurrently in an unsafe manner.
final class CursorRecord: Model, @unchecked Sendable {
    static let schema = "stellar_cursors"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "stellar_account")
    var stellarAccount: String
    
    @Field(key: "cursor")
    var cursor: String
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() {}
    
    init(id: UUID? = nil, stellarAccount: String, cursor: String) {
        self.id = id
        self.stellarAccount = stellarAccount
        self.cursor = cursor
    }
}

// Database model for tracking processed transactions
// Needs @unchecked Sendable for the same reasons as CursorRecord
final class ProcessedTransactionRecord: Model, @unchecked Sendable {
    static let schema = "processed_transactions"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "stellar_account")
    var stellarAccount: String
    
    @Field(key: "transaction_id")
    var transactionId: String
    
    @Field(key: "processed_at")
    var processedAt: Date
    
    init() {}
    
    init(id: UUID? = nil, stellarAccount: String, transactionId: String, processedAt: Date = Date()) {
        self.id = id
        self.stellarAccount = stellarAccount
        self.transactionId = transactionId
        self.processedAt = processedAt
    }
}

actor StellarNotificationService {
    private static var instance: StellarNotificationService?
    
    static func shared(app: Application) -> StellarNotificationService {
        if instance == nil {
            instance = StellarNotificationService(app: app)
        }
        return instance!
    }
    
    private let app: Application
    private let horizonURL: String
    private var isMonitoring: Bool = false
    private var lastCursor: String?
    private var currentAccount: String?
    private var monitoredAccounts: Set<String> = []
    private var eventLoop: (any EventLoop)?
    private var httpClient: HTTPClient?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isHeartbeatActive: Bool = false
    private var keepaliveInterval: UInt64 = 30_000_000_000 // 30 seconds in nanoseconds
    private var consecutiveFailures: Int = 0
    private let maxReconnectDelay: UInt64 = 60_000_000_000 // 60 seconds in nanoseconds
    private var processedTransactions: Set<String> = []
    private let maxProcessedTransactionsCount: Int = 1000
    private var usePolling: Bool = false
    private var deviceTokenCache: [String: String] = [:]
    
    init(app: Application) {
        self.app = app
        self.horizonURL = Environment.get("STELLAR_HORIZON_URL") ?? "https://horizon-testnet.stellar.org"
        
        // Configure HTTPClient with longer timeouts for streaming connections
        let clientConfig = HTTPClient.Configuration(
            timeout: .init(connect: .seconds(30), read: .seconds(600)),
            connectionPool: .init(
                idleTimeout: .seconds(300),
                concurrentHTTP1ConnectionsPerHostSoftLimit: 8
            ),
            ignoreUncleanSSLShutdown: true,
            decompression: .enabled(limit: .none)
        )
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup), configuration: clientConfig)
        
        self.eventLoop = app.eventLoopGroup.next()
    }

    // Cache a device token in memory for fast lookups
    func cacheDeviceToken(_ token: String, for account: String) {
        deviceTokenCache[account] = token
    }

    // Remove a cached token and delete the registration from the database
    func removeDeviceToken(for account: String) async throws {
        deviceTokenCache.removeValue(forKey: account)

        if let registration = try await DeviceTokenRegistration.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .first() {
            try await registration.delete(on: app.db)
        }
    }

    // Retrieve a device token from cache or fallback to the database
    func getDeviceToken(for account: String) async throws -> String? {
        if let cached = deviceTokenCache[account] {
            return cached
        }

        if let registration = try await DeviceTokenRegistration.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .first() {
            deviceTokenCache[account] = registration.deviceToken
            return registration.deviceToken
        }

        return nil
    }
    
    func startMonitoring(account: String) async throws {
        guard !monitoredAccounts.contains(account) else { return }
        
        // Check if account exists on testnet
        let url = "\(horizonURL)/accounts/\(account)"
        var request = try HTTPClient.Request(url: url, method: .GET)
        request.headers.add(name: "Accept", value: "application/json")
        
        let response = try await httpClient?.execute(request: request).get()
        guard let response = response else {
            throw StellarError.invalidResponse
        }
        
        guard response.status == .ok else {
            throw StellarError.accountNotFound
        }
        
        // Load previously processed transactions from database
        processedTransactions = await loadProcessedTransactions(for: account)
        app.logger.info("🔄 STELLAR: Loaded \(processedTransactions.count) previously processed transactions")
        
        // Always start with "now" when first monitoring an account
        // This ensures we only get new transactions and don't process historical ones
        lastCursor = "now"
        app.logger.info("🔄 STELLAR: Starting fresh monitoring with cursor=now for account: \(account)")
        await saveLastCursor(lastCursor!, for: account)
        
        monitoredAccounts.insert(account)
        currentAccount = account
        isMonitoring = true
        consecutiveFailures = 0
        usePolling = false
        
        // Start monitoring in the background with optimized streaming
        reconnectTask = Task {
            await monitorAccount(account)
        }
        
        app.logger.info("✅ Successfully started monitoring account: \(account)")
    }
    
    private func loadLastCursor(for account: String) async -> String? {
        let cursorRecord = try? await CursorRecord.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .first()
        
        if let cursor = cursorRecord?.cursor {
            app.logger.info("Loaded saved cursor for account \(account): \(cursor)")
            return cursor
        } else {
            app.logger.info("No saved cursor found for account \(account), using 'now'")
            return "now"
        }
    }
    
    private func saveLastCursor(_ cursor: String, for account: String) async {
        // We'll use try? to silently handle the case where the table doesn't exist
        if let existingRecord = try? await CursorRecord.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .first() {
            
            // Table exists and record found, update it
            existingRecord.cursor = cursor
            try? await existingRecord.save(on: app.db)
            app.logger.debug("Updated cursor record for account \(account): \(cursor)")
        } else {
            // Either table doesn't exist or record not found, in memory tracking only
            app.logger.debug("Unable to save cursor to database, tracking in memory only: \(cursor)")
        }
    }
    
    private func loadProcessedTransactions(for account: String) async -> Set<String> {
        // Query for all processed transactions for this account
        let records = try? await ProcessedTransactionRecord.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .all()
        
        if let records = records, !records.isEmpty {
            let transactionIds = Set(records.map { $0.transactionId })
            app.logger.info("✅ STELLAR: Loaded \(transactionIds.count) processed transactions from database")
            return transactionIds
        } else {
            app.logger.info("ℹ️ STELLAR: No processed transactions found in database, using empty set")
            return []
        }
    }
    
    private func saveProcessedTransaction(_ transactionId: String, for account: String) async {
        // Add to in-memory cache
        processedTransactions.insert(transactionId)
        
        // Save to database for persistence across restarts
        // Check if already saved first to avoid duplicates
        let existingRecord = try? await ProcessedTransactionRecord.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .filter(\.$transactionId == transactionId)
            .first()
        
        if existingRecord == nil {
            // Create new record
            let record = ProcessedTransactionRecord(
                stellarAccount: account,
                transactionId: transactionId,
                processedAt: Date()
            )
            
            try? await record.save(on: app.db)
            app.logger.debug("✅ STELLAR: Saved processed transaction \(transactionId) to database")
        } else {
            app.logger.debug("ℹ️ STELLAR: Transaction \(transactionId) already in database")
        }
        
        // Clean up old records if we have too many
        if processedTransactions.count > maxProcessedTransactionsCount {
            await cleanupOldProcessedTransactions(for: account)
        }
    }
    
    // New method to clean up old processed transactions
    private func cleanupOldProcessedTransactions(for account: String) async {
        app.logger.info("🧹 STELLAR: Cleaning up old processed transactions")
        
        // Find the oldest transactions to delete
        let oldestRecords = try? await ProcessedTransactionRecord.query(on: app.db)
            .filter(\.$stellarAccount == account)
            .sort(\.$processedAt, .ascending)
            .limit(maxProcessedTransactionsCount / 2)
            .all()
        
        if let oldestRecords = oldestRecords, !oldestRecords.isEmpty {
            // Delete these records
            for record in oldestRecords {
                try? await record.delete(on: app.db)
            }
            
            app.logger.info("🧹 STELLAR: Removed \(oldestRecords.count) old transaction records")
            
            // Also clean up the in-memory cache (keep only the most recent half)
            let transactionsToKeep = try? await ProcessedTransactionRecord.query(on: app.db)
                .filter(\.$stellarAccount == account)
                .all()
            
            if let transactionsToKeep = transactionsToKeep {
                processedTransactions = Set(transactionsToKeep.map { $0.transactionId })
                app.logger.info("🧹 STELLAR: Reset in-memory transaction cache to \(processedTransactions.count) entries")
            }
        }
    }
    
    // Method to immediately check for transactions (used when starting monitoring)
    private func forceCheckForTransactions(account: String) async {
        app.logger.error("🔍 STELLAR: Performing initial transaction check for: \(account)")
        
        // Query for most recent transactions, ordered by most recent first
        let url = "\(horizonURL)/accounts/\(account)/transactions?order=desc&limit=10"
        
        var request = try? HTTPClient.Request(url: url, method: .GET)
        request?.headers.add(name: "Accept", value: "application/json")
        
        guard let request = request else {
            app.logger.error("❌ STELLAR: Failed to create transaction check request")
            return
        }
        
        let response = try? await httpClient?.execute(request: request).get()
        guard let response = response,
              response.status == .ok,
              let body = response.body else {
            app.logger.error("❌ STELLAR: Transaction check request failed")
            return
        }
        
        let data = Data(buffer: body)
        
        if let transactionResponse = try? JSONDecoder().decode(TransactionResponse.self, from: data) {
            let count = transactionResponse._embedded.records.count
            app.logger.error("🌟 STELLAR: Found \(count) recent transactions in initial check")
            
            if count > 0 {
                // Get the most recent transaction's paging token to use as our cursor
                let mostRecentTransaction = transactionResponse._embedded.records[0]
                lastCursor = mostRecentTransaction.paging_token
                app.logger.error("🌟 STELLAR: Starting monitoring from cursor: \(lastCursor!)")
                await saveLastCursor(lastCursor!, for: account)
            } else {
                app.logger.error("ℹ️ STELLAR: No recent transactions found during initial check")
            }
        }
    }
    
    // Optimized method to establish a streaming connection with proper keep-alive
    private func monitorAccount(_ account: String) async {
        // Initialize cursor to 'now' to stream only new transactions going forward
        if lastCursor == nil || lastCursor == "now" {
            lastCursor = "now" 
            app.logger.error("🌟 STELLAR: Starting monitoring from NOW for account: \(account)")
        } else {
            app.logger.error("🌟 STELLAR: Resuming monitoring from cursor: \(lastCursor!) for account: \(account)")
        }
        
        // Start the heartbeat task if not already running
        if heartbeatTask == nil {
            startHeartbeat()
        }
        
        // Create a dedicated HTTPClient with proper configurations for streaming
        let streamingClient = HTTPClient(
            eventLoopGroupProvider: .shared(app.eventLoopGroup),
            configuration: .init(
                timeout: .init(connect: .seconds(5), read: .seconds(600)),
                connectionPool: .init(
                    idleTimeout: .seconds(600),
                    concurrentHTTP1ConnectionsPerHostSoftLimit: 1
                ),
                ignoreUncleanSSLShutdown: true
            )
        )
        
        while isMonitoring {
            // Improved streaming connection with better performance
            app.logger.error("🔄 STELLAR: Establishing streaming connection...")
            
            do {
                // Create a streaming URL with better quality-of-service parameters
                let streamUrl = "\(horizonURL)/accounts/\(account)/transactions?cursor=\(lastCursor ?? "now")&X-Client-Timeout=600"
                app.logger.error("🔗 STELLAR: Opening stream connection to: \(streamUrl)")
                
                var request = try HTTPClient.Request(url: streamUrl, method: .GET)
                
                // Critical headers for SSE
                request.headers.add(name: "Accept", value: "text/event-stream")
                request.headers.add(name: "Connection", value: "keep-alive")
                request.headers.add(name: "Cache-Control", value: "no-cache")
                request.headers.add(name: "Keep-Alive", value: "timeout=600")
                request.headers.add(name: "X-Client-Name", value: "bebop-ios-app")
                
                let requestStartTime = Date().timeIntervalSince1970
                let response = try await streamingClient.execute(request: request).get()
                let responseTime = Date().timeIntervalSince1970 - requestStartTime
                
                app.logger.error("⏱️ STELLAR: Stream connection established in \(responseTime) seconds")
                
                if response.status != HTTPResponseStatus.ok {
                    app.logger.error("❌ STELLAR: Stream connection failed with status: \(response.status)")
                    throw StellarError.streamError
                }
                
                guard let body = response.body else {
                    app.logger.error("❌ STELLAR: Stream returned empty body")
                    throw StellarError.invalidResponse
                }
                
                app.logger.error("✅ STELLAR: Stream connection established successfully")
                consecutiveFailures = 0
                isHeartbeatActive = true // Mark heartbeat as active once connection is established
                
                // Process the stream data with more efficient parsing
                var buffer = ""
                var lastDataTime = Date()
                var eventCount = 0
                
                app.logger.error("🔄 STELLAR: Starting to process streaming data...")
                
                // Process each byte of the stream
                for chunk in body.readableBytesView {
                    // Update heartbeat time for any data
                    lastDataTime = Date()
                    
                    if let char = String(bytes: [chunk], encoding: .utf8) {
                        buffer.append(char)
                        
                        // When we see a double newline, it's the end of an event
                        if buffer.contains("\n\n") {
                            let events = buffer.components(separatedBy: "\n\n")
                            
                            // Process all complete events
                            for i in 0..<events.count-1 {
                                let event = events[i]
                                eventCount += 1
                                
                                // Skip heartbeat messages
                                if event.contains("\"hello\"") || event.contains("\"byebye\"") || event.contains("Waiting for") {
                                    app.logger.debug("💓 STELLAR: Heartbeat event received")
                                    continue
                                }
                                
                                // Extract the JSON data from the event
                                if let dataLine = event.components(separatedBy: "\n").first(where: { $0.hasPrefix("data:") }) {
                                    let jsonString = String(dataLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines))
                                    
                                    // Process events quickly in a dedicated task
                                    let dataToProcess = jsonString
                                    Task {
                                        if let jsonData = dataToProcess.data(using: .utf8),
                                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                           let id = json["id"] as? String {
                                            
                                            // Skip already processed
                                            if processedTransactions.contains(id) {
                                                app.logger.debug("ℹ️ STELLAR: Skipping already processed transaction: \(id)")
                                                return
                                            }
                                            
                                            // Skip failed transactions
                                            if let successful = json["successful"] as? Bool, !successful {
                                                app.logger.debug("ℹ️ STELLAR: Skipping unsuccessful transaction: \(id)")
                                                processedTransactions.insert(id)
                                                await saveProcessedTransaction(id, for: account)
                                                return
                                            }
                                            
                                            // Update cursor immediately
                                            if let pagingToken = json["paging_token"] as? String {
                                                lastCursor = pagingToken
                                                await saveLastCursor(pagingToken, for: account)
                                            }
                                            
                                            // Process transaction quickly
                                            if let transaction = try? mapJsonToTransaction(json) {
                                                let receivedTime = Date().timeIntervalSince1970
                                                app.logger.error("🌟 STELLAR: Processing transaction \(id) from stream")
                                                
                                                // Start the notification process immediately with the transaction
                                                // without waiting for operations lookup
                                                await processTransaction(transaction, for: account)
                                                
                                                let processingTime = Date().timeIntervalSince1970 - receivedTime
                                                app.logger.error("⏱️ STELLAR: Stream processing time: \(processingTime) seconds")
                                            }
                                        }
                                    }
                                }
                            }
                            
                            // Keep only the last partial event
                            buffer = events.last ?? ""
                        }
                    }
                    
                    // Check for timeout to detect dead connections
                    let currentTime = Date()
                    if currentTime.timeIntervalSince(lastDataTime) > 120 { // 2 minutes with no data
                        app.logger.error("⚠️ STELLAR: No data received for 2 minutes, stream connection may be dead")
                        throw StellarError.streamError // Force reconnection
                    }
                }
                
                isHeartbeatActive = false // Disable heartbeat when connection is closed
                app.logger.error("ℹ️ STELLAR: Stream connection closed after \(eventCount) events")
                
            } catch {
                isHeartbeatActive = false // Disable heartbeat on connection error
                consecutiveFailures += 1
                app.logger.error("❌ STELLAR: Stream error: \(error)")
                
                // Calculate backoff delay with exponential increase but max cap
                let backoffDelay = min(
                    UInt64(pow(2.0, Double(min(consecutiveFailures, 6)))) * 1_000_000_000,
                    maxReconnectDelay
                )
                app.logger.error("⏱️ STELLAR: Reconnecting in \(backoffDelay/1_000_000_000) seconds...")
                try? await Task.sleep(nanoseconds: backoffDelay)
            }
        }
        
        // Cleanup when done monitoring
        try? await streamingClient.shutdown()
    }
    
    // Start a background task to send periodic heartbeats to keep the connection alive
    private func startHeartbeat() {
        app.logger.error("💓 STELLAR: Starting heartbeat task")
        
        heartbeatTask = Task {
            while isMonitoring {
                if isHeartbeatActive {
                    // Get server time from Stellar to maintain connection
                    let pingUrl = "\(horizonURL)/fee_stats"
                    var request = try? HTTPClient.Request(url: pingUrl, method: .HEAD)
                    request?.headers.add(name: "Connection", value: "keep-alive")
                    request?.headers.add(name: "Cache-Control", value: "no-cache")
                    
                    if let request = request {
                        let response = try? await httpClient?.execute(request: request).get()
                        
                        if let status = response?.status {
                            app.logger.debug("💓 STELLAR: Keep-alive ping successful with status: \(status)")
                        } else {
                            app.logger.debug("⚠️ STELLAR: Keep-alive ping failed with no response")
                        }
                        
                        // Check server time if available
                        if let dateHeader = response?.headers.first(name: "Date") {
                            app.logger.debug("🕒 STELLAR: Server time: \(dateHeader)")
                        }
                    }
                }
                
                // Sleep for the keep-alive interval - use a shorter interval (20 seconds)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            
            app.logger.error("💤 STELLAR: Heartbeat task stopped")
        }
    }
    
    // Process a single event from the stream
    private func processEventData(_ data: String, for account: String) async {
        // Handle special stream events
        if data.contains("\"hello\"") || data.contains("\"byebye\"") || data.contains("\"message\":\"Waiting for new ledgers") {
            app.logger.debug("💓 STELLAR: Heartbeat or status message: \(data)")
            return
        }
        
        app.logger.error("📥 STELLAR: Processing transaction event")
        
        guard let jsonData = data.data(using: .utf8) else {
            app.logger.error("❌ STELLAR: Invalid event data encoding")
            return
        }
        
        do {
            // Parse the JSON data
            let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            
            // Check if this is a transaction
            guard let json = json, let id = json["id"] as? String else {
                app.logger.error("❌ STELLAR: Event data missing transaction ID or invalid format")
                app.logger.error("❌ STELLAR: Raw event: \(data.prefix(200))...")
                return
            }
            
            // Skip if already processed
            if processedTransactions.contains(id) {
                app.logger.error("ℹ️ STELLAR: Skipping already processed transaction: \(id)")
                return
            }
            
            app.logger.error("🔍 STELLAR: Processing streamed transaction: \(id)")
            
            // Parse the transaction from the JSON
            let transaction = try mapJsonToTransaction(json)
            
            if transaction.successful {
                // Update cursor immediately to avoid reprocessing
                lastCursor = transaction.paging_token
                await saveLastCursor(transaction.paging_token, for: account)
                
                // Process the transaction
                await processTransaction(transaction, for: account)
            } else {
                app.logger.error("ℹ️ STELLAR: Transaction was not successful, skipping: \(id)")
                processedTransactions.insert(id)
                await saveProcessedTransaction(id, for: account)
            }
            
            // Reset failure counter on successful processing
            consecutiveFailures = 0
            } catch {
            app.logger.error("❌ STELLAR: Error processing event data: \(error)")
            
            // Log more detailed debugging information for JSON parsing errors
            if let nsError = error as NSError? {
                app.logger.error("❌ STELLAR: Error domain: \(nsError.domain), code: \(nsError.code)")
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    app.logger.error("❌ STELLAR: Underlying error: \(underlyingError)")
                }
            }
            
            app.logger.error("❌ STELLAR: Raw event: \(data.prefix(200))...")
        }
    }
    
    // Process a transaction to check for payments - optimized for minimal latency
    private func processTransaction(_ transaction: Transaction, for account: String) async {
        let startTime = Date().timeIntervalSince1970
        app.logger.error("🔍 STELLAR: Processing transaction ID: \(transaction.id), created at \(transaction.created_at)")
        
        // OPTIMIZATION: Skip fetching operations if already processed
        if processedTransactions.contains(transaction.id) {
            app.logger.error("ℹ️ STELLAR: Transaction \(transaction.id) already processed, skipping")
            return
        }
        
        // Mark as processed immediately to avoid duplicate processing
        processedTransactions.insert(transaction.id)
        
        // CRITICAL OPTIMIZATION: Send an immediate notification without waiting
        // This dramatically reduces perceived notification latency
        Task {
            let notifStartTime = Date().timeIntervalSince1970
            
            // Send immediate simple notification with just "Payment received"
            await sendPaymentNotification(
                transaction,
                amount: "funds",
                assetCode: "", 
                isDetailedNotification: false
            )
            
            let notifTime = Date().timeIntervalSince1970 - notifStartTime
            app.logger.error("⚡️ STELLAR: Immediate notification sent in \(notifTime) seconds")
        }
        
        // Save to database in the background
        Task {
            await saveProcessedTransaction(transaction.id, for: account)
        }
        
        // In parallel, fetch operations to get accurate payment details
        let operationsUrl = "\(horizonURL)/transactions/\(transaction.id)/operations?limit=10"
        app.logger.debug("🔍 STELLAR: Fetching operations from \(operationsUrl)")
        
        var operationsRequest = try? HTTPClient.Request(url: operationsUrl, method: .GET)
        operationsRequest?.headers.add(name: "Accept", value: "application/json")
        operationsRequest?.headers.add(name: "Connection", value: "close") // Don't keep connection open
        
        guard let operationsRequest = operationsRequest else {
            app.logger.error("❌ STELLAR: Failed to create operations request")
            return
        }
        
        // Fetch operations directly
        do {
            let requestStartTime = Date().timeIntervalSince1970
            
            guard let response = try await httpClient?.execute(request: operationsRequest).get(),
                  response.status == .ok,
                  let body = response.body else {
                app.logger.error("❌ STELLAR: Failed to fetch operations - bad response")
                return
            }
            
            let requestTime = Date().timeIntervalSince1970 - requestStartTime
            app.logger.debug("⏱️ STELLAR: Operations API request took \(requestTime) seconds")
            
            // Process the operations response
            let opData = Data(buffer: body)
            
            guard let operationsData = try? JSONSerialization.jsonObject(with: opData) as? [String: Any],
                let records = operationsData["_embedded"] as? [String: Any],
                let operations = records["records"] as? [[String: Any]] else {
                app.logger.error("❌ STELLAR: Failed to parse operations response")
                return
            }
            
            // Check for payment operations
            for operation in operations {
                if let type = operation["type"] as? String, type == "payment",
                   let destination = operation["to"] as? String, destination == account {
                    
                    // We found a payment to this account - get the details
                    let amount = operation["amount"] as? String ?? ""
                    
                    // Format amount
                    var formattedAmount = amount
                    if let amountValue = Double(amount) {
                        if amountValue.truncatingRemainder(dividingBy: 1) == 0 {
                            // Whole number, format without decimals
                            formattedAmount = String(format: "%.0f", amountValue)
                        } else {
                            // Has decimals, format with 2 decimal places
                            formattedAmount = String(format: "%.2f", amountValue)
                        }
                    }
                    
                    // Determine asset code
                    let assetType = operation["asset_type"] as? String ?? ""
                    var assetCode = ""
                    if assetType == "native" {
                        assetCode = "XLM"
                    } else {
                        assetCode = operation["asset_code"] as? String ?? ""
                    }
                    
                    app.logger.error("💰 STELLAR: Found payment: \(formattedAmount) \(assetCode) to \(destination)")
                    
                    // Send a follow-up detailed notification with accurate payment details 
                    // This gives the user the specific amount information
                    await sendPaymentNotification(
                        transaction,
                        amount: formattedAmount,
                        assetCode: assetCode,
                        isDetailedNotification: true
                    )
                    
                    break // Only process the first payment operation to this account
                }
            }
            
            let totalTime = Date().timeIntervalSince1970 - startTime
            app.logger.debug("⏱️ STELLAR: Total transaction processing took \(totalTime) seconds")
            
        } catch {
            app.logger.error("❌ STELLAR: Error fetching operations: \(error)")
        }
    }
    
    // Optimize the notification sending process
    private func sendPaymentNotification(_ transaction: Transaction, amount: String, assetCode: String, isDetailedNotification: Bool = true) async {
        let startTime = Date().timeIntervalSince1970
        guard let currentAccount = currentAccount else {
            app.logger.error("❌ NOTIFICATION: No current account set for notification")
            return
        }
        
        // Format notification based on whether this is a detailed or quick notification
        let notificationBody = isDetailedNotification 
            ? "You received \(amount) \(assetCode) 💸" 
            : "You received a payment 💸"
            
        app.logger.error("🔔 NOTIFICATION: Preparing \(isDetailedNotification ? "detailed" : "immediate") notification: \"\(notificationBody)\"")
        
        // Simplified payload with only essential information
        let payload: [String: String] = [
            "stellarAccount": currentAccount,
            "transactionId": transaction.id,
            "amount": amount,
            "assetCode": assetCode,
            "notificationType": isDetailedNotification ? "detailed" : "immediate"
        ]
        
        // Use cached registration if we have one to avoid DB lookup
        // This is a critical optimization for immediate notifications
        do {
            let dbLookupStartTime = Date().timeIntervalSince1970
            guard let deviceToken = try await getDeviceToken(for: currentAccount) else {
                app.logger.error("❌ NOTIFICATION: No device token found for account \(currentAccount)")
                return
            }
            let dbLookupTime = Date().timeIntervalSince1970 - dbLookupStartTime
            app.logger.error("⏱️ NOTIFICATION: Device token lookup took \(dbLookupTime) seconds")

            app.logger.error("✅ NOTIFICATION: Found device token, sending notification")

            // Send notification - measure exact time spent in APNs
            let notifSendStartTime = Date().timeIntervalSince1970

            try await NotificationBroadcaster.shared.broadcastNotification(
                to: deviceToken,
                title: "Payment Received",
                body: notificationBody,
                payload: payload
            )
            
            let notifSendTime = Date().timeIntervalSince1970 - notifSendStartTime
            let totalTime = Date().timeIntervalSince1970 - startTime
            
            app.logger.error("✅ NOTIFICATION: APNs send took \(notifSendTime) seconds")
            app.logger.error("✅ NOTIFICATION: Total notification process took \(totalTime) seconds")
            
        } catch {
            app.logger.error("❌ NOTIFICATION: Failed to send: \(error)")
            
            let errorString = error.localizedDescription
            if errorString.contains("BadDeviceToken") {
                app.logger.error("❌ NOTIFICATION: Invalid device token - token may be expired")
                try? await removeDeviceToken(for: currentAccount)
            } else if errorString.contains("DeviceTokenNotForTopic") {
                app.logger.error("❌ NOTIFICATION: Token doesn't match app bundle ID")
                try? await removeDeviceToken(for: currentAccount)
            } else if errorString.contains("Unregistered") {
                app.logger.error("❌ NOTIFICATION: Device has unregistered from notifications")
                try? await removeDeviceToken(for: currentAccount)
            } else {
                app.logger.error("❌ NOTIFICATION: Other APNS error: \(errorString)")
            }
        }
    }
    
    func stopMonitoring() {
        print("Stopping monitoring...")
        isMonitoring = false
        isHeartbeatActive = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        currentAccount = nil
    }
    
    deinit {
        try? httpClient?.syncShutdown()
    }
}

// Transaction model
struct Transaction: Codable {
    let id: String
    let successful: Bool
    let created_at: String
    let source_account: String
    let fee_account: String?
    let fee_charged: String?
    let operation_count: Int
    let envelope_xdr: String
    let result_xdr: String
    let result_meta_xdr: String?
    let fee_meta_xdr: String?
    let memo_type: String?
    let memo: String?
    let signatures: [String]
    let valid_after: String?
    let valid_before: String?
    let ledger: Int
    let paging_token: String
}

// Transaction response model
struct TransactionResponse: Codable {
    let _embedded: Embedded
    let _links: Links
    
    struct Embedded: Codable {
        let records: [Transaction]
    }
    
    struct Links: Codable {
        let next: Link
    }
    
    struct Link: Codable {
        let href: String
    }
}

enum StellarError: Error {
    case invalidResponse
    case accountNotFound
    case streamError
    case invalidTransactionFormat
}

// Helper method to convert JSON to Transaction
private func mapJsonToTransaction(_ json: [String: Any]) throws -> Transaction {
    guard 
        let id = json["id"] as? String,
        let pagingToken = json["paging_token"] as? String,
        let successful = json["successful"] as? Bool,
        let createdAt = json["created_at"] as? String,
        let sourceAccount = json["source_account"] as? String,
        let _ = (json["_links"] as? [String: Any])?["operations"] as? [String: Any]
    else {
        throw StellarError.invalidTransactionFormat
    }
    
    // Create a Transaction instance from the extracted values
    return Transaction(
        id: id,
        successful: successful,
        created_at: createdAt,
        source_account: sourceAccount,
        fee_account: nil,
        fee_charged: nil,
        operation_count: 0,
        envelope_xdr: "",
        result_xdr: "",
        result_meta_xdr: nil,
        fee_meta_xdr: nil,
        memo_type: nil,
        memo: "",
        signatures: [],
        valid_after: nil,
        valid_before: nil,
        ledger: 0,
        paging_token: pagingToken
    )
} 