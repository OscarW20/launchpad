#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Turns whatever a drop or a paste carries into files the composer can attach. A file from Finder arrives as a file URL;
/// a screenshot from the corner thumbnail, a browser image or an image on the pasteboard arrives as a promised file or as
/// raw image data. Each is saved as a file in a temporary folder (the chat copies it into its Inbox when you send).
enum AttachmentIngest {
    static let types: [UTType] = [.fileURL, .image]

    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for provider in providers {
            if let url = await url(from: provider) { out.append(url) }
        }
        return out
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), let url = await fileURL(provider) { return url }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return await image(provider) }
        return nil
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { continuation.resume(returning: url) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private static func image(_ provider: NSItemProvider) async -> URL? {
        let base = baseName(provider.suggestedName)
        // A file (a promised one, or one the sender wrote): it's only ours for the length of the callback, so copy it now.
        let copied: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                continuation.resume(returning: url.flatMap { save(copyOf: $0, named: base) })
            }
        }
        if let copied { return copied }
        // Raw image data (the corner thumbnail, a browser image, the pasteboard): written out as a PNG.
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data.flatMap { save(data: $0, named: base) })
            }
        }
    }

    private static func baseName(_ suggested: String?) -> String {
        let name = (suggested.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }) ?? ""
        if !name.isEmpty { return name }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(f.string(from: Date()))"
    }

    private static func folder() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchpadDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        return dir
    }

    /// A copy of a file handed to us, keeping its type. A TIFF (what the pasteboard usually holds) becomes a PNG.
    private static func save(copyOf url: URL, named base: String) -> URL? {
        let ext = url.pathExtension.lowercased()
        if ext == "tiff" || ext == "tif" || ext.isEmpty, let data = try? Data(contentsOf: url) { return save(data: data, named: base) }
        guard let dir = folder() else { return nil }
        let target = dir.appendingPathComponent("\(base).\(ext)")
        do { try FileManager.default.copyItem(at: url, to: target) } catch { return nil }
        return target
    }

    private static func save(data: Data, named base: String) -> URL? {
        guard let dir = folder() else { return nil }
        let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
        let target = dir.appendingPathComponent("\(base).png")
        do { try png.write(to: target, options: .atomic) } catch { return nil }
        return target
    }
}
#endif
