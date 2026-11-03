import Foundation

// MARK: - NanoKVM AES-256-CBC Password Encryption (CryptoJS / aes-everywhere compatible)

public enum NanoKVMCrypto {
    /// Shared obfuscation key defined in NanoKVM `server/utils/encrypt.go` and `web/src/lib/encrypt.ts`.
    public static let secretKey = "nanokvm-sipeed-2024"

    /// Encrypts a plaintext string using OpenSSL EVP_BytesToKey (MD5) + AES-256-CBC + PKCS#7 padding,
    /// prefixed with `"Salted__"` + 8-byte salt, Base64-encoded, and URL percent-encoded.
    public static func encryptPassword(
        _ plaintext: String,
        passphrase: String = secretKey,
        salt: [UInt8]? = nil
    ) -> String {
        let saltBytes: [UInt8]
        if let salt, salt.count == 8 {
            saltBytes = salt
        } else {
            saltBytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }

        let (key, iv) = deriveKeyAndIV(passphrase: Array(passphrase.utf8), salt: saltBytes)
        let padded = pkcs7Pad(Array(plaintext.utf8), blockSize: 16)
        let encrypted = aes256CBCEncrypt(padded, key: key, iv: iv)

        var payload: [UInt8] = Array("Salted__".utf8)
        payload.append(contentsOf: saltBytes)
        payload.append(contentsOf: encrypted)

        let base64 = Data(payload).base64EncodedString()
        return urlEncodeComponent(base64)
    }

    /// Decrypts a URL-encoded Base64 `"Salted__"` AES-256-CBC ciphertext produced by NanoKVM / CryptoJS.
    public static func decryptPassword(
        _ encoded: String,
        passphrase: String = secretKey
    ) -> String? {
        guard !encoded.isEmpty else { return "" }
        let unescaped = urlDecodeQueryComponent(encoded)
        guard let rawData = Data(base64Encoded: unescaped) else { return nil }
        let raw = Array(rawData)
        let header = Array("Salted__".utf8)
        guard raw.count >= 16, Array(raw[0..<8]) == header else { return nil }

        let salt = Array(raw[8..<16])
        let ciphertext = Array(raw[16...])
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }

