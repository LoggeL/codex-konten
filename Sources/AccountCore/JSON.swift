import Foundation
enum J: Codable, Sendable {
    case object([String:J]), array([J]), string(String), number(Double), bool(Bool), null
    init(from d: Decoder) throws { let c = try d.singleValueContainer(); if c.decodeNil() { self = .null } else if let x = try? c.decode(Bool.self) { self = .bool(x) } else if let x = try? c.decode(Double.self) { self = .number(x) } else if let x = try? c.decode(String.self) { self = .string(x) } else if let x = try? c.decode([String:J].self) { self = .object(x) } else { self = .array(try c.decode([J].self)) } }
    func encode(to e: Encoder) throws { var c = e.singleValueContainer(); switch self { case .object(let x): try c.encode(x); case .array(let x): try c.encode(x); case .string(let x): try c.encode(x); case .number(let x): try c.encode(x); case .bool(let x): try c.encode(x); case .null: try c.encodeNil() } }
    subscript(_ key:String) -> J? { if case .object(let x) = self { return x[key] }; return nil }
    var string:String? { if case .string(let x) = self { return x }; return nil }
    var number:Double? { if case .number(let x) = self { return x }; return nil }
    var array:[J]? { if case .array(let x) = self { return x }; return nil }
    var object:[String:J]? { if case .object(let x) = self { return x }; return nil }
}
struct Identity: Sendable, Equatable {
    let accountID: String?
    let email: String?
    func matches(_ other:Identity) -> Bool {
        if let a = accountID, let b = other.accountID { return a == b }
        guard let a = email?.lowercased(), let b = other.email?.lowercased(), !a.isEmpty else { return false }
        return a == b
    }
    static func credential(_ data:Data) throws -> Identity {
        let auth = try JSONDecoder().decode(J.self, from:data)
        func claims(_ token:String?) -> J? { guard let parts = token?.split(separator:"."), parts.count > 1 else { return nil }; var part = String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/"); part += String(repeating:"=",count:(4-part.count%4)%4); guard let d = Data(base64Encoded:part) else { return nil }; return try? JSONDecoder().decode(J.self,from:d) }
        let id = claims(auth["tokens"]?["id_token"]?.string)
        let access = claims(auth["tokens"]?["access_token"]?.string)
        let account = auth["tokens"]?["account_id"]?.string ?? id?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string ?? access?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string
        let email = id?["email"]?.string ?? access?["email"]?.string
        guard account != nil || email != nil else { throw AccountError.message("Keine ChatGPT-Kontoidentität in der Dateianmeldung. API-Schlüssel und Schlüsselbund-Anmeldungen werden nicht umgeschaltet.") }
        return Identity(accountID:account,email:email)
    }
}
func safeMessage(_ error:Error) -> String {
    if error is CancellationError { return "Abgebrochen." }
    var s = error.localizedDescription
    for pattern in ["eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)?", "(?:sk-|rt_)[A-Za-z0-9_-]+", "(?i)Bearer\\s+[^\\s]+", "https?://[^\\s]+"] { s = s.replacingOccurrences(of:pattern,with:"[geschützt]",options:.regularExpression) }
    return String(s.prefix(800))
}
