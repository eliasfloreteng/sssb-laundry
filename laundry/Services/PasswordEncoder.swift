import Foundation

enum PasswordEncoder {
    static func encode(password: String, salt: String) -> String {
        guard let saltValue = Int(salt) else { return password }
        return String(password.map { char in
            let charValue = Int(char.unicodeScalars.first!.value)
            let encoded = charValue ^ saltValue
            return Character(UnicodeScalar(encoded)!)
        })
    }
}
