import Foundation

struct ConfigProfile: Identifiable, Hashable {
    let name: String
    let url: URL
    let createdAt: Date

    var id: String { url.path }
}