        let (key, iv) = deriveKeyAndIV(passphrase: Array(passphrase.utf8), salt: salt)
        let decrypted = aes256CBCDecrypt(ciphertext, key: key, iv: iv)
        guard let unpadded = pkcs7Unpad(decrypted, blockSize: 16) else { return nil }
        return String(bytes: unpadded, encoding: .utf8)
    }

    /// Builds a form-urlencoded login payload accepted by both PiKVM/GLKVM (`user`/`passwd`)
    /// and NanoKVM (`Username`/`Password`).
    public static func loginForm(username: String, password: String, otp: String = "") -> String {
        let encrypted = encryptPassword(password)
        return KVMRequest.form([
            "user": username,
            "passwd": password + otp,
            "Username": username,
            "Password": encrypted
        ])
    }

    /// Builds a JSON login payload for `POST /api/auth/login` on NanoKVM.
    public static func loginJSON(username: String, password: String) -> Data {
        let payload: [String: String] = [
            "username": username,
            "password": encryptPassword(password)
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Inspects the JSON response from `POST /api/auth/login` to distinguish NanoKVM (`code`/`msg`/`data`)
    /// from PiKVM/GLKVM (`ok`/`result`).
    public static func parseLoginResponse(_ data: Data) -> (isNanoKVM: Bool, ok: Bool, token: String?, error: String?) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (isNanoKVM: false, ok: true, token: nil, error: nil)
        }
        if let code = object["code"] as? Int {
            let ok = (code == 0)
            let dataObj = object["data"] as? [String: Any]
            let token = dataObj?["token"] as? String
            let msg = object["msg"] as? String
            return (
                isNanoKVM: true,
                ok: ok,
                token: token,
                error: ok ? nil : (msg ?? "The NanoKVM device rejected the sign-in.")
            )
        }
        if let ok = object["ok"] as? Bool {
            let resultObj = object["result"] as? [String: Any]
            let token = (resultObj?["token"] as? String) ?? (resultObj?["auth_token"] as? String)
            let errMsg = (resultObj?["error_msg"] as? String)
                ?? (resultObj?["message"] as? String)
                ?? (resultObj?["error"] as? String)
            return (
                isNanoKVM: false,
                ok: ok,
                token: token,
                error: ok ? nil : (errMsg ?? "The device rejected the sign-in.")
            )
        }
        return (isNanoKVM: false, ok: true, token: nil, error: nil)
    }

    /// Extracts the first complete JPEG image (`FFD8` ... `FFD9`) from a NanoKVM `/api/stream/mjpeg` buffer.
    public static func extractFirstMJPEGFrame(_ data: Data) -> Data? {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        var startIndex: Int?
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 {
                startIndex = i
                break
            }
        }
        guard let start = startIndex else { return nil }
        for j in (start + 2)..<(bytes.count - 1) {
            if bytes[j] == 0xFF && bytes[j + 1] == 0xD9 {
                return Data(bytes[start...(j + 1)])
            }
        }
        return nil
    }

    private static func urlEncodeComponent(_ string: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func urlDecodeQueryComponent(_ string: String) -> String {
        let plusReplaced = string.replacingOccurrences(of: "+", with: " ")
        return plusReplaced.removingPercentEncoding ?? plusReplaced
    }

    // MARK: OpenSSL EVP_BytesToKey (MD5)

    public static func deriveKeyAndIV(passphrase: [UInt8], salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        var salted: [UInt8] = []
        salted.reserveCapacity(48)
        var dI: [UInt8] = []
        while salted.count < 48 {
            var input: [UInt8] = []
            input.reserveCapacity(dI.count + passphrase.count + salt.count)
            input.append(contentsOf: dI)
            input.append(contentsOf: passphrase)
            input.append(contentsOf: salt)
            dI = md5(input)
            salted.append(contentsOf: dI)
        }
        return (Array(salted[0..<32]), Array(salted[32..<48]))
    }

    private static func pkcs7Pad(_ data: [UInt8], blockSize: Int) -> [UInt8] {
        let padLen = blockSize - (data.count % blockSize)
        return data + [UInt8](repeating: UInt8(padLen), count: padLen)
    }

    private static func pkcs7Unpad(_ data: [UInt8], blockSize: Int) -> [UInt8]? {
        guard !data.isEmpty, data.count % blockSize == 0, let last = data.last else { return nil }
        let padLen = Int(last)
        guard padLen >= 1 && padLen <= blockSize && padLen <= data.count else { return nil }
        for i in (data.count - padLen)..<data.count {
            if data[i] != last { return nil }
        }
        return Array(data[0..<(data.count - padLen)])
    }

    // MARK: Pure Swift RFC 1321 MD5

    public static func md5(_ message: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [
            7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
            5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
            4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
            6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21
        ]
        let k: [UInt32] = [
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
            0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
            0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
            0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
            0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
            0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
            0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
            0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
            0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
        ]

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        var msg = message
        let bitLen = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            msg.append(UInt8(truncatingIfNeeded: bitLen >> UInt64(shift)))
        }

        func leftRotate(_ x: UInt32, _ c: UInt32) -> UInt32 {
            (x << c) | (x >> (32 - c))
        }

        var m = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(msg[j])
                    | (UInt32(msg[j + 1]) << 8)
                    | (UInt32(msg[j + 2]) << 16)
                    | (UInt32(msg[j + 3]) << 24)
            }

            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                let f: UInt32
                let g: Int
                if i < 16 {
                    f = (b & c) | ((~b) & d)
                    g = i
                } else if i < 32 {
                    f = (d & b) | ((~d) & c)
                    g = (5 * i + 1) % 16
                } else if i < 48 {
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                } else {
                    f = c ^ (b | (~d))
                    g = (7 * i) % 16
                }
                let temp = d
                d = c
                c = b
                b = b &+ leftRotate(a &+ f &+ k[i] &+ m[g], s[i])
                a = temp
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var digest: [UInt8] = []
        digest.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            digest.append(UInt8(word & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 24) & 0xff))
        }
        return digest
    }

    // MARK: Pure Swift FIPS-197 AES-256-CBC

    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16
    ]

    private static let invSbox: [UInt8] = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d
    ]

    private static let rcon: [UInt8] = [
        0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
    ]

    private static func expandKey256(_ key: [UInt8]) -> [UInt8] {
        var w = [UInt8](repeating: 0, count: 240)
        for i in 0..<32 { w[i] = key[i] }
        var bytesGenerated = 32
        var rconIteration = 1
        var temp = [UInt8](repeating: 0, count: 4)

        while bytesGenerated < 240 {
            for i in 0..<4 { temp[i] = w[bytesGenerated - 4 + i] }
            if bytesGenerated % 32 == 0 {
                let t = temp[0]
                temp[0] = sbox[Int(temp[1])] ^ rcon[rconIteration]
                temp[1] = sbox[Int(temp[2])]
                temp[2] = sbox[Int(temp[3])]
                temp[3] = sbox[Int(t)]
                rconIteration += 1
            } else if bytesGenerated % 32 == 16 {
                for i in 0..<4 { temp[i] = sbox[Int(temp[i])] }
            }
            for i in 0..<4 {
                w[bytesGenerated] = w[bytesGenerated - 32] ^ temp[i]
                bytesGenerated += 1
            }
        }
        return w
    }

    private static func gmul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var p: UInt8 = 0
        var aa = a
        var bb = b
        for _ in 0..<8 {
            if (bb & 1) != 0 { p ^= aa }
            let hiBit = (aa & 0x80) != 0
            aa <<= 1
            if hiBit { aa ^= 0x1b }
            bb >>= 1
        }
        return p
    }

    private static func encryptBlock(_ input: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var s = input
        for i in 0..<16 { s[i] ^= roundKeys[i] }

        for round in 1...14 {
            for i in 0..<16 { s[i] = sbox[Int(s[i])] }

            let t1 = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t1
            let t2 = s[2]; let t6 = s[6]; s[2] = s[10]; s[6] = s[14]; s[10] = t2; s[14] = t6
            let t3 = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t3

            if round < 14 {
                for col in 0..<4 {
                    let idx = col * 4
                    let a0 = s[idx], a1 = s[idx + 1], a2 = s[idx + 2], a3 = s[idx + 3]
                    s[idx]     = gmul(a0, 2) ^ gmul(a1, 3) ^ a2 ^ a3
                    s[idx + 1] = a0 ^ gmul(a1, 2) ^ gmul(a2, 3) ^ a3
                    s[idx + 2] = a0 ^ a1 ^ gmul(a2, 2) ^ gmul(a3, 3)
                    s[idx + 3] = gmul(a0, 3) ^ a1 ^ a2 ^ gmul(a3, 2)
                }
            }

            let rkOffset = round * 16
            for i in 0..<16 { s[i] ^= roundKeys[rkOffset + i] }
        }
        return s
    }

    private static func decryptBlock(_ input: [UInt8], roundKeys: [UInt8]) -> [UInt8] {
        var s = input
        for i in 0..<16 { s[i] ^= roundKeys[14 * 16 + i] }

        for round in stride(from: 13, through: 0, by: -1) {
            let t13 = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t13
            let t2 = s[2]; let t6 = s[6]; s[2] = s[10]; s[6] = s[14]; s[10] = t2; s[14] = t6
            let t3 = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t3

            for i in 0..<16 { s[i] = invSbox[Int(s[i])] }

            let rkOffset = round * 16
            for i in 0..<16 { s[i] ^= roundKeys[rkOffset + i] }

            if round > 0 {
                for col in 0..<4 {
                    let idx = col * 4
                    let a0 = s[idx], a1 = s[idx + 1], a2 = s[idx + 2], a3 = s[idx + 3]
                    s[idx]     = gmul(a0, 0x0e) ^ gmul(a1, 0x0b) ^ gmul(a2, 0x0d) ^ gmul(a3, 0x09)
                    s[idx + 1] = gmul(a0, 0x09) ^ gmul(a1, 0x0e) ^ gmul(a2, 0x0b) ^ gmul(a3, 0x0d)
                    s[idx + 2] = gmul(a0, 0x0d) ^ gmul(a1, 0x09) ^ gmul(a2, 0x0e) ^ gmul(a3, 0x0b)
                    s[idx + 3] = gmul(a0, 0x0b) ^ gmul(a1, 0x0d) ^ gmul(a2, 0x09) ^ gmul(a3, 0x0e)
                }
            }
        }
        return s
    }

    private static func aes256CBCEncrypt(_ paddedPlaintext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let roundKeys = expandKey256(key)
        var out = [UInt8](repeating: 0, count: paddedPlaintext.count)
        var prev = iv
        for offset in stride(from: 0, to: paddedPlaintext.count, by: 16) {
            var block = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { block[i] = paddedPlaintext[offset + i] ^ prev[i] }
            let enc = encryptBlock(block, roundKeys: roundKeys)
            for i in 0..<16 { out[offset + i] = enc[i] }
            prev = enc
        }
        return out
    }

    private static func aes256CBCDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let roundKeys = expandKey256(key)
        var out = [UInt8](repeating: 0, count: ciphertext.count)
        var prev = iv
        for offset in stride(from: 0, to: ciphertext.count, by: 16) {
            let block = Array(ciphertext[offset..<(offset + 16)])
            let dec = decryptBlock(block, roundKeys: roundKeys)
            for i in 0..<16 { out[offset + i] = dec[i] ^ prev[i] }
            prev = block
        }
        return out
    }
}

