import Foundation
import UniformTypeIdentifiers

struct ShareExtensionContent: Equatable {
    let text: String
    let sourceURL: URL?

    var previewText: String {
        text.shareTrimmedNonEmpty ?? text
    }
}

enum ShareExtensionContentError: LocalizedError {
    case noTextContent

    var errorDescription: String? {
        switch self {
        case .noTextContent:
            return "Smithers can only receive shared text or URLs in this version."
        }
    }
}

struct ShareExtensionContentLoader {
    let context: NSExtensionContext?

    func load() async throws -> ShareExtensionContent {
        guard let providers = context?.shareItemProviders, !providers.isEmpty else {
            throw ShareExtensionContentError.noTextContent
        }

        if let urlContent = await loadFirstURL(from: providers) {
            return urlContent
        }
        if let textContent = await loadFirstText(from: providers) {
            return textContent
        }

        throw ShareExtensionContentError.noTextContent
    }

    private func loadFirstURL(from providers: [NSItemProvider]) async -> ShareExtensionContent? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let item = try? await Self.loadItem(provider, typeIdentifier: UTType.url.identifier),
                  let url = Self.url(from: item)
            else {
                continue
            }
            return ShareExtensionContent(text: url.absoluteString, sourceURL: url)
        }
        return nil
    }

    private func loadFirstText(from providers: [NSItemProvider]) async -> ShareExtensionContent? {
        let textTypes = [
            UTType.plainText.identifier,
            UTType.text.identifier,
        ]

        for type in textTypes {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
                guard let item = try? await Self.loadItem(provider, typeIdentifier: type),
                      let text = Self.text(from: item)?.shareTrimmedNonEmpty
                else {
                    continue
                }
                return ShareExtensionContent(text: text, sourceURL: URL(string: text))
            }
        }

        return nil
    }

    private static func loadItem(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let item else {
                    continuation.resume(throwing: ShareExtensionContentError.noTextContent)
                    return
                }
                continuation.resume(returning: item)
            }
        }
    }

    private static func url(from item: NSSecureCoding) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let text = text(from: item) {
            return URL(string: text)
        }
        return nil
    }

    private static func text(from item: NSSecureCoding) -> String? {
        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if let data = item as? NSData {
            return String(data: data as Data, encoding: .utf8)
        }
        if let url = item as? URL {
            return url.absoluteString
        }
        if let url = item as? NSURL {
            return (url as URL).absoluteString
        }
        return nil
    }
}

private extension NSExtensionContext {
    var shareItemProviders: [NSItemProvider] {
        inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
    }
}

extension String {
    var shareTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
