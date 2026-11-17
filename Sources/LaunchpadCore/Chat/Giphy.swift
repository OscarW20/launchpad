import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GIF search through GIPHY. The API key is in the Keychain (`SecretStore`, account `giphy.API_KEY`); it is put
/// in the request URL only, so never log that URL.
public enum GiphySearch {
    public static let keyAccount = "giphy.API_KEY"
    public static let endpoint = "https://api.giphy.com/v1/gifs/search"

    public struct Result: Identifiable, Hashable, Sendable {
        public var id: String
        public var gif: GifRef
    }

    public typealias Fetch = @Sendable (URL) async throws -> Data

    public static func key(from secrets: SecretStore) -> String? {
        let k = secrets.read(keyAccount).value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty ?? true) ? nil : k
    }

    /// The search URL, or nil for an empty query or key.
    public static func url(query: String, key: String, limit: Int = 24, rating: String = "g") -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !key.isEmpty, var c = URLComponents(string: endpoint) else { return nil }
        c.queryItems = [
            URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "q", value: String(q.prefix(100))),
            URLQueryItem(name: "limit", value: "\(max(1, min(limit, 50)))"), URLQueryItem(name: "rating", value: rating),
        ]
        return c.url
    }

    /// Reads GIPHY's search response: `data[].images.fixed_height` (and `fixed_width_small` as the preview).
    public static func parse(_ data: Data) -> [Result] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let images = item["images"] as? [String: Any],
                  let full = images["fixed_height"] as? [String: Any], let u = full["url"] as? String else { return nil }
            let small = (images["fixed_width_small"] as? [String: Any])?["url"] as? String
            func num(_ v: Any?) -> Double? { (v as? String).flatMap(Double.init) ?? (v as? Double) ?? (v as? Int).map(Double.init) }
            let title = (item["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return Result(id: id, gif: GifRef(url: u, width: num(full["width"]) ?? 200, height: num(full["height"]) ?? 200,
                                              title: title, preview: small ?? u))
        }
    }

    public static let urlSessionFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Searches, or returns [] with no key, no network or a bad answer.
    public static func search(_ query: String, secrets: SecretStore, limit: Int = 24, fetch: Fetch = urlSessionFetch) async -> [Result] {
        guard let key = key(from: secrets), let url = url(query: query, key: key, limit: limit),
              let data = try? await fetch(url) else { return [] }
        return parse(data)
    }
}
