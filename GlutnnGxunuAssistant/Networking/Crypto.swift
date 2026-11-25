import Foundation
import CryptoKit
import Security

// MARK: - MD5（桂工登录用）
//
// Flutter 版 submitHexMd5 是**双重 MD5**：先对密码做一次 MD5 转
// 十六进制串，再对那个十六进制串做一次 MD5。不是单次 MD5。
// 用 CryptoKit 的 Insecure.MD5（标准实现）。

/// 单次 MD5，转小写十六进制串。
func md5Hex(_ string: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(string.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// 桂工登录密码：MD5(MD5(密码) 的十六进制串) 的十六进制串。
func gutPasswordHash(_ password: String) -> String {
    md5Hex(md5Hex(password))
}

// MARK: - RSA PKCS#1 v1.5（职师院正方 V9.0 登录用）
//
// 服务器 login_getPublicKey.html 返回的 modulus / exponent 都是
// **Base64** 串（不是十六进制）。加密后返回的也是 **Base64** 密文。
// 用 Security 框架的标准实现，不自己写大数运算。
//
// 关键步骤：Base64 解出 modulus/exponent 的原始字节 → 手工拼出
// DER 编码的 SubjectPublicKeyInfo → SecKeyCreateWithData 建 SecKey
// → SecKeyCreateEncryptedData(.rsaEncryptionPKCS1) 加密。

private enum DER {
    /// DER 长度编码：<128 用单字节，>=128 用长格式。
    static func length(_ count: Int) -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 {
            bytes.insert(UInt8(n & 0xff), at: 0)
            n >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    /// DER INTEGER：去掉前导零；最高位为 1 时前面补 0x00（保持正数）。
    static func integer(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 1 && bytes[0] == 0x00 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return Data([0x02]) + length(bytes.count) + Data(bytes)
    }

    /// DER SEQUENCE。
    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    /// DER BIT STRING（内容前加一个 0x00 表示未用位数为 0）。
    static func bitString(_ content: Data) -> Data {
        let body = Data([0x00]) + content
        return Data([0x03]) + length(body.count) + body
    }
}

/// 从 Base64 的 modulus/exponent 拼出 SubjectPublicKeyInfo 的 DER。
private func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
    // RSAPublicKey ::= SEQUENCE { modulus INTEGER, exponent INTEGER }
    let rsaKey = DER.sequence(DER.integer(modulus) + DER.integer(exponent))
    // AlgorithmIdentifier ::= SEQUENCE { OID rsaEncryption, NULL }
    // OID 1.2.840.113549.1.1.1 = 06 09 2A 86 48 86 F7 0D 01 01 01
    let oid = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
    let algorithm = DER.sequence(oid + Data([0x05, 0x00]))
    // SubjectPublicKeyInfo ::= SEQUENCE { algorithm, BIT STRING(rsaKey) }
    return DER.sequence(algorithm + DER.bitString(rsaKey))
}

/// 从 Base64 的 modulus/exponent 建 SecKey（1024 位 RSA 公钥）。
private func secKey(modulusBase64: String, exponentBase64: String) -> SecKey? {
    guard let modulus = Data(base64Encoded: modulusBase64),
          let exponent = Data(base64Encoded: exponentBase64) else {
        return nil
    }
    let der = rsaPublicKeyDER(modulus: modulus, exponent: exponent)
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: max(modulus.count * 8, 1024),
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
        return nil
    }
    return key
}

/// 用 Base64 的 modulus/exponent（V9.0 公钥接口返回的格式）加密明文，
/// 返回 Base64 密文。1024 位密钥 → 密文固定 128 字节。
/// 失败返回 nil。
func rsaEncryptPKCS1(plaintext: String, modulusBase64: String, exponentBase64: String) -> String? {
    guard let key = secKey(modulusBase64: modulusBase64, exponentBase64: exponentBase64) else {
        return nil
    }
    let plainData = Data(plaintext.utf8)
    var error: Unmanaged<CFError>?
    guard let cipher = SecKeyCreateEncryptedData(
        key,
        .rsaEncryptionPKCS1,
        plainData as CFData,
        &error
    ) else {
        return nil
    }
    return (cipher as Data).base64EncodedString()
}