// MARK: - NanoKVM WebRTC Signaling (`/api/stream/h264`)

public struct NanoKVMSignaling {
    public enum Action: Equatable {
        case send(String)
        case createOffer(stunServer: String?)
        case answer(String)
        case candidate(Int, String)
    }

    public private(set) var negotiationStarted = false
    public private(set) var remoteDescriptionSet = false
    public private(set) var useLegacyEvents = false
    private var pendingRemoteCandidates: [(Int, String)] = []

    public init() {}

    public mutating func reset() {
        negotiationStarted = false
        remoteDescriptionSet = false
        useLegacyEvents = false
        pendingRemoteCandidates.removeAll()
    }

    /// Triggered if the NanoKVM server did not emit `"ice-servers"` on connect (legacy NanoKVM firmware).
    public mutating func fallbackOfferIfNeeded() -> [Action] {
        guard !negotiationStarted else { return [] }
        negotiationStarted = true
        useLegacyEvents = true
        return [.createOffer(stunServer: nil)]
    }

    public func offer(_ sdp: String) -> Action {
        let desc: [String: String] = ["type": "offer", "sdp": sdp]
        let descData = (try? JSONSerialization.data(withJSONObject: desc)) ?? Data()
        let descStr = String(decoding: descData, as: UTF8.self)
        return .send(Self.encodeEnvelope(event: useLegacyEvents ? "offer" : "video-offer", data: descStr))
    }

