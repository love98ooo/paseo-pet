import Darwin
import Foundation

enum CredentialStore {
    private static let directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PaseoPet", isDirectory: true)
    private static let passwordURL = directoryURL.appendingPathComponent("daemon-password")

    static func loadPassword() -> String? {
        guard
            isSecureItem(at: directoryURL, type: .typeDirectory, permissions: 0o700),
            isSecureItem(at: passwordURL, type: .typeRegular, permissions: 0o600),
            let data = try? Data(contentsOf: passwordURL),
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        else { return nil }
        return password
    }

    @discardableResult
    static func savePassword(_ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let fileManager = FileManager.default
        do {
            if (try? fileManager.attributesOfItem(atPath: directoryURL.path)) != nil {
                guard isOwnedItem(at: directoryURL, type: .typeDirectory) else { return false }
            } else {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            guard isSecureItem(at: directoryURL, type: .typeDirectory, permissions: 0o700) else { return false }
            if (try? fileManager.attributesOfItem(atPath: passwordURL.path)) != nil {
                guard isOwnedItem(at: passwordURL, type: .typeRegular) else { return false }
            }
            try Data(password.utf8).write(to: passwordURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
            return isSecureItem(at: passwordURL, type: .typeRegular, permissions: 0o600)
        } catch {
            return false
        }
    }

    private static func isOwnedItem(at url: URL, type: FileAttributeType) -> Bool {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == type,
            let owner = attributes[.ownerAccountID] as? NSNumber
        else { return false }
        return owner.uint32Value == getuid()
    }

    private static func isSecureItem(at url: URL, type: FileAttributeType, permissions: Int) -> Bool {
        guard
            isOwnedItem(at: url, type: type),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let actualPermissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return actualPermissions.intValue & 0o777 == permissions
    }

#if DEBUG
    static func assertSecurityRules() {
        assert(metadataIsSecure(type: .typeRegular, owner: getuid(), permissions: 0o600, expectedType: .typeRegular, expectedPermissions: 0o600))
        assert(!metadataIsSecure(type: .typeRegular, owner: getuid(), permissions: 0o644, expectedType: .typeRegular, expectedPermissions: 0o600))
        assert(!metadataIsSecure(type: .typeDirectory, owner: getuid(), permissions: 0o700, expectedType: .typeRegular, expectedPermissions: 0o600))
        assert(!metadataIsSecure(type: .typeRegular, owner: getuid() &+ 1, permissions: 0o600, expectedType: .typeRegular, expectedPermissions: 0o600))
    }

    private static func metadataIsSecure(
        type: FileAttributeType,
        owner: uid_t,
        permissions: Int,
        expectedType: FileAttributeType,
        expectedPermissions: Int
    ) -> Bool {
        type == expectedType && owner == getuid() && permissions & 0o777 == expectedPermissions
    }
#endif
}
