import Foundation
import Photos
import CryptoKit
import UIKit
import AVFoundation

/// 사진·영상 지문 계산 (모두 기기 안에서, 네트워크 사용 안 함)
enum Fingerprint {
    /// 64비트 차이 해시(dHash): 9x8 흑백으로 줄여 옆 칸과 밝기 비교
    static func dHash(_ cg: CGImage) -> UInt64? {
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bits: UInt64 = 0
        for y in 0..<h { for x in 0..<8 {
            bits <<= 1
            if px[y * w + x] > px[y * w + x + 1] { bits |= 1 }
        } }
        return bits
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// 작은 썸네일로 dHash (동기 — 백그라운드에서 호출)
    static func photoHash(_ asset: PHAsset) -> UInt64? {
        let o = PHImageRequestOptions()
        o.isSynchronous = true
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = false
        var out: UInt64?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 64, height: 64), contentMode: .aspectFill, options: o) { img, _ in
            if let cg = img?.cgImage { out = dHash(cg) }
        }
        return out
    }

    /// 원본 리소스 전체의 SHA-256. 기기에 원본이 없으면(iCloud 전용) nil
    static func sha256(_ asset: PHAsset) async -> String? {
        let res = PHAssetResource.assetResources(for: asset)
        let pick = res.first { $0.type == .photo || $0.type == .video } ?? res.first
        guard let r = pick else { return nil }
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = false
        return await withCheckedContinuation { cont in
            var hasher = SHA256()
            PHAssetResourceManager.default().requestData(for: r, options: o, dataReceivedHandler: { chunk in
                hasher.update(data: chunk)
            }, completionHandler: { err in
                if err != nil { cont.resume(returning: nil); return }
                let d = hasher.finalize()
                cont.resume(returning: d.map { String(format: "%02x", $0) }.joined())
            })
        }
    }

    /// 영상 여러 시점(25·50·75%)의 프레임 지문
    static func videoFrames(_ asset: PHAsset) async -> [UInt64]? {
        let o = PHVideoRequestOptions()
        o.isNetworkAccessAllowed = false
        o.deliveryMode = .fastFormat
        let av: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: o) { a, _, _ in cont.resume(returning: a) }
        }
        guard let av else { return nil }
        let gen = AVAssetImageGenerator(asset: av)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 64, height: 64)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var out: [UInt64] = []
        for f in [0.25, 0.5, 0.75] {
            let t = CMTime(seconds: asset.duration * f, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image, let h = dHash(cg) else { return nil }
            out.append(h)
        }
        return out
    }
}

extension PHAsset {
    /// 원본 파일 크기(바이트). 사진은 원본·편집본 리소스 중 가장 큰 것
    var fileSize: Int64 {
        let rs = PHAssetResource.assetResources(for: self)
        var best: Int64 = 0
        for r in rs {
            if let n = r.value(forKey: "fileSize") as? NSNumber { best = max(best, n.int64Value) }
        }
        return best
    }
    var isScreenshot: Bool { mediaSubtypes.contains(.photoScreenshot) }
    var isLivePhoto: Bool { mediaSubtypes.contains(.photoLive) }
}
