//
//  EditorViewModel.swift
//  Capster
//

import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Drives the post-recording editor window: owns the timeline (`EditorProject`), the
/// `AVPlayer` previewing it, and undo/redo. Structural edits (trim commit, split, reorder,
/// add/remove clip) all go through `apply(_:)` so every one of them uniformly pushes undo
/// state and triggers a composition/player rebuild - no call site can forget one or the
/// other.
@MainActor
@Observable
final class EditorViewModel {

    private(set) var project: EditorProject
    let player = AVPlayer()
    let thumbnailCache = ThumbnailCache()

    private(set) var playheadTime: CMTime = .zero
    private(set) var isPlaying = false
    private(set) var isRebuildingPreview = false
    private(set) var loadError: String?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Whether `project` has unsaved changes relative to what's on disk in the `.capster`
    /// project file - tracked separately from the undo stack since undoing back to a
    /// previously-saved state should also clear it.
    private(set) var hasUnsavedChanges = false

    private var undoStack: [EditorProject] = []
    private var redoStack: [EditorProject] = []
    private var rebuildTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Capster", category: "EditorViewModel")

    private init(project: EditorProject) {
        self.project = project
        observePlayhead()
        rebuildPreview()
    }

    /// Loads the editor for `originalRecordingURL`: if a `.capster` project file already
    /// holds saved edits for it, resumes that timeline exactly as left off; otherwise
    /// probes the recording fresh as a single untrimmed clip. The async probing (reading
    /// the asset's duration) can't happen inside `init`, so callers await this factory
    /// instead of calling `init` directly.
    static func make(originalRecordingURL: URL) async -> EditorViewModel {
        let projectFileURL = CapsterProjectFile.url(for: originalRecordingURL)
        if let savedFile = CapsterProjectFile.read(from: projectFileURL), !savedFile.clips.isEmpty {
            return EditorViewModel(project: savedFile.makeEditorProject())
        }

        let clip = (try? await VideoCompositionService.makeClip(for: originalRecordingURL))
            ?? EditorClip(sourceURL: originalRecordingURL, sourceDuration: .zero)
        return EditorViewModel(project: EditorProject(clips: [clip], originalRecordingURL: originalRecordingURL))
    }

    /// Persists the current timeline to the `.capster` project file next to the original
    /// recording, so reopening it later (via `make(originalRecordingURL:)`) restores this
    /// exact edit state instead of starting over from the untouched recording.
    func save() {
        CapsterProjectFile.write(project, for: project.originalRecordingURL)
        hasUnsavedChanges = false
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Not explicitly removed - `[weak self]` means it becomes a no-op once this view
    /// model deallocates, and the observer itself is released along with `player` (which
    /// nothing outside this view model holds a reference to).
    private func observePlayhead() {
        _ = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            self?.playheadTime = time
        }
    }

    // MARK: - Editing

    /// Commits a trim on the clip with `id`, pushing undo state and rebuilding the
    /// preview. Callers update a local draft value while dragging and only call this on
    /// `.onEnded`, so intermediate drag positions never hit the undo stack.
    func trim(clipID: EditorClip.ID, trimStart: CMTime? = nil, trimEnd: CMTime? = nil) {
        apply { project in
            guard let index = project.clips.firstIndex(where: { $0.id == clipID }) else { return }
            if let trimStart { project.clips[index].trimStart = trimStart }
            if let trimEnd { project.clips[index].trimEnd = trimEnd }
        }
    }

    /// Splits the clip under the current playhead into two.
    func split() {
        apply { $0.split(at: playheadTime) }
    }

    func moveClip(id: EditorClip.ID, to destinationIndex: Int) {
        apply { $0.moveClip(id: id, to: destinationIndex) }
    }

    func removeClip(id: EditorClip.ID) {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        apply { $0.removeClip(id: id) }
        if !project.clips.contains(where: { $0.sourceURL == clip.sourceURL }) {
            thumbnailCache.evict(sourceURL: clip.sourceURL)
        }
    }

    /// Probes `url` and appends it to the timeline as a new, untrimmed clip.
    func addClip(from url: URL) async {
        do {
            let clip = try await VideoCompositionService.makeClip(for: url)
            apply { $0.clips.append(clip) }
        } catch {
            loadError = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
            logger.error("Failed to add clip \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        hasUnsavedChanges = true
        rebuildPreview()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        hasUnsavedChanges = true
        rebuildPreview()
    }

    /// Applies a structural mutation to `project`, pushing the prior state onto the undo
    /// stack, clearing redo, and rebuilding the preview - the single path every editing
    /// action goes through so none of that bookkeeping can be forgotten at a call site.
    private func apply(_ mutation: (inout EditorProject) -> Void) {
        let previous = project
        var updated = project
        mutation(&updated)
        guard updated != previous else { return }

        undoStack.append(previous)
        redoStack.removeAll()
        project = updated
        hasUnsavedChanges = true
        rebuildPreview()
    }

    // MARK: - Preview rebuilding

    /// Rebuilds the composition and swaps in a new `AVPlayerItem` - `AVPlayerItem` doesn't
    /// support hot-swapping tracks once playback has started, so every structural edit
    /// gets a fresh item rather than mutating the current one.
    private func rebuildPreview() {
        rebuildTask?.cancel()
        let currentProject = project
        let resumeTime = playheadTime
        isRebuildingPreview = true

        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await VideoCompositionService.makeComposition(from: currentProject)
                if Task.isCancelled { return }
                let item = AVPlayerItem(asset: result.composition)
                item.videoComposition = result.videoComposition
                player.replaceCurrentItem(with: item)
                seek(to: min(resumeTime, currentProject.totalDuration))
                loadError = nil
            } catch {
                logger.error("Failed to rebuild preview: \(error.localizedDescription, privacy: .public)")
                loadError = error.localizedDescription
            }
            isRebuildingPreview = false
        }
    }
}
