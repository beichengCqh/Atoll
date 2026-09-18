import CryptoKit
import Foundation

private enum KeyToolError: LocalizedError {
    case invalidArguments
    case invalidPrivateKey
    case invalidSignature
    case outputAlreadyExists(String)
    case unableToCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return """
            Usage: sparkle_key_tool.swift generate <output-directory>
                   sparkle_key_tool.swift public <private-key-file>
                   sparkle_key_tool.swift sign <private-key-file> <file>
                   sparkle_key_tool.swift verify <public-key-base64> <file> <signature-base64>
            """
        case .invalidSignature:
            return "The EdDSA signature does not match the file for the given public key."
        case .invalidPrivateKey:
            return "The private key must be a Base64-encoded 32-byte Ed25519 seed."
        case let .outputAlreadyExists(path):
            return "Refusing to overwrite existing key material at \(path)."
        case let .unableToCreateFile(path):
            return "Unable to create key material at \(path)."
        }
    }
}

/// 读取 Sparkle 格式的私钥：Base64 编码的 32 字节 Ed25519 种子，与 `sign_update --ed-key-file` 读取的格式一致。
private func decodePrivateKey(at path: String) throws -> Curve25519.Signing.PrivateKey {
    let encoded = try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
        throw KeyToolError.invalidPrivateKey
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
}

/// 在目标目录生成一对 Sparkle EdDSA 密钥，只向标准输出打印公钥。
/// 已存在同名文件时拒绝执行，防止覆盖掉已经写进 Info.plist 的那把密钥。
private func generateKeys(in outputDirectory: String) throws {
    let directoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directoryURL.path
    )

    let privateKeyURL = directoryURL.appendingPathComponent("sparkle_private_key")
    let publicKeyURL = directoryURL.appendingPathComponent("sparkle_public_key.txt")
    for outputURL in [privateKeyURL, publicKeyURL] where FileManager.default.fileExists(atPath: outputURL.path) {
        throw KeyToolError.outputAlreadyExists(outputURL.path)
    }

    let privateKey = Curve25519.Signing.PrivateKey()
    let privateSeed = privateKey.rawRepresentation.base64EncodedString()
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()

    // 创建文件时直接带上 0600 权限，私钥从落盘那一刻起就只有属主可读
    guard FileManager.default.createFile(
        atPath: privateKeyURL.path,
        contents: Data(privateSeed.utf8),
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw KeyToolError.unableToCreateFile(privateKeyURL.path)
    }
    try publicKey.write(to: publicKeyURL, atomically: true, encoding: .utf8)

    print(publicKey)
}

/// 由私钥推导公钥，CI 用它核对私钥与 Info.plist 里的 SUPublicEDKey 是否成对。
private func printPublicKey(from privateKeyPath: String) throws {
    let privateKey = try decodePrivateKey(at: privateKeyPath)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
}

/// 对文件整体做 Ed25519 签名并打印 Base64 签名，格式与 appcast 里的 sparkle:edSignature 相同。
private func signFile(privateKeyPath: String, filePath: String) throws {
    let privateKey = try decodePrivateKey(at: privateKeyPath)
    let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
    print(try privateKey.signature(for: data).base64EncodedString())
}

/// 用 App 内置的公钥独立校验更新包签名，模拟客户端 Sparkle 收到更新时的那一步检查。
private func verifyFile(publicKeyBase64: String, filePath: String, signatureBase64: String) throws {
    guard let keyData = Data(base64Encoded: publicKeyBase64), keyData.count == 32,
          let signature = Data(base64Encoded: signatureBase64) else {
        throw KeyToolError.invalidSignature
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
    guard publicKey.isValidSignature(signature, for: data) else {
        throw KeyToolError.invalidSignature
    }
    print("OK")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch (arguments.first, arguments.count) {
    case ("generate", 2):
        try generateKeys(in: arguments[1])
    case ("public", 2):
        try printPublicKey(from: arguments[1])
    case ("sign", 3):
        try signFile(privateKeyPath: arguments[1], filePath: arguments[2])
    case ("verify", 4):
        try verifyFile(publicKeyBase64: arguments[1], filePath: arguments[2], signatureBase64: arguments[3])
    default:
        throw KeyToolError.invalidArguments
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
