import CNIOOpenSSL
import Foundation
import Bits

/// Available cipher modes. Either `encrypt` or `decrypt`.
///
/// Used when calling `reset` on a `Cipher`.
public enum CipherMode: Int32 {
    /// Encrypts arbitrary data to encrypted ciphertext.
    case encrypt = 1

    /// Decrypts encrypted ciphertext back to its original value.
    case decrypt = 0
}

/// Wrapper to allow for safely working with a potentially-nil Data's byte buffer.
extension Optional where Wrapped == Data {
    // - note: It's iffy to try this with a mutable buffer, so an Optional version
    // of withMutableByteBuffer is not provided.
    func withByteBuffer<T>(_ closure: (BytesBufferPointer?) throws -> T) rethrows -> T {
        switch self {
        case .some(let data):
            return try data.withByteBuffer({ try closure($0) })
        case .none:
            return try closure(nil)
        }
    }
}

/// OpenSSLStreamCipher is a protocol representing a higher-level interface for managing various OpenSSL stream ciphers.
public protocol OpenSSLStreamCipher {
    /// Resets / initializes the cipher algorithm context. Must be called before calling update.
    /// See the default implementation extension on this protocol for more.
    func reset(key: LosslessDataConvertible, iv: LosslessDataConvertible?, mode: CipherMode) throws

    /// Encrypts or decrypts a chunk of data into the supplied buffer.
    /// See the default implementation extension on this protocol for more.
    func update(data: LosslessDataConvertible, into buffer: inout Data) throws

    /// Finalizes the encryption or decryption, appending any additional data into the supplied buffer.
    /// See the default implementation extension on this protocol for more.
    func finish(into buffer: inout Data) throws

    /// The OpenSSLCipherAlgorithm this stream cipher is interacting with
    var algorithm: OpenSSLCipherAlgorithm { get }

    /// The OpenSSL Cipher Stream Context
    var ctx: OpaquePointer { get }
}

extension OpenSSLStreamCipher {
    /// Resets / initializes the cipher algorithm context. This must be called once before calling `update(data:)`
    ///
    ///     let key: Data // 16-bytes
    ///     var aes128 = Cipher(algorithm: .aes128ecb)
    ///     try aes128.reset(key: key, mode: .encrypt)
    ///
    /// - parameters:
    ///     - key: Cipher key to use for the encryption or decryption.
    ///            This key must be an appropriate length for the cipher you are using. See `CipherAlgorithm.keySize`.
    ///     - iv: Optional initialization vector to use for the encryption or decryption.
    ///           The IV must be an appropriate length for the cipher you are using. See `CipherAlgorithm.ivSize`.
    ///     - mode: Determines whether this `Cipher` will encrypt or decrypt data.
    ///             This is set to `CipherModel.encrypt` by default.
    ///
    /// - throws: `CryptoError` if reset fails, data conversion fails, or key/iv lengths are not correct.
    public func reset(key: LosslessDataConvertible, iv: LosslessDataConvertible? = nil, mode: CipherMode = .encrypt) throws {
        let key = key.convertToData()
        let iv = iv?.convertToData()

        let keyLength = EVP_CIPHER_key_length(algorithm.c.convert())
        guard keyLength == key.count else {
            throw CryptoError(identifier: "cipherKeySize", reason: "Invalid cipher key length \(key.count) != \(keyLength).")
        }

        let ivLength = EVP_CIPHER_iv_length(algorithm.c.convert())
        guard (ivLength == 0 && (iv == nil || iv?.count == 0)) || (iv != nil && iv?.count == Int(ivLength)) else {
            throw CryptoError(identifier: "cipherIVSize", reason: "Invalid cipher IV length \(iv?.count ?? 0) != \(ivLength).")
        }

        guard key.withByteBuffer({ keyBuffer in
            iv.withByteBuffer { ivBuffer in
                EVP_CipherInit_ex(ctx.convert(), algorithm.c.convert(), nil, keyBuffer.baseAddress!, ivBuffer?.baseAddress, mode.rawValue)
            }
        }) == 1 else {
            throw CryptoError.openssl(identifier: "EVP_CipherInit_ex", reason: "Failed initializing cipher context.")
        }
    }

    /// Encrypts or decrypts a chunk of data into the supplied buffer.
    ///
    ///     let key: Data // 16-bytes
    ///     let aes128 = Cipher(algorithm: .aes128ecb)
    ///     try aes128.reset(key: key, mode: .encrypt)
    ///     var buffer = Data()
    ///     try aes128.update(data: "hello", into: &buffer)
    ///     try aes128.update(data: "world", into: &buffer)
    ///     print(buffer) // Partial ciphertext
    ///
    /// Note: You _must_ call `reset()` once before calling this method.
    ///
    /// - parameters:
    ///     - data: Message chunk to encrypt or decrypt.
    ///     - buffer: Mutable buffer to append newly encrypted or decrypted data to.
    /// - throws: `CryptoError` if update fails or data conversion fails.
    public func update(data: LosslessDataConvertible, into buffer: inout Data) throws {
        let input = data.convertToData()
        var chunk = Data(count: input.count + Int(algorithm.blockSize) - 1)
        var chunkLength: Int32 = 0

        guard chunk.withMutableByteBuffer({ chunkBuffer in
            input.withByteBuffer { inputBuffer in
                EVP_CipherUpdate(ctx.convert(), chunkBuffer.baseAddress!, &chunkLength, inputBuffer.baseAddress!, Int32(truncatingIfNeeded: inputBuffer.count))
            }
        }) == 1 else {
            throw CryptoError.openssl(identifier: "EVP_CipherUpdate", reason: "Failed updating cipher.")
        }
        buffer += chunk.prefix(upTo: Int(chunkLength))
    }

    /// Finalizes the encryption or decryption, appending any additional data into the supplied buffer.
    ///
    ///     let key: Data // 16-bytes
    ///     let aes128 = Cipher(algorithm: .aes128ecb)
    ///     try aes128.reset(key: key, mode: .encrypt)
    ///     var buffer = Data()
    ///     try aes128.update(data: "hello", into: &buffer)
    ///     try aes128.update(data: "world", into: &buffer)
    ///     try aes128.finish(into: &buffer)
    ///     print(buffer) // Completed ciphertext
    ///
    /// Note: You _must_ call `reset()` once and `update()` at least once before calling this method.
    ///
    /// - parameters:
    ///     - buffer: Mutable buffer to append any remaining encrypted or decrypted data to.
    /// - throws: `CryptoError` if finalization fails.
    public func finish(into buffer: inout Data) throws {
        var chunk = Data(count: Int(algorithm.blockSize))
        var chunkLength: Int32 = 0

        guard chunk.withMutableByteBuffer({ EVP_CipherFinal_ex(ctx.convert(), $0.baseAddress!, &chunkLength) }) == 1 else {
            throw CryptoError.openssl(identifier: "EVP_CipherFinal_ex", reason: "Failed finishing cipher.")
        }
        buffer += chunk.prefix(upTo: Int(chunkLength))
    }
}
