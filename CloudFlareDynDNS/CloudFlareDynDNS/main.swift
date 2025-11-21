//
//  CloudFlareDynDNS.swift
//  Self-scheduling Dynamic DNS Updater with Dynamic DNS ID Lookup
//
//  Created by Todd Bruss
//  Runs now and 24/7 and executes at 12:00 AM UTC daily
//  (c) 2025 Logos InkPen LLC, InkPen.IO

import Foundation
import CryptoKit

// MARK: - Models

struct DNSZone {
    let domain: String
    let zoneId: String
}

struct DNSRecord: Codable {
    let id: String
    let name: String
    let type: String
    let content: String
    let proxied: Bool
    let ttl: Int
}

struct CloudflareResponse: Codable {
    let result: [DNSRecord]
    let success: Bool
    let errors: [CloudflareError]
    let messages: [String]
}

struct CloudflareError: Codable {
    let code: Int
    let message: String
}

struct CloudflareConfig {
    let email = "your-cloudflare-email-address" //edit me
    let apiKey = "your-cloudflare-api-key" //edit me
    let bearerToken = "your-cloudflare-bearer-token" //edit me
}

// MARK: - DNS Updater

actor DNSUpdater {
    private let config = CloudflareConfig()
    private let zones = [
        DNSZone(domain: "your-cloudflare-domain1", zoneId: "your-cloudflare-zoneid1"), //edit me
        DNSZone(domain: "your-cloudflare-domain2", zoneId: "your-cloudflare-zoneid2"), //edit me
    ]
    
    private var dnsRecordCache: [String: DNSRecord] = [:]
    
    func runForever() async {
        log("🚀 Todd's CloudFlareDynDNS Updater Started - Running 24/7")
        log("⏰ Configured to run Now and at 12:00 AM UTC daily")
        log("")
        
        // Run immediately on startup
        log("▶️  Running initial update...")
        await executeUpdate()
        log("")
        
        // Then continue with scheduled runs
        while true {
            let sleepSeconds = secondsUntilMidnightUTC()
            log("⏳ Next run in \(formatDuration(sleepSeconds))")
            
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds) * 1_000_000_000)
            
            await executeUpdate()
        }
    }
    
    private func executeUpdate() async {
        log("🚀 Starting DNS update cycle")
        log("⏰ \(formattedTimestamp())")
        
        do {
            // Fetch current IP
            let ipAddress = try await fetchPublicIPAddress()
            log("✅ Current Public IP: \(ipAddress)")
            
            // Fetch DNS records for all zones
            await fetchAllDNSRecords()
            
            // Update all records
            await updateAllRecords(with: ipAddress)
            
            log("✨ Update cycle completed successfully")
        } catch {
            log("❌ Error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Fetch DNS Records
    
    private func fetchAllDNSRecords() async {
        log("🔍 Fetching DNS record IDs...")
        
        await withTaskGroup(of: Void.self) { group in
            for zone in zones {
                group.addTask {
                    await self.fetchDNSRecords(for: zone)
                }
            }
        }
    }
    
    private func fetchDNSRecords(for zone: DNSZone) async {
        do {
            let records = try await performDNSRecordFetch(zoneId: zone.zoneId)
            
            // Find A record matching the domain
            if let aRecord = records.first(where: { $0.name == zone.domain && $0.type
              == "A" }) {
                  dnsRecordCache[zone.domain] = aRecord
                let idData = Data(aRecord.id.utf8)
                let hash = SHA256.hash(data: idData)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                log("✅ \(zone.domain) - SHA256 DNS ID: \(hashString)")
              } else {
                  log("⚠️  \(zone.domain) - No A record found")
              }
        } catch {
            log("❌ \(zone.domain) - Failed to fetch DNS records: \(error.localizedDescription)")
        }
    }
    
    private func performDNSRecordFetch(zoneId: String) async throws -> [DNSRecord] {
        let urlString = "https://api.cloudflare.com/client/v4/zones/\(zoneId)/dns_records"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "HTTP Error", code: -1)
        }
        
        let decoder = JSONDecoder()
        let cloudflareResponse = try decoder.decode(CloudflareResponse.self, from: data)
        
        guard cloudflareResponse.success else {
            let errorMessages = cloudflareResponse.errors.map { $0.message }.joined(separator: ", ")
            throw NSError(domain: "Cloudflare API Error: \(errorMessages)", code: -1)
        }
        
        return cloudflareResponse.result
    }
    
    // MARK: - IP Fetching
    
    private func fetchPublicIPAddress() async throws -> String {
        guard let url = URL(string: "https://api.ipify.org") else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        guard let ipAddress = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NSError(domain: "Invalid IP response", code: -1)
        }
        
        return ipAddress
    }
    
    // MARK: - DNS Updates
    
    private func updateAllRecords(with ipAddress: String) async {
        await withTaskGroup(of: Void.self) { group in
            for zone in zones {
                if let record = dnsRecordCache[zone.domain] {
                    group.addTask {
                        await self.updateDNSRecord(ipAddress, zone: zone, recordId: record.id)
                    }
                }
            }
        }
    }
    
    private func updateDNSRecord(_ ip: String, zone: DNSZone, recordId: String) async {
        do {
            try await performDNSUpdate(ip, zone: zone, recordId: recordId)
            log("✅ \(zone.domain) - Updated")
        } catch {
            log("❌ \(zone.domain) - Failed: \(error.localizedDescription)")
        }
    }
    
    private func performDNSUpdate(_ ip: String, zone: DNSZone, recordId: String) async throws {
        let urlString = "https://api.cloudflare.com/client/v4/zones/\(zone.zoneId)/dns_records/\(recordId)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Invalid URL", code: -1)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.email, forHTTPHeaderField: "X-Auth-Email")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Auth-Key")
        request.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")
        
        let parameters: [String: Any] = [
            "content": ip,
            "name": zone.domain,
            "proxied": true,
            "type": "A",
            "comment": "Auto-updated",
            "ttl": 1
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "HTTP Error", code: -1)
        }
    }
    
    // MARK: - Scheduling Helpers
    
    private func secondsUntilMidnightUTC() -> TimeInterval {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let midnightTomorrow = calendar.startOfDay(for: tomorrow)
        
        return midnightTomorrow.timeIntervalSince(now)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    
    // MARK: - Logging
    
    private func log(_ message: String) {
        let timestamp = formattedTimestamp()
        print("[\(timestamp)] \(message)")
        fflush(stdout)
    }
    
    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date()) + " UTC"
    }
}

// MARK: - Main Entry Point

let updater = DNSUpdater()
Task {
    await updater.runForever()
}

RunLoop.main.run()