    public func localCandidate(line: Int, sdp: String) -> Action {
        let cand: [String: Any] = [
            "candidate": sdp,
            "sdpMid": "0",
            "sdpMLineIndex": line
        ]
        let candData = (try? JSONSerialization.data(withJSONObject: cand)) ?? Data()
        let candStr = String(decoding: candData, as: UTF8.self)
        return .send(Self.encodeEnvelope(event: useLegacyEvents ? "candidate" : "video-candidate", data: candStr))
    }

    public func heartbeat() -> Action {
        .send(Self.encodeEnvelope(event: "heartbeat", data: ""))
    }

    public mutating func receive(_ data: Data) throws -> [Action] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else {
            return []
        }
        let payloadString = object["data"] as? String ?? ""

        switch event {
        case "ice-servers":
            guard !negotiationStarted else { return [] }
            negotiationStarted = true
            useLegacyEvents = false
            var stunURL: String?
            if let payloadData = payloadString.data(using: .utf8),
               let servers = (try? JSONSerialization.jsonObject(with: payloadData)) as? [[String: Any]] {
                for server in servers {
                    if let urls = server["urls"] as? [String], let first = urls.first(where: { $0.hasPrefix("stun:") }) {
                        stunURL = first
                        break
                    } else if let url = server["urls"] as? String, url.hasPrefix("stun:") {
                        stunURL = url
                        break
                    }
                }
            }
            return [.createOffer(stunServer: stunURL)]

        case "video-answer", "answer":
            guard let payloadData = payloadString.data(using: .utf8),
                  let answerObj = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
                  let sdp = answerObj["sdp"] as? String, !sdp.isEmpty else {
                return []
            }
            remoteDescriptionSet = true
            var actions: [Action] = [.answer(sdp)]
            for (line, cand) in pendingRemoteCandidates {
                actions.append(.candidate(line, cand))
            }
            pendingRemoteCandidates.removeAll()
            return actions

        case "video-candidate", "candidate":
            guard let payloadData = payloadString.data(using: .utf8),
                  let candObj = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
                  let cand = candObj["candidate"] as? String, !cand.isEmpty else {
                return []
            }
            let line = (candObj["sdpMLineIndex"] as? Int) ?? 0
            if remoteDescriptionSet {
                return [.candidate(line, cand)]
            } else {
                pendingRemoteCandidates.append((line, cand))
                return []
            }

        case "heartbeat":
            return []

        default:
            return []
        }
    }

    private static func encodeEnvelope(event: String, data: String) -> String {
        let dict: [String: String] = ["event": event, "data": data]
        guard let raw = try? JSONSerialization.data(withJSONObject: dict) else {
            return "{\"event\":\"\(event)\",\"data\":\"\"}"
        }
        return String(decoding: raw, as: UTF8.self)
    }
}

