import Foundation
import CryptoKit
import CommonCrypto
import Security

/// 키체인 보관(이 기기에서만, 잠금 해제 상태에서만)
enum Keychain {
    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "kr.pocketclean",
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    @discardableResult static func set(_ key: String, _ data: Data) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "kr.pocketclean", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    static func delete(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "kr.pocketclean", kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
    }
    /// 없으면 새로 만든 256비트 키
    static func symmetricKey(_ name: String) -> SymmetricKey {
        if let d = get(name), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        set(name, k.withUnsafeBytes { Data($0) })
        return k
    }
}

enum Crypto {
    static let magic = Data("PCV1".utf8)

    /// 버전 머리말 + AES-256-GCM(고유 nonce 포함)
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let c = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return magic + c
    }
    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.count > magic.count + 28, data.prefix(magic.count) == magic else { throw CocoaError(.coderReadCorrupt) }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(magic.count)), using: key)
    }

    static func pbkdf2(_ password: String, salt: Data, rounds: UInt32 = 210_000) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        return SymmetricKey(data: out)
    }

    static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// 사람이 옮겨 적기 쉬운 복구 코드 (헷갈리는 글자 제외, 약 120비트)
    static func recoveryCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = random(24)
        let s = bytes.map { chars[Int($0) % chars.count] }
        return stride(from: 0, to: 24, by: 4).map { String(s[$0..<$0 + 4]) }.joined(separator: "-")
    }
}
