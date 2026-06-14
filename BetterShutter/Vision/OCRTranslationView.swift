import SwiftUI
@preconcurrency import Translation

/// On-device translation of recognized OCR text (macshot parity). Uses Apple's Translation framework,
/// which only vends a session through SwiftUI's `.translationTask`, so this small view is hosted from
/// the AppKit OCR window. Source language is auto-detected; the target is the device language.
@available(macOS 15.0, *)
struct OCRTranslationView: View {
    let sourceText: String
    let onDone: () -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var translated: String = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation").font(.headline)
            ScrollView {
                Text(failed ? "Translation unavailable. The language pack may need downloading in System Settings."
                     : (translated.isEmpty ? "Translating…" : translated))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translated, forType: .string)
                }
                .disabled(translated.isEmpty)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440, height: 320)
        .translationTask(configuration) { session in
            do {
                translated = try await session.translate(sourceText).targetText
            } catch {
                failed = true
            }
        }
        .onAppear {
            // nil source/target → auto-detect the source, translate to the device language.
            configuration = TranslationSession.Configuration()
        }
    }
}
