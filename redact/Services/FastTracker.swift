import CoreGraphics
import CoreImage
import Foundation

/// FastTracker: occlusion-aware multi-object tracking, so a blur stays glued to a thing instead
/// of flickering with the detector.
///
/// This is Ultralytics' **FastTracker** (`fasttrack.yaml`, `trackers/fast_tracker.py`,
/// arXiv:2508.14370), ported to Swift. Ultralytics' trackers are Python and run beside a PyTorch
/// model, so they cannot be loaded into a CoreML app; the algorithm and every default below are
/// taken directly from `fasttrack.yaml`.
///
/// FastTracker is ByteTrack plus occlusion handling. ByteTrack's own idea is the two-stage match:
/// confident detections first, then a second pass against the *low*-confidence ones, because a
/// weak detection is usually a real object that got occluded or motion-blurred, and keeping it
/// beats dropping the track. On top of that FastTracker adds: when an unmatched track is mostly
/// covered by an active neighbour it is flagged occluded, its motion state is rolled back to
/// before the occlusion, its box is enlarged once and its velocity dampened so it survives the
/// pass-behind; occluded tracks get a grace period before being marked lost and stay re-findable
/// for longer afterwards; and a new detection that heavily overlaps an existing track is
/// suppressed so crowds don't spawn ghost IDs.
///
/// One deliberate difference from upstream. Ultralytics emits only tracks matched on the current
/// frame, because for analytics a coasted box is a false positive. Here a coasted box is the
/// entire point: if the detector blinks for one frame and nothing is drawn, an unblurred face
/// goes out in the export. So predicted boxes for still-alive tracks are emitted too.
public final class FastTracker {
    /// Every value here is the default from Ultralytics' `fasttrack.yaml`.
    struct Config {
        /// First-stage match threshold: detections at or above this are treated as reliable.
        var trackHighThreshold: Float = 0.25
        /// Below this a detection is noise and is ignored entirely.
        var trackLowThreshold: Float = 0.1
        /// A leftover detection must be at least this strong to start a new track.
        var newTrackThreshold: Float = 0.25
        /// Frames a lost track is kept alive.
        var trackBuffer = 30
        /// First-stage association threshold, as a cost: accept when cost <= this.
        var matchThreshold: CGFloat = 0.8
        /// Fold the detection's confidence into the first-stage cost.
        var fuseScore = true

        // FastTracker-specific knobs.
        /// History frames back to restore velocity from at occlusion onset.
        var resetVelocityOffsetOcc = 5
        /// History frames back to restore position from at occlusion onset.
        var resetPositionOffsetOcc = 3
        /// One-shot box height scale while occluded, widening the search region.
        var enlargeBoxOcc: CGFloat = 1.1
        /// Velocity dampening applied while occluded.
        var dampenMotionOcc: CGFloat = 0.5
        /// Max consecutive occluded frames before a track is marked lost anyway.
        var activeOccToLostThreshold = 10
        /// Fraction of a track's area covered by another before declaring occlusion.
        var occCoverThreshold: CGFloat = 0.7
        /// Frames a recently-occluded lost track stays re-findable.
        var occReappearWindow = 40
        /// Suppress a new track when its overlap with an active one reaches this.
        var initIoUSuppress: CGFloat = 0.7
    }

    /// Second-stage threshold, as a cost. Hard-coded upstream in `_second_association`.
    private let secondStageMatchThreshold: CGFloat = 0.5
    /// A track is not blurred until seen this many times, so noise never produces a one-frame
    /// smear. Our own addition: upstream has no equivalent because it emits only matched tracks.
    private let minimumHits = 2

    private let config: Config
    private var tracks: [Track] = []
    private var nextID = 1
    private var frameID = 0
    private var historyLength: Int { max(config.resetVelocityOffsetOcc, config.resetPositionOffsetOcc) + 4 }

    public convenience init() { self.init(config: Config()) }

    init(config: Config) {
        self.config = config
    }

    private struct Snapshot {
        var box: CGRect
        var velocity: CGVector
    }

    private enum TrackState {
        case tracked
        case lost
    }

    private final class Track {
        var id: Int
        var classIndex: Int
        var box: CGRect
        var velocity: CGVector
        var confidence: Float
        var hits: Int
        var state: TrackState = .tracked
        var notMatched = 0
        var isOccluded = false
        var occludedLength = 0
        var lastOccludedFrame = -1
        var wasRecentlyOccluded = false
        var lastFrameSeen: Int
        /// Bounded ring buffer of recent motion states, so the rollback at occlusion onset has
        /// something to roll back to. Bounded so memory stays flat however long a track lives.
        var history: [Snapshot] = []
        var mask: CIImage?

