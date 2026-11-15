// OP-3: a finger opens a sealed key, from a process with no entitlement.
//
//     swift scripts/spike-seal.swift
//
// Seals thirty-two random bytes to a Secure Enclave key in one process and
// unseals them in a second, which is the one that raises the Touch ID sheet.
// Prints "match" and nothing else when the bytes come back the same.
//
//     swift scripts/spike-seal.swift seal <dir>      the first half alone
//     swift scripts/spike-seal.swift unseal <dir>    the second half alone
//
// The halves exist apart so the bundle can be rebuilt and signed again
// between them.

import CryptoKit
import Foundation
import LocalAuthentication

let info = Data("com.meric.oripass.spike-seal".utf8)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func seal(in directory: URL) throws {
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet], &error
    ) else { fail("no access control: \(String(describing: error?.takeRetainedValue()))") }

    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    var sender = try HPKE.Sender(recipientKey: key.publicKey,
                                 ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
    let box = try sender.seal(secret)

    try key.dataRepresentation.write(to: directory.appendingPathComponent("key"))
    try sender.encapsulatedKey.write(to: directory.appendingPathComponent("encapsulated"))
    try box.write(to: directory.appendingPathComponent("box"))
    // The spike's only plain copy, so the second process has something to
    // compare with. The app keeps no such file.
    try secret.write(to: directory.appendingPathComponent("expected"))
}

func unseal(in directory: URL) throws {
    let context = LAContext()
    context.localizedReason = "unlock OriPass"
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: Data(contentsOf: directory.appendingPathComponent("key")),
        authenticationContext: context
    )
    var recipient = try HPKE.Recipient(
        privateKey: key, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
        encapsulatedKey: Data(contentsOf: directory.appendingPathComponent("encapsulated"))
    )
    let secret = try recipient.open(Data(contentsOf: directory.appendingPathComponent("box")))
    let expected = try Data(contentsOf: directory.appendingPathComponent("expected"))
    guard secret == expected else { fail("the bytes differ") }
    print("match")
}

let arguments = CommandLine.arguments
do {
    if arguments.count == 3, arguments[1] == "seal" {
        try seal(in: URL(fileURLWithPath: arguments[2]))
    } else if arguments.count == 3, arguments[1] == "unseal" {
        try unseal(in: URL(fileURLWithPath: arguments[2]))
    } else {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-spike-seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try seal(in: directory)

        let second = Process()
        second.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        second.arguments = [arguments[0], "unseal", directory.path]
        try second.run()
        second.waitUntilExit()
        exit(second.terminationStatus)
    }
} catch {
    fail("\(error)")
}
