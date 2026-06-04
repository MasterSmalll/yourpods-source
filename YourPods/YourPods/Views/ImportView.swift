import SwiftUI
import UniformTypeIdentifiers

/// Import/Export view for OPML subscriptions.
struct ImportView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var importError: String?
    @State private var importedCount = 0
    @State private var showResult = false
    @State private var showFileImporter = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)
                    
                    Button {
                        exportOPML()
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Label("Export OPML", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting || podcastManager.subscriptions.isEmpty)
                }
                
                if showResult {
                    Section {
                        if let error = importError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else {
                            Label("Imported \(importedCount) podcasts", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("Import / Export")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { importOPML(from: url) }
                case .failure(let error):
                    importError = error.localizedDescription
                    showResult = true
                }
            }
        }
    }
    
    private func importOPML(from url: URL) {
        isImporting = true
        importError = nil
        showResult = false
        
        Task {
            do {
                guard url.startAccessingSecurityScopedResource() else {
                    importError = "Cannot access file"
                    showResult = true
                    isImporting = false
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let data = try Data(contentsOf: url)
                let feedUrls = OPMLService.parseURLs(from: data)
                
                var added = 0
                for feedUrl in feedUrls {
                    do {
                        try await podcastManager.addSubscription(url: feedUrl)
                        added += 1
                    } catch {
                        // Skip individual failures
                    }
                }
                
                importedCount = added
                showResult = true
            } catch {
                importError = error.localizedDescription
                showResult = true
            }
            isImporting = false
        }
    }
    
    private func exportOPML() {
        isExporting = true
        let xml = OPMLService.export(podcasts: podcastManager.subscriptions)
        
        // Write to temporary file and share
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("yourpods_subscriptions.opml")
        try? xml.write(to: tempUrl, atomically: true, encoding: .utf8)
        
        #if os(iOS)
        // Share sheet
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first {
            let activityVC = UIActivityViewController(activityItems: [tempUrl], applicationActivities: nil)
            window.rootViewController?.present(activityVC, animated: true)
        }
        #endif
        
        isExporting = false
    }
}
