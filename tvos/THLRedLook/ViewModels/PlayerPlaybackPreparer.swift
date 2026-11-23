import Foundation
import AVFoundation

@MainActor
final class PlayerPlaybackPreparer {
    private let repository: NativeRepository
    private let store: LocalStore

    init(repository: NativeRepository = .shared, store: LocalStore = .shared) {
        self.repository = repository
        self.store = store
    }

    func prepareEpisode(
        drama: Drama,
        allEpisodes: [Episode],
        episodeIndex: Int,
        requestedQuality: Int,
        avoidURL: String,
        engine: PlaybackEngine
    ) async throws -> PreparedPlaybackResult {
        if drama.id.starts(with: "test_") {
            let quality = requestedQuality > 0 ? requestedQuality : 1080
            let testPlan = PlaybackPlan(url: "http://localhost/test.mp4", quality: quality, qualities: [1080, 720, 480])
            let asset = AVURLAsset(url: URL(string: testPlan.url)!)
            return PreparedPlaybackResult(plan: testPlan, playerItem: AVPlayerItem(asset: asset), decryptedURL: nil)
        }

        var currentDrama = drama
        var currentEpisodes = allEpisodes
        var episode = currentEpisodes.first { $0.number == episodeIndex }

        if episode?.raw == nil || HongguoSeriesIdentity.isRounded(currentDrama) {
            let detail = try await repository.loadDetail(drama: currentDrama, store: store)
            currentDrama = detail.drama
            if !detail.episodes.isEmpty { currentEpisodes = detail.episodes }
            episode = currentEpisodes.first { $0.number == episodeIndex }
        }

        guard let episode else {
            throw NSError(domain: "Player", code: -1, userInfo: [NSLocalizedDescriptionKey: "没有找到当前分集"])
        }

        if let localURL = DownloadService.shared.completedLocalURL(dramaId: currentDrama.id, episodeId: episode.id) {
            let localPlan = PlaybackPlan(url: localURL.absoluteString, quality: 1080, qualities: [1080], local: true)
            let item = engine == .mpv ? nil : AVPlayerItem(url: localURL)
            return PreparedPlaybackResult(plan: localPlan, playerItem: item, decryptedURL: nil, drama: currentDrama, episodes: currentEpisodes)
        }

        let resolved = try await repository.resolvePlayback(
            drama: currentDrama,
            episode: episode,
            episodeIndex: episodeIndex,
            quality: requestedQuality,
            avoidURL: avoidURL
        )

        guard let scheme = URL(string: resolved.url)?.scheme, ["https", "http", "file"].contains(scheme) else {
            throw NSError(domain: "Player", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效播放地址"])
        }

        let useMPV = engine == .mpv || (engine == .automatic && resolved.decryptionKey.isEmpty)
        if useMPV {
            let requiresMPV = engine == .mpv ? true : await HLSCompatibilityProbe.requiresMPV(resolved)
            if requiresMPV {
                return PreparedPlaybackResult(plan: resolved, playerItem: nil, decryptedURL: nil, drama: currentDrama, episodes: currentEpisodes)
            }
        }
        let prepared = try await PlaybackAssetFactory.prepare(resolved)
        let item = AVPlayerItem(asset: prepared.asset)
        item.preferredForwardBufferDuration = 3
        return PreparedPlaybackResult(plan: resolved, playerItem: item, decryptedURL: prepared.decryptedURL, drama: currentDrama, episodes: currentEpisodes)
    }
}
