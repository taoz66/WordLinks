import AppKit
import SwiftUI

/// First-party brand artwork is bundled so choosing an AI service never loads a remote image.
struct AIServiceLogo: View {
    let kind: AIServiceKind

    var body: some View {
        Group {
            switch kind {
            case .chatGPT:
                if let image = AIServiceLogoResource.chatGPT {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                }
            case .appleIntelligence:
                if #available(macOS 15.0, *),
                   NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil) != nil {
                    Image(systemName: "apple.intelligence")
                        .font(.system(size: 32, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                } else if let image = AIServiceLogoResource.appleIntelligence {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            case .customAPI, .localModel:
                Image(systemName: "network")
                    .font(.system(size: 32, weight: .regular))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 44, height: 44)
    }
}

private enum AIServiceLogoResource {
    static let chatGPT = image(named: "chatgpt", extension: "pdf")
    static let appleIntelligence = image(named: "apple-intelligence", extension: "png")

    private static func image(named name: String, extension fileExtension: String) -> NSImage? {
        // Prefer the installed SwiftPM bundle so moving Wordlinks.app does not
        // depend on a resource bundle left in a developer's build directory.
        let installedBundle = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("ReadingToolDaily_ReadingToolDaily.bundle"))
        }
        let resources = installedBundle ?? Bundle.module
        guard let url = resources.url(forResource: name, withExtension: fileExtension,
                                      subdirectory: "AIServiceLogos") else { return nil }
        return NSImage(contentsOf: url)
    }
}