// MARK: - NanoKVM HID Input Protocol (`/api/ws`)

public enum NanoKVMHID {
    public static let heartbeatEvent: UInt8 = 0
    public static let keyboardEvent: UInt8 = 1
    public static let mouseEvent: UInt8 = 2

    public static let heartbeat: [UInt8] = [heartbeatEvent]

    public static let modifierMap: [String: UInt8] = [
        "ControlLeft":  1 << 0,
        "ShiftLeft":    1 << 1,
        "AltLeft":      1 << 2,
        "MetaLeft":     1 << 3,
        "ControlRight": 1 << 4,
        "ShiftRight":   1 << 5,
        "AltRight":     1 << 6,
        "MetaRight":    1 << 7
    ]

    /// Maps DOM `KeyboardEvent.code` names (used throughout Overlook) to USB HID Usage IDs (`web/src/lib/keymap.ts`).
    public static let keycodeMap: [String: UInt8] = {
        var map: [String: UInt8] = [
            "KeyA": 0x04, "KeyB": 0x05, "KeyC": 0x06, "KeyD": 0x07,
            "KeyE": 0x08, "KeyF": 0x09, "KeyG": 0x0a, "KeyH": 0x0b,
            "KeyI": 0x0c, "KeyJ": 0x0d, "KeyK": 0x0e, "KeyL": 0x0f,
            "KeyM": 0x10, "KeyN": 0x11, "KeyO": 0x12, "KeyP": 0x13,
            "KeyQ": 0x14, "KeyR": 0x15, "KeyS": 0x16, "KeyT": 0x17,
            "KeyU": 0x18, "KeyV": 0x19, "KeyW": 0x1a, "KeyX": 0x1b,
            "KeyY": 0x1c, "KeyZ": 0x1d,

            "Digit1": 0x1e, "Digit2": 0x1f, "Digit3": 0x20, "Digit4": 0x21,
            "Digit5": 0x22, "Digit6": 0x23, "Digit7": 0x24, "Digit8": 0x25,
            "Digit9": 0x26, "Digit0": 0x27,

            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2a, "Tab": 0x2b,
            "Space": 0x2c, "Minus": 0x2d, "Equal": 0x2e, "BracketLeft": 0x2f,
            "BracketRight": 0x30, "Backslash": 0x31, "IntlHash": 0x32,
            "Semicolon": 0x33, "Quote": 0x34, "Backquote": 0x35,
            "Comma": 0x36, "Period": 0x37, "Slash": 0x38, "CapsLock": 0x39,

            "F1": 0x3a, "F2": 0x3b, "F3": 0x3c, "F4": 0x3d,
            "F5": 0x3e, "F6": 0x3f, "F7": 0x40, "F8": 0x41,
            "F9": 0x42, "F10": 0x43, "F11": 0x44, "F12": 0x45,

            "PrintScreen": 0x46, "ScrollLock": 0x47, "Pause": 0x48,
            "Insert": 0x49, "Home": 0x4a, "PageUp": 0x4b,
            "Delete": 0x4c, "End": 0x4d, "PageDown": 0x4e,

            "ArrowRight": 0x4f, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,

            "NumLock": 0x53, "NumpadDivide": 0x54, "NumpadMultiply": 0x55,
            "NumpadSubtract": 0x56, "NumpadAdd": 0x57, "NumpadEnter": 0x58,
            "Numpad1": 0x59, "Numpad2": 0x5a, "Numpad3": 0x5b,
            "Numpad4": 0x5c, "Numpad5": 0x5d, "Numpad6": 0x5e,
            "Numpad7": 0x5f, "Numpad8": 0x60, "Numpad9": 0x61,
            "Numpad0": 0x62, "NumpadDecimal": 0x63,

            "IntlBackslash": 0x64, "ContextMenu": 0x65, "Power": 0x66, "NumpadEqual": 0x67,

            "F13": 0x68, "F14": 0x69, "F15": 0x6a, "F16": 0x6b,
            "F17": 0x6c, "F18": 0x6d, "F19": 0x6e, "F20": 0x6f,
            "F21": 0x70, "F22": 0x71, "F23": 0x72, "F24": 0x73,

            "Help": 0x75, "AudioVolumeMute": 0x7f, "AudioVolumeUp": 0x80, "AudioVolumeDown": 0x81,
            "IntlRo": 0x87, "KanaMode": 0x88, "IntlYen": 0x89, "Convert": 0x8a, "NonConvert": 0x8b
        ]
        return map
    }()