        init(id: Int, classIndex: Int, box: CGRect, confidence: Float, frame: Int) {
            self.id = id
            self.classIndex = classIndex
            self.box = box
            self.velocity = .zero
            self.confidence = confidence
            self.hits = 1
            self.lastFrameSeen = frame
        }

        func pushHistory(limit: Int) {
            history.append(Snapshot(box: box, velocity: velocity))
            if history.count > limit { history.removeFirst(history.count - limit) }
        }
    }

    public func reset() {
        tracks.removeAll()
        nextID = 1
        frameID = 0
    }

    /// Runs one frame's detections through the tracker and returns what should be blurred.
    public func update(with detections: [Detection]) -> [Detection] {
        frameID += 1

        // Predict: every track carries on moving the way it has been moving.
        for track in tracks {
            track.box = track.box.offsetBy(dx: track.velocity.dx, dy: track.velocity.dy)
        }

        let strong = detections.filter { $0.confidence >= config.trackHighThreshold }
        let weak = detections.filter {
            $0.confidence >= config.trackLowThreshold && $0.confidence < config.trackHighThreshold
        }

        var unmatched = Set(tracks.indices)

        // Stage one: confident detections, against everything including lost tracks so a lost
        // track can be re-found.
        var leftoverStrong = associate(
            strong, unmatched: &unmatched, threshold: config.matchThreshold, fuseScore: config.fuseScore
        )
        // Stage two: the weak detections, against tracked-state leftovers only, matching upstream.
        var stillTracked = unmatched.filter { tracks[$0].state == .tracked }
        _ = associate(weak, unmatched: &stillTracked, threshold: secondStageMatchThreshold, fuseScore: false)
        let matchedInSecondStage = unmatched.subtracting(stillTracked)
        unmatched.subtract(matchedInSecondStage)

        handleOcclusions(unmatchedIndices: stillTracked)

        // Strong leftovers become new tracks, unless they sit on top of an existing one.
        leftoverStrong.removeAll { detection in
            guard detection.confidence >= config.newTrackThreshold else { return true }
            if config.initIoUSuppress < 1.0 {
                let overlapsActive = tracks.contains { track in
                    track.state == .tracked && iou(track.box, detection.boundingBox) >= config.initIoUSuppress
                }
                if overlapsActive { return true }
            }
            let track = Track(
                id: nextID, classIndex: detection.classIndex, box: detection.boundingBox,
                confidence: detection.confidence, frame: frameID
            )
            track.mask = detection.maskImage
            track.pushHistory(limit: historyLength)
            tracks.append(track)
            nextID += 1
            return true
        }

        // Drop lost tracks that are past their buffer, with a longer grace window for anything
        // that went missing while occluded.
        tracks.removeAll { track in
            guard track.state == .lost else { return false }
            let recentlyOccluded = track.wasRecentlyOccluded
                && (frameID - track.lastOccludedFrame <= config.occReappearWindow)
            return !recentlyOccluded && (frameID - track.lastFrameSeen > config.trackBuffer)
        }

        return tracks.compactMap { track in
            guard track.state == .tracked else { return nil }
            guard track.hits >= minimumHits || track.lastFrameSeen == frameID else { return nil }
            // A mask is pixel data tied to the frame it came from. On a coasted frame the object
            // has moved on, so a stale mask would clip the blur to the wrong shape; hand back no
            // mask and let that frame fall back to a box.
            let mask = track.lastFrameSeen == frameID ? track.mask : nil
            return Detection(
                classIndex: track.classIndex,
                confidence: track.confidence,
                boundingBox: track.box,
                maskImage: mask
            )
        }
    }

    // MARK: - Association

    /// Greedy assignment on the cost matrix. Upstream uses Hungarian matching; with the handful of
    /// objects in a frame the greedy pick is the same often enough that the extra machinery is not
    /// worth carrying.
    private func associate(
        _ detections: [Detection], unmatched: inout Set<Int>, threshold: CGFloat, fuseScore: Bool
    ) -> [Detection] {
        var remaining = detections
        guard !remaining.isEmpty, !unmatched.isEmpty else { return remaining }

        while !remaining.isEmpty, !unmatched.isEmpty {
            var best: (trackIndex: Int, detectionIndex: Int, cost: CGFloat)?
            for trackIndex in unmatched {
                let track = tracks[trackIndex]
                for (detectionIndex, detection) in remaining.enumerated() {
                    // Never let one class's box capture another's track: an ID that swaps class is
                    // exactly the flicker this is meant to remove.
                    guard detection.classIndex == track.classIndex else { continue }
                    let overlap = iou(track.box, detection.boundingBox)
                    // ByteTrack's `fuse_score`: fold confidence into the similarity so a strong
                    // detection wins a contested match.
                    let similarity = fuseScore ? overlap * CGFloat(detection.confidence) : overlap
                    let cost = 1 - similarity
                    guard cost <= threshold, overlap > 0 else { continue }
                    if best == nil || cost < best!.cost { best = (trackIndex, detectionIndex, cost) }
                }
            }
            guard let match = best else { break }

            apply(remaining[match.detectionIndex], to: tracks[match.trackIndex])
            unmatched.remove(match.trackIndex)
            remaining.remove(at: match.detectionIndex)
        }
        return remaining
    }

