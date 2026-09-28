// Checks a Sparkle update signature the way installed copies of the app check an update: against
// the public key the app trusts (SUPublicEDKey in App/Info.plist). release.sh uses it to check a
// key it's given in a file before the long build.
//
//   xcrun swift scripts/verify-update-signature.swift <public key> <file> <signature>
//
// The key and the signature are base64, as Sparkle writes them. Exits 1 when the signature isn't
// the file's by that key's private half, and 2 when the arguments can't be read.
import CryptoKit
import Foundation

func stop(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("verify-update-signature: \(message)\n".utf8))
    exit(status)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else {
    stop("usage: verify-update-signature.swift <public key> <file> <signature>", status: 2)
}
guard let keyData = Data(base64Encoded: arguments[0]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { stop("the public key isn't a base64 Ed25519 key", status: 2) }
guard let file = FileManager.default.contents(atPath: arguments[1]) else {
    stop("can't read \(arguments[1])", status: 2)
}
guard let signature = Data(base64Encoded: arguments[2]) else {
    stop("the signature isn't base64", status: 2)
}
guard key.isValidSignature(signature, for: file) else {
    stop("the signature doesn't verify with the public key", status: 1)
}
