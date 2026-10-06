import Foundation

public enum TwitchTokenValidation {
    public enum Failure: Error { case rejected, malformed }
    public static func check(_ data: Data, username: String) throws {
        struct Claims: Decodable {
            let login: String?
            let user_id: String?
            let scopes: [String]
            let expires_in: Int
        }
        guard data.count <= 8192 else { throw Failure.malformed }
        let claims: Claims
        do { claims = try JSONDecoder().decode(Claims.self, from: data) }
        catch { throw Failure.malformed }
        guard claims.login == username, claims.user_id?.isEmpty == false,
              claims.scopes.contains("chat:read"), claims.expires_in > 0 else { throw Failure.rejected }
    }
}
