import Foundation
import CryptoKit

// ============================================================
//  PulseBar 授权码工具（离线签名，不需要任何服务器）
// ============================================================
//
//  原理：用 Ed25519 数字签名。
//    · 私钥只有你自己有（存在 ~/.pulsebar/license-private.key，千万别泄露、别丢）
//    · 公钥内嵌在每个 App 里，用来本地验签
//    · 用户拿到的是一串授权码，App 离线验证，**永远不需要联网**
//
//  用法：
//    license keygen                      # 生成密钥对（只做一次）
//    license issue <昵称> [产品] [天数]    # 给某个支持者发一枚授权码
//    license verify <授权码>              # 验证一枚授权码是否有效
//    license info                        # 显示公钥（要贴进 App 里的那串）
//
//  产品代号：默认 "*" 表示"全部作品通用"
//  天数：0 或省略 = 永久有效
//
// ============================================================

let keyDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pulsebar")
let privURL = keyDir.appendingPathComponent("license-private.key")
let pubURL = keyDir.appendingPathComponent("license-public.key")

// MARK: - 工具函数

func b64u(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func unb64u(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 命令

let args = Array(CommandLine.arguments.dropFirst())

guard let cmd = args.first else {
    print("""
    用法:
      license keygen                        生成密钥对（只做一次）
      license issue <昵称> [产品] [天数]      发一枚授权码
      license verify <授权码>                验证授权码
      license info                          显示公钥
    """)
    exit(0)
}

switch cmd {

case "keygen":
    try? FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: privURL.path) {
        print("私钥已存在：\(privURL.path)")
        print("（不想覆盖就先手动备份走。重新生成会让**所有已发出的授权码全部失效**！）")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    try! b64u(key.rawRepresentation).write(to: privURL, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
    try! b64u(key.publicKey.rawRepresentation).write(to: pubURL, atomically: true, encoding: .utf8)

    print("✅ 密钥对已生成")
    print("   私钥（务必备份、绝不外传）: \(privURL.path)")
    print("   公钥（要贴进 App 里）      : \(pubURL.path)")
    print("")
    print("公钥内容（嵌到 App 的 License.publicKeyBase64 里）：")
    print(b64u(key.publicKey.rawRepresentation))
    print("")
    print("⚠️ 私钥丢了 = 以后再也发不出新授权码；私钥泄露 = 别人能伪造授权码。")
    print("   建议把它复制一份到你的密码管理器里。")

case "info":
    guard let pub = try? String(contentsOf: pubURL, encoding: .utf8) else {
        fail("找不到公钥，先跑 `license keygen`")
    }
    print(pub.trimmingCharacters(in: .whitespacesAndNewlines))

case "issue":
    let name = args.count > 1 ? args[1] : "匿名支持者"
    let product = args.count > 2 ? args[2] : "*"
    let days = args.count > 3 ? (Int(args[3]) ?? 0) : 0

    guard let privStr = try? String(contentsOf: privURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let privData = unb64u(privStr),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) else {
        fail("读不到私钥或私钥损坏：\(privURL.path)")
    }

    let expiry: Int
    if days > 0 {
        expiry = Int(Date().timeIntervalSince1970 / 86400) + days
    } else {
        expiry = 0   // 永久
    }

    let payload: [String: Any] = ["v": 1, "p": product, "n": name, "e": expiry]
    let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let sig = try! priv.signature(for: payloadData)

    let code = "PB1." + b64u(payloadData) + "." + b64u(sig)
    print(code)

case "verify":
    guard args.count > 1 else { fail("用法: license verify <授权码>") }
    let code = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pubStr = try? String(contentsOf: pubURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let pubData = unb64u(pubStr),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
        fail("读不到公钥，先跑 `license keygen`")
    }
    let parts = code.split(separator: ".")
    guard parts.count == 3, parts[0] == "PB1",
          let pData = unb64u(String(parts[1])), let sData = unb64u(String(parts[2])) else {
        fail("❌ 授权码格式不对")
    }
    guard pub.isValidSignature(sData, for: pData) else {
        fail("❌ 签名验证失败（这是伪造或被改过的授权码）")
    }
    let json = try! JSONSerialization.jsonObject(with: pData) as! [String: Any]
    let expiry = json["e"] as? Int ?? 0
    let expText: String
    if expiry == 0 {
        expText = "永久"
    } else {
        let d = Date(timeIntervalSince1970: TimeInterval(expiry) * 86400)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        expText = f.string(from: d)
    }
    print("✅ 有效")
    print("   授权给  : \(json["n"] ?? "?")")
    print("   适用产品: \(json["p"] ?? "?")")
    print("   有效期  : \(expText)")

default:
    fail("未知命令: \(cmd)")
}
