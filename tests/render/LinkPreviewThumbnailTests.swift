import AppKit
import Foundation
import Testing
@testable import ZephyrRender

@MainActor
@Suite struct LinkPreviewThumbnailTests {
    @Test func rejectsOversizedFilesBeforeThumbnailGeneration() async throws {
        try await withFixture { directory in
            let url = directory.appendingPathComponent("large.docx")
            try Data(repeating: 0, count: LinkPreviewThumbnailRenderer.fileSizeLimit + 1).write(to: url)

            do {
                _ = try await LinkPreviewThumbnailRenderer().render(url)
                Issue.record("Expected an oversized file to be rejected")
            } catch let error as LinkPreviewThumbnailRenderer.Failure {
                guard case .tooLarge = error else { Issue.record("Expected tooLarge failure"); return }
            } catch {
                Issue.record("Expected tooLarge failure, got \(error)")
            }
        }
    }

    @Test func rejectsDirectoriesBeforeThumbnailGeneration() async throws {
        try await withFixture { directory in
            do {
                _ = try await LinkPreviewThumbnailRenderer().render(directory)
                Issue.record("Expected a directory to be rejected")
            } catch let error as LinkPreviewThumbnailRenderer.Failure {
                guard case .unavailable = error else { Issue.record("Expected unavailable failure"); return }
            } catch {
                Issue.record("Expected unavailable failure, got \(error)")
            }
        }
    }

    @Test func cancelledTaskFailsWithoutStartingAProviderRequest() async {
        let url = URL(fileURLWithPath: "/missing-preview.docx")
        let task = Task { @MainActor () throws -> NSImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LinkPreviewThumbnailRenderer().render(url)
        }

        switch await task.result {
        case .failure(is CancellationError):
            break
        default:
            Issue.record("Expected cancellation before thumbnail generation")
        }
    }

    private func withFixture(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zephyr-thumbnail-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