    public static func mouseButtonBit(_ name: String) -> UInt8 {
        switch name {
        case "left": return 1 << 0
        case "right": return 1 << 1
        case "middle": return 1 << 2
        case "down", "back": return 1 << 3
        case "up", "forward": return 1 << 4
        default: return 0
        }
    }
}

public struct NanoKVMKeyboardState: Sendable {
    public private(set) var modifier: UInt8 = 0
    public private(set) var pressedKeys: [String] = []

    public init() {}

    public mutating func keyDown(_ code: String) -> [UInt8]? {
        if let bit = NanoKVMHID.modifierMap[code] {
            modifier |= bit
            return buildFrame()
        }
        guard NanoKVMHID.keycodeMap[code] != nil else { return nil }
        if !pressedKeys.contains(code), pressedKeys.count < 6 {
            pressedKeys.append(code)
        }
        return buildFrame()
    }

    public mutating func keyUp(_ code: String) -> [UInt8]? {
        if let bit = NanoKVMHID.modifierMap[code] {
            modifier &= ~bit
            return buildFrame()
        }
        guard NanoKVMHID.keycodeMap[code] != nil else { return nil }
        pressedKeys.removeAll { $0 == code }
        return buildFrame()
    }

    public mutating func reset() -> [UInt8] {
        modifier = 0
        pressedKeys.removeAll()
        return buildFrame()
    }

    /// 9-byte WebSocket payload: `[0x01, modifier, 0x00, key0, key1, key2, key3, key4, key5]`.
    public func buildFrame() -> [UInt8] {
        var frame: [UInt8] = [NanoKVMHID.keyboardEvent, modifier, 0x00, 0, 0, 0, 0, 0, 0]
        for (index, keyName) in pressedKeys.prefix(6).enumerated() {
            if let keycode = NanoKVMHID.keycodeMap[keyName] {
                frame[3 + index] = keycode
            }
        }
        return frame
    }
}

public struct NanoKVMMouseState: Sendable {
    public private(set) var buttons: UInt8 = 0
    public private(set) var lastX: UInt16 = 0x4000
    public private(set) var lastY: UInt16 = 0x4000

    public init() {}

    public mutating func button(_ name: String, pressed: Bool, isAbsolute: Bool) -> [UInt8]? {
        let bit = NanoKVMHID.mouseButtonBit(name)
        guard bit != 0 else { return nil }
        if pressed {
            buttons |= bit
        } else {
            buttons &= ~bit
        }
        return isAbsolute
            ? buildAbsoluteFrame(x: lastX, y: lastY, wheel: 0)
            : buildRelativeFrame(dx: 0, dy: 0, wheel: 0)
    }

    /// Builds a 7-byte absolute mouse frame from normalized coordinates in `0.0...1.0`.
    /// NanoKVM maps `[0.0, 1.0]` to `0x0001...0x7fff` (`1...32767`) in little-endian order.
    public mutating func moveAbsolute(normalizedX: Double, normalizedY: Double) -> [UInt8] {
        let clampedX = max(0.0, min(1.0, normalizedX))
        let clampedY = max(0.0, min(1.0, normalizedY))
        let rawX = UInt16(min(0x7fff, max(0x0001, Int(floor(Double(0x7fff) * clampedX)) + 1)))
        let rawY = UInt16(min(0x7fff, max(0x0001, Int(floor(Double(0x7fff) * clampedY)) + 1)))
        lastX = rawX
        lastY = rawY
        return buildAbsoluteFrame(x: rawX, y: rawY, wheel: 0)
    }

    /// Converts KVMD signed coordinates (`-32767...32767`) into NanoKVM's `1...32767` little-endian report.
    public mutating func moveAbsolute(kvmdX: Int, kvmdY: Int) -> [UInt8] {
        let nx = (Double(max(-32767, min(32767, kvmdX))) + 32767.0) / 65534.0
        let ny = (Double(max(-32767, min(32767, kvmdY))) + 32767.0) / 65534.0
        return moveAbsolute(normalizedX: nx, normalizedY: ny)
    }