    private func apply(_ detection: Detection, to track: Track) {
        let previous = track.box
        // Smooth towards the measurement rather than snapping to it. Upstream lets a Kalman filter
        // do this; the blend below is the same idea with one tunable.
        let smoothing: CGFloat = 0.65
        let blended = CGRect(
            x: previous.minX + (detection.boundingBox.minX - previous.minX) * smoothing,
            y: previous.minY + (detection.boundingBox.minY - previous.minY) * smoothing,
            width: previous.width + (detection.boundingBox.width - previous.width) * smoothing,
            height: previous.height + (detection.boundingBox.height - previous.height) * smoothing
        )
        track.velocity = CGVector(
            dx: (blended.midX - previous.midX) * 0.5 + track.velocity.dx * 0.5,
            dy: (blended.midY - previous.midY) * 0.5 + track.velocity.dy * 0.5
        )
        track.box = blended
        track.confidence = detection.confidence
        track.mask = detection.maskImage
        track.hits += 1
        track.lastFrameSeen = frameID
        track.state = .tracked
        // A successful match clears the occlusion bookkeeping, as in upstream's `_apply_match`.
        track.isOccluded = false
        track.notMatched = 0
        track.occludedLength = 0
        track.pushHistory(limit: historyLength)
    }

    // MARK: - Occlusion

    /// Flags unmatched tracks that are mostly covered by an active neighbour, rolls their motion
    /// state back to before the occlusion, and decides when to give up on them.
    private func handleOcclusions(unmatchedIndices: Set<Int>) {
        guard !unmatchedIndices.isEmpty else { return }
        let active = tracks.filter { $0.state == .tracked && $0.lastFrameSeen == frameID && !$0.isOccluded }

        for index in unmatchedIndices {
            let track = tracks[index]
            track.notMatched += 1

            // Coverage is intersection over the *unmatched track's* area, not IoU: what matters is
            // how much of this object is hidden, regardless of how big the thing in front is.
            let coverage = active.reduce(CGFloat.zero) { best, other in
                guard other.id != track.id else { return best }
                let intersection = other.box.intersection(track.box)
                guard !intersection.isNull else { return best }
                let area = track.box.width * track.box.height
                guard area > 0 else { return best }
                return max(best, (intersection.width * intersection.height) / area)
            }

            if coverage > config.occCoverThreshold, !track.isOccluded, track.state == .tracked {
                track.isOccluded = true
                track.occludedLength = 1
                track.lastOccludedFrame = frameID
                track.wasRecentlyOccluded = true

                // Roll back: velocity from further back than position, because by the time the
                // occlusion is noticed the last few frames have already been corrupted by it.
                if track.history.count >= config.resetVelocityOffsetOcc {
                    track.velocity = track.history[track.history.count - config.resetVelocityOffsetOcc].velocity
                }
                if track.history.count >= config.resetPositionOffsetOcc {
                    track.box = track.history[track.history.count - config.resetPositionOffsetOcc].box
                }
                // Widen the search region once, and slow the drift so the box doesn't sail off
                // while the object is invisible.
                let heightGrowth = track.box.height * (config.enlargeBoxOcc - 1)
                let widthGrowth = track.box.width * (config.enlargeBoxOcc - 1)
                track.box = track.box.insetBy(dx: -widthGrowth / 2, dy: -heightGrowth / 2)
                track.velocity = CGVector(
                    dx: track.velocity.dx * config.dampenMotionOcc,
                    dy: track.velocity.dy * config.dampenMotionOcc
                )
            } else if track.isOccluded {
                track.occludedLength += 1
            }

            if track.wasRecentlyOccluded, frameID - track.lastOccludedFrame > config.occReappearWindow {
                track.wasRecentlyOccluded = false
            }

            // Occluded tracks get a grace period; everything else is given up on after two misses.
            let outOfGrace = !track.isOccluded || track.occludedLength > config.activeOccToLostThreshold
            if track.state != .lost, track.notMatched > 2, outOfGrace {
                track.state = .lost
            }
        }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let overlap = intersection.width * intersection.height
        let union = a.width * a.height + b.width * b.height - overlap
        guard union > 0 else { return 0 }
        return overlap / union
    }
}
