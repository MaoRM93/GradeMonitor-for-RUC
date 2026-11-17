// 开发机签名密钥专用钥匙串助手。
// 用 stdin/stdout 传递密钥数据，避免把私钥放进 shell 参数、日志或临时文件。
import Foundation
import LocalAuthentication
import Security

let usage = "Usage: keychain_secret <read|write|delete> <service> <account>"
guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(64)
}
let operation = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
let account = CommandLine.arguments[3]

func baseQuery() -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword,
     kSecAttrService: service,
     kSecAttrAccount: account]
}

/// 控制/发布私钥必须要求当前 macOS 用户显式确认；普通应用凭据仍使用标准
/// 钥匙串策略，避免每次成绩轮询触发系统认证窗口。
// 只有两枚签名私钥需要更高保护。开发者登录令牌虽共用 service，不能套用
// userPresence；否则覆盖升级后设置页读取令牌会反复触发系统授权窗口。
func requiresUserPresence() -> Bool {
    service == "GradeMonitorSigning" &&
    (account == "control-signing-ed25519-v2" || account == "release-signing-ed25519-v2")
}

func fail(_ status: OSStatus) -> Never {
    let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(Int32(status == errSecSuccess ? 1 : status))
}

switch operation {
case "read", "read-raw":
    var query = baseQuery()
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    // read-raw 只在一次性迁移中读取尚未受保护的旧条目；正常运行一律
    // 走 read，从而要求 Touch ID/系统密码。
    if requiresUserPresence() && operation == "read" {
        let context = LAContext()
        context.localizedReason = "允许 GradeMonitor 使用开发者签名密钥"
        query[kSecUseAuthenticationContext] = context
    }
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { fail(status) }
    FileHandle.standardOutput.write(data)
case "write":
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { FileHandle.standardError.write(Data("empty secret\n".utf8)); exit(65) }
    let query = baseQuery()
    SecItemDelete(query as CFDictionary)
    var attributes = query
    attributes[kSecValueData] = data
    if requiresUserPresence() {
        var error: Unmanaged<CFError>?
        if let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) {
            attributes[kSecAttrAccessControl] = access
        }
    }
    var status = SecItemAdd(attributes as CFDictionary, nil)
    // 当前开发机上的 ad-hoc 工具无数据保护钥匙串 entitlement（-34018），
    // 无法创建 userPresence 项。经开发者明确授权后，回退为当前 macOS 用户
    // 的传统登录钥匙串项：不写文件、不进入项目或安装包，且仅在签发时读取。
    if status == errSecMissingEntitlement && requiresUserPresence() {
        attributes.removeValue(forKey: kSecAttrAccessControl)
        status = SecItemAdd(attributes as CFDictionary, nil)
    }
    guard status == errSecSuccess else { fail(status) }
case "delete":
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail(status) }
default:
    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(64)
}
