//
//  EditorProjectTests.swift
//  CapsterTests
//

import Testing
import CoreMedia
import Foundation
@testable import Capster

struct EditorProjectTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func clip(_ sourceName: String, trimStart: Double = 0, trimEnd: Double, sourceDuration: Double? = nil) -> EditorClip {
        EditorClip(
            sourceURL: URL(fileURLWithPath: "/tmp/\(sourceName).mov"),
            sourceDuration: time(sourceDuration ?? trimEnd),
            trimStart: time(trimStart),
            trimEnd: time(trimEnd)
        )
    }

    // MARK: - Duration

    @Test func trimmedDurationIsTrimEndMinusTrimStart() {
        let clip = clip("a", trimStart: 2, trimEnd: 7)
        #expect(clip.trimmedDuration.seconds == 5)
    }

    @Test func totalDurationSumsEveryClipsTrimmedRange() {
        let project = EditorProject(
            clips: [clip("a", trimEnd: 5), clip("b", trimStart: 1, trimEnd: 4)],
            originalRecordingURL: URL(fileURLWithPath: "/tmp/original.mov")
        )
        #expect(project.totalDuration.seconds == 8)
    }

    // MARK: - Split

    @Test func splitInsideAClipProducesTwoClipsSharingTheSource() {
        var project = EditorProject(clips: [clip("a", trimEnd: 10)], originalRecordingURL: URL(fileURLWithPath: "/tmp/a.mov"))
        project.split(at: time(4))

        #expect(project.clips.count == 2)
        #expect(project.clips[0].sourceURL == project.clips[1].sourceURL)
        #expect(project.clips[0].trimStart.seconds == 0)
        #expect(project.clips[0].trimEnd.seconds == 4)
        #expect(project.clips[1].trimStart.seconds == 4)
        #expect(project.clips[1].trimEnd.seconds == 10)
        #expect(project.clips[0].id != project.clips[1].id)
    }

    @Test func splitAcrossMultipleClipsFindsTheRightOne() {
        var project = EditorProject(
            clips: [clip("a", trimEnd: 5), clip("b", trimEnd: 5)],
            originalRecordingURL: URL(fileURLWithPath: "/tmp/original.mov")
        )
        project.split(at: time(7))

        #expect(project.clips.count == 3)
        #expect(project.clips[1].sourceURL.lastPathComponent == "b.mov")
        #expect(project.clips[1].trimEnd.seconds == 2)
        #expect(project.clips[2].trimStart.seconds == 2)
    }

    @Test func splitAtAClipBoundaryIsANoOp() {
        var project = EditorProject(
            clips: [clip("a", trimEnd: 5), clip("b", trimEnd: 5)],
            originalRecordingURL: URL(fileURLWithPath: "/tmp/original.mov")
        )
        project.split(at: time(5))

        #expect(project.clips.count == 2)
    }

    @Test func splitPastTheEndOfTheTimelineIsANoOp() {
        var project = EditorProject(clips: [clip("a", trimEnd: 5)], originalRecordingURL: URL(fileURLWithPath: "/tmp/a.mov"))
        project.split(at: time(50))

        #expect(project.clips.count == 1)
    }

    // MARK: - Reorder

    @Test func moveClipReordersTheTimeline() {
        var project = EditorProject(
            clips: [clip("a", trimEnd: 1), clip("b", trimEnd: 1), clip("c", trimEnd: 1)],
            originalRecordingURL: URL(fileURLWithPath: "/tmp/original.mov")
        )
        let bID = project.clips[1].id
        project.moveClip(id: bID, to: 0)

        #expect(project.clips.map(\.sourceURL.lastPathComponent) == ["b.mov", "a.mov", "c.mov"])
    }

    @Test func moveClipWithUnknownIDIsANoOp() {
        var project = EditorProject(clips: [clip("a", trimEnd: 1)], originalRecordingURL: URL(fileURLWithPath: "/tmp/a.mov"))
        project.moveClip(id: UUID(), to: 0)

        #expect(project.clips.count == 1)
    }

    // MARK: - Remove

    @Test func removeClipDropsIt() {
        var project = EditorProject(
            clips: [clip("a", trimEnd: 1), clip("b", trimEnd: 1)],
            originalRecordingURL: URL(fileURLWithPath: "/tmp/original.mov")
        )
        let aID = project.clips[0].id
        project.removeClip(id: aID)

        #expect(project.clips.count == 1)
        #expect(project.clips[0].sourceURL.lastPathComponent == "b.mov")
    }
}