    /// Chunks relative movement into 5-byte frames `[0x02, buttons, dx, dy, 0]`.
    public func moveRelative(dx: Int, dy: Int) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var remX = dx
        var remY = dy
        while remX != 0 || remY != 0 {
            let stepX = max(-127, min(127, remX))
            let stepY = max(-127, min(127, remY))
            frames.append(buildRelativeFrame(dx: stepX, dy: stepY, wheel: 0))
            remX -= stepX
            remY -= stepY
        }
        return frames
    }

    public func wheel(dy: Int, isAbsolute: Bool) -> [UInt8] {
        let clampedWheel = max(-127, min(127, dy))
        return isAbsolute
            ? buildAbsoluteFrame(x: lastX, y: lastY, wheel: clampedWheel)
            : buildRelativeFrame(dx: 0, dy: 0, wheel: clampedWheel)
    }

    public mutating func reset(isAbsolute: Bool) -> [UInt8] {
        buttons = 0
        return isAbsolute
            ? buildAbsoluteFrame(x: lastX, y: lastY, wheel: 0)
            : buildRelativeFrame(dx: 0, dy: 0, wheel: 0)
    }

    public func buildAbsoluteFrame(x: UInt16, y: UInt16, wheel: Int) -> [UInt8] {
        let w = UInt8(bitPattern: Int8(clamping: max(-127, min(127, wheel))))
        return [
            NanoKVMHID.mouseEvent,
            buttons,
            UInt8(x & 0xff),
            UInt8((x >> 8) & 0xff),
            UInt8(y & 0xff),
            UInt8((y >> 8) & 0xff),
            w
        ]
    }

    public func buildRelativeFrame(dx: Int, dy: Int, wheel: Int) -> [UInt8] {
        let bx = UInt8(bitPattern: Int8(clamping: max(-127, min(127, dx))))
        let by = UInt8(bitPattern: Int8(clamping: max(-127, min(127, dy))))
        let bw = UInt8(bitPattern: Int8(clamping: max(-127, min(127, wheel))))
        return [NanoKVMHID.mouseEvent, buttons, bx, by, bw]
    }
}

// MARK: - NanoKVM REST API Wire Models (`server/proto/*`)

public struct NanoKVMResponse<DataType: Decodable>: Decodable {
    public let code: Int
    public let msg: String?
    public let data: DataType?
}

public struct NanoKVMEmptyData: Decodable, Sendable {
    public init() {}
}

public struct NanoKVMIP: Decodable, Hashable, Sendable {
    public let name: String?
    public let addr: String?
    public let version: String?
    public let type: String?
}

public struct NanoKVMInfoRsp: Decodable, Hashable, Sendable {
    public let ips: [NanoKVMIP]?
    public let mdns: String?
    public let image: String?
    public let application: String?
    public let deviceKey: String?
}

public struct NanoKVMHardwareRsp: Decodable, Hashable, Sendable {
    public let version: String?
}

public struct NanoKVMGpioRsp: Decodable, Hashable, Sendable {
    public let pwr: Bool?
    public let hdd: Bool?
}

public struct NanoKVMHdmiStateRsp: Decodable, Hashable, Sendable {
    public let enabled: Bool?
    public let signal: Bool?
    public let idleTimeout: Int?
}

public struct NanoKVMMouseJigglerRsp: Decodable, Hashable, Sendable {
    public let enabled: Bool?
    public let mode: String?
}

public struct NanoKVMHidModeRsp: Decodable, Hashable, Sendable {
    public let mode: String?
}

public struct NanoKVMKeyboardLedStatusRsp: Decodable, Hashable, Sendable {
    public let numLock: Bool?
    public let capsLock: Bool?
    public let scrollLock: Bool?
    public let known: Bool?
    public let updatedAt: String?
}

public struct NanoKVMMediaItem: Decodable, Hashable, Sendable {
    public let type: String?
    public let rel: String?
    public let name: String?
    public let size: UInt64?
    public let fs: String?
    public let browsable: Bool?
    public let attached: Bool?
}

public struct NanoKVMMediaRsp: Decodable, Hashable, Sendable {
    public let media: [NanoKVMMediaItem]?
}

public struct NanoKVMMediaStateRsp: Decodable, Hashable, Sendable {
    public let state: String?
    public let type: String?
    public let rel: String?
    public let hidOnly: Bool?
    public let cdrom: Bool?
}

public struct NanoKVMImagesRsp: Decodable, Hashable, Sendable {
    public let files: [String]?
}

public struct NanoKVMMountedImageRsp: Decodable, Hashable, Sendable {
    public let file: String?
}

public struct NanoKVMCdRomRsp: Decodable, Hashable, Sendable {
    public let cdrom: Int64?
}

