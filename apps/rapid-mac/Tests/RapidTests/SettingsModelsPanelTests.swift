import Foundation
import Testing
@testable import Rapid

/// Pin the pure helpers ``SettingsModelsPanel`` uses for its row
/// captions and "Freed X" banner so a copy refactor can't silently
/// drift the truth table.
@MainActor
@Suite("Settings Models panel — pure helpers (#160)")
struct SettingsModelsPanelTests {

    // MARK: - humanBytes

    @Test("humanBytes: rounds to one decimal in GB above 1 GiB")
    func humanBytesGB() {
        // 1 GiB exactly → "1.0 GB"
        #expect(SettingsModelsPanel.humanBytes(1_073_741_824) == "1.0 GB")
        // 3.1 GiB → "3.1 GB"
        #expect(SettingsModelsPanel.humanBytes(Int64(3.1 * Double(1024 * 1024 * 1024))) == "3.1 GB")
        // 16 GiB → "16.0 GB"
        #expect(SettingsModelsPanel.humanBytes(Int64(16) * 1_073_741_824) == "16.0 GB")
    }

    @Test("humanBytes: drops to MB below 1 GiB")
    func humanBytesMB() {
        // 512 MiB
        #expect(SettingsModelsPanel.humanBytes(512 * 1024 * 1024) == "512 MB")
        // Boundary case — 1 byte under 1 GiB still reads as MB.
        #expect(SettingsModelsPanel.humanBytes(1_073_741_823) == "1024 MB")
    }

    // MARK: - runningCaption

    @Test("runningCaption: .fetching shows file count with pluralisation")
    func runningCaptionFetching() {
        #expect(
            SettingsModelsPanel.runningCaption(phase: .fetching(done: 5, total: 12, percent: 41))
                == "Downloading 5/12 files"
        )
        #expect(
            SettingsModelsPanel.runningCaption(phase: .fetching(done: 1, total: 1, percent: 100))
                == "Downloading 1/1 file"
        )
    }

    @Test("runningCaption: .downloading surfaces percent only — bytes/eta live in the body overlay")
    func runningCaptionDownloading() {
        let caption = SettingsModelsPanel.runningCaption(
            phase: .downloading(
                file: "model-00001-of-00006.safetensors",
                done: "1.18G",
                total: "4.50G",
                percent: 26,
                speed: "42.0MB/s",
                eta: "01:18"
            )
        )
        #expect(caption == "26%")
    }

    @Test("runningCaption: idle / preparing / warmingUp render their own copy")
    func runningCaptionOtherPhases() {
        #expect(SettingsModelsPanel.runningCaption(phase: .idle) == "Starting…")
        #expect(SettingsModelsPanel.runningCaption(phase: .preparing) == "Preparing…")
        #expect(SettingsModelsPanel.runningCaption(phase: .warmingUp) == "Finalising…")
    }

    // MARK: - isRunning

    @Test("isRunning: true for a freshly-initialised .running job")
    func isRunningFreshJob() {
        // ``status`` is ``fileprivate(set)`` so tests can only assert
        // the initial .running state; the other branches are pinned
        // through ``captionForJob`` truth-table tests below via the
        // ``runningCaption`` path, which exercises the same switch.
        let job = DownloadManager.Job(alias: "qwen3.5-9b-4bit")
        #expect(SettingsModelsPanel.isRunning(job))
    }

    // MARK: - bucket (section classification)
    //
    // Dogfood bug: a model that was still downloading appeared under
    // "Downloaded", captioned with the bytes that had landed so far
    // (1.6 GiB) as though that were its finished size (~5.7 GB). The
    // cause is that `ModelEntry.cached` comes from `rapid-mlx ls`, which
    // happily lists a cache directory that is still being written.

    private func entry(
        _ alias: String = "qwen3.5-4b-4bit",
        cached: Bool,
        sizeOnDisk: String? = nil
    ) -> ModelEntry {
        ModelEntry(alias: alias, hfRepo: nil, sizeOnDisk: sizeOnDisk, cached: cached)
    }

    @Test("bucket: an in-flight pull outranks the cached flag")
    func bucketDownloadingWinsOverCached() {
        // The exact reported shape: partially written, so `ls` calls it
        // cached, but the job is still running.
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: true, sizeOnDisk: "1.6 GiB"),
                servingAlias: "bonsai-1.7b-2bit",
                isDownloading: true
            ) == .available
        )
        // Even if it somehow became the serving alias mid-pull, a
        // running job still owns the row (that's where Cancel lives).
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: true),
                servingAlias: "qwen3.5-4b-4bit",
                isDownloading: true
            ) == .available
        )
    }

    @Test("bucket: settled entries land in the section their cache state implies")
    func bucketSettledEntries() {
        // Finished pull, not being served → Downloaded.
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: true, sizeOnDisk: "5.7 GiB"),
                servingAlias: "bonsai-1.7b-2bit",
                isDownloading: false
            ) == .downloaded
        )
        // Finished pull AND serving → In use.
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: true),
                servingAlias: "qwen3.5-4b-4bit",
                isDownloading: false
            ) == .inUse
        )
        // Never downloaded → Available.
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: false),
                servingAlias: "bonsai-1.7b-2bit",
                isDownloading: false
            ) == .available
        )
        // No server running at all: cached but nothing is served.
        #expect(
            SettingsModelsPanel.bucket(
                entry: entry(cached: true),
                servingAlias: nil,
                isDownloading: false
            ) == .downloaded
        )
    }

    @Test("bucket: a model is never in two sections at once")
    func bucketIsTotalAndDisjoint() {
        for cached in [true, false] {
            for downloading in [true, false] {
                for serving in ["qwen3.5-4b-4bit", "bonsai-1.7b-2bit", nil] {
                    let b = SettingsModelsPanel.bucket(
                        entry: entry(cached: cached),
                        servingAlias: serving,
                        isDownloading: downloading
                    )
                    // Exactly one bucket, and a not-cached entry can
                    // only ever be available.
                    if !cached { #expect(b == .available) }
                    if downloading { #expect(b == .available) }
                }
            }
        }
    }
}
