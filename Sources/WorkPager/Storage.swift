import Foundation
import Security
import WorkPagerCore

struct Preferences: Codable {
    var deviceUID = ""
    var channel = 0
    var threshold = 0.90
    var cooldown = 30.0
    var cameraID = ""
    var autoMode = false
    var armDelay = 30.0
    var disarmDelay = 5.0
    var server = "https://ntfy.sh"
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "preferences"), var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.threshold = value.threshold.isFinite ? min(1, max(0.5, value.threshold)) : 0.9
        value.cooldown = value.cooldown.isFinite ? min(3600, max(1, value.cooldown)) : 30
        value.armDelay = value.armDelay.isFinite ? min(600, max(1, value.armDelay)) : 30
        value.disarmDelay = value.disarmDelay.isFinite ? min(600, max(1, value.disarmDelay)) : 5
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "preferences") } }
}

enum LocalStore {
    static var templateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkPager/reference.json")
    }
    static func loadTemplate() throws -> SoundTemplate? {
        guard FileManager.default.fileExists(atPath: templateURL.path) else { return nil }
        let value = try JSONDecoder().decode(SoundTemplate.self, from: Data(contentsOf: templateURL))
        guard value.isValid else { throw NSError(domain: "WorkPager", code: 1, userInfo: [NSLocalizedDescriptionKey: "保存済み学習データが無効です。再学習してください。"]) }
        return value
    }
    static func save(_ template: SoundTemplate) throws {
        try FileManager.default.createDirectory(at: templateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(template).write(to: templateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: templateURL.path)
    }
}

enum SecretStore {
    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.WorkPager", kSecAttrAccount as String: "ntfy-topic"] }
    static func save(_ topic: String) throws {
        let attributes = [kSecValueData as String: Data(topic.utf8)]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = base.merging(attributes) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychainへの保存に失敗しました (\(status))"]) }
    }
}