public struct NanoKVMWifiRsp: Decodable, Hashable, Sendable {
    public let supported: Bool?
    public let apMode: Bool?
    public let connected: Bool?
    public let ssid: String?
}

public enum NanoKVMMapper {
    public static func pasteLanguage(forKeymap keymap: String?) -> String {
        guard let km = keymap?.lowercased() else { return "" }
        if km.hasPrefix("de") { return "de" }
        if km.hasPrefix("fr") { return "fr" }
        return ""
    }

    public static func mapAtxState(from gpio: NanoKVMGpioRsp) -> KVMAtxState {
        let leds = KVMAtxState.LEDs(hdd: gpio.hdd ?? false, power: gpio.pwr ?? false)
        return KVMAtxState(busy: false, enabled: true, leds: leds)
    }

    public static func mapSystemInfo(info: NanoKVMInfoRsp, hardwareVersion: String?) -> KVMSystemInfo {
        let hwModel = hardwareVersion.map { "Sipeed NanoKVM (\($0))" } ?? "Sipeed NanoKVM Cube"
        let json: [String: Any] = [
            "hw": [
                "platform": [
                    "base": hwModel,
                    "model": hwModel,
                    "serial": info.deviceKey ?? "",
                    "type": "nanokvm"
                ]
            ],
            "system": [
                "kvmd": [
                    "version": "NanoKVM \(info.application ?? "1.0")"
                ],
                "streamer": [
                    "app": "libkvm",
                    "version": info.image ?? ""
                ],
                "kernel": [
                    "system": "Linux",
                    "release": info.image ?? "SG2002",
                    "machine": "riscv64"
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let decoded = try? JSONDecoder().decode(KVMSystemInfo.self, from: data) {
            return decoded
        }
        return KVMSystemInfo(hw: nil, system: nil)
    }

    public static func mapHidState(
        leds: NanoKVMKeyboardLedStatusRsp?,
        jiggler: NanoKVMMouseJigglerRsp?,
        isAbsoluteMouse: Bool
    ) -> KVMHidState {
        let json: [String: Any] = [
            "busy": false,
            "connected": true,
            "enabled": true,
            "online": true,
            "jiggler": [
                "active": jiggler?.enabled ?? false,
                "enabled": jiggler?.enabled ?? false,
                "interval": 60.0
            ],
            "keyboard": [
                "online": true,
                "leds": [
                    "caps": leds?.capsLock ?? false,
                    "num": leds?.numLock ?? false,
                    "scroll": leds?.scrollLock ?? false
                ],
                "outputs": [
                    "active": "usb",
                    "available": ["usb"]
                ]
            ],
            "mouse": [
                "online": true,
                "absolute": isAbsoluteMouse,
                "outputs": [
                    "active": isAbsoluteMouse ? "usb" : "usb_rel",
                    "available": ["usb", "usb_rel"]
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONDecoder().decode(KVMHidState.self, from: data))!
    }

    public static func mapMsdState(media: NanoKVMMediaRsp?, state: NanoKVMMediaStateRsp?) -> KVMMsdState {
        var imagesDict: [String: [String: Any]] = [:]
        var mountedName: String?
        var mountedSize: UInt64 = 0
        for item in media?.media ?? [] where (item.type ?? "image") == "image" {
            let key = item.rel ?? item.name ?? ""
            guard !key.isEmpty else { continue }
            let sz = item.size ?? 0
            imagesDict[key] = [
                "size": sz,
                "complete": true,
                "in_storage": true,
                "removable": true
            ]
            if item.attached == true {
                mountedName = key
                mountedSize = sz
            }
        }
        if mountedName == nil, let rel = state?.rel, !rel.isEmpty {
            mountedName = rel
        }
        let connected = (state?.state == "image" || state?.state == "partition" || mountedName != nil)
        let cdrom = state?.cdrom ?? (mountedName?.lowercased().hasSuffix(".iso") ?? true)
        var driveDict: [String: Any] = [
            "connected": connected,
            "cdrom": cdrom,
            "rw": !cdrom
        ]
        if let mountedName {
            driveDict["image"] = ["name": mountedName, "size": mountedSize]
        }
        let json: [String: Any] = [
            "enabled": !(state?.hidOnly ?? false),
            "online": true,
            "busy": false,
            "drive": driveDict,
            "storage": [
                "size": 0,
                "free": 0,
                "uploading": false,
                "downloading": false,
                "images": imagesDict
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONDecoder().decode(KVMMsdState.self, from: data))!
    }
}
