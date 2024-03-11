import SwiftUI
import RealityKit
import ARKit

@MainActor
class 🥽AppModel: ObservableObject {
    @Published private(set) var authorizationStatus: ARKitSession.AuthorizationStatus?
    @Published var selectedLeft: Bool = false
    @Published var selectedRight: Bool = false
    
    @Published var latestHandTracking: HandsUpdates = .init(left: nil, right: nil)
    
    struct HandsUpdates {
        var left: HandAnchor?
        var right: HandAnchor?
    }
    
    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    
    let rootEntity = Entity()
    private let lineEntity = 🧩Entity.line()
    private let fingerEntities: [HandAnchor.Chirality: Entity] = 🧩Entity.fingerTips()
    // private let genericBalls: [Entity] = (0..<10).map { _ in 🧩Entity.genericBall() }
    // 3 per finger + wrist
//    let genericBalls: [Entity] = (0..<32).map { _ in 🧩Entity.genericBall() }
    let handJoints: [HandSkeleton.JointName] = [
        .thumbKnuckle,
        .thumbIntermediateBase,
        .thumbTip,
        .indexFingerKnuckle,
        .indexFingerIntermediateBase,
        .indexFingerTip,
        .middleFingerKnuckle,
        .middleFingerIntermediateBase,
        .middleFingerTip,
        .ringFingerKnuckle,
        .ringFingerIntermediateBase,
        .ringFingerTip,
        .littleFingerKnuckle,
        .littleFingerIntermediateBase,
        .littleFingerTip,
        .wrist
    ]
    let genericBalls: [Entity] = 🧩Entity.genericBalls();
    
    private let sound1: AudioFileResource = try! .load(named: "sound1")
    private let sound2: AudioFileResource = try! .load(named: "sound2")
    
    private var coolDownSelection: Bool = false
}

extension 🥽AppModel {
    func setUpChildEntities() {
        self.rootEntity.addChild(self.lineEntity)
        self.fingerEntities.values.forEach { self.rootEntity.addChild($0) }
        self.genericBalls.forEach { self.rootEntity.addChild($0) }
    }
    
    func observeAuthorizationStatus() {
        Task {
            self.authorizationStatus = await self.session.queryAuthorization(for: [.handTracking])[.handTracking]
            
            for await update in self.session.events {
                if case .authorizationChanged(let type, let status) = update {
                    if type == .handTracking { self.authorizationStatus = status }
                } else {
                    print("Another session event \(update).")
                }
            }
        }
    }
    
    func run() {
#if targetEnvironment(simulator)
        print("Not support handTracking in simulator.")
#else
        Task { @MainActor in
            do {
                try await self.session.run([self.handTracking])
                await self.processHandUpdates()
            } catch {
                print(error)
            }
        }
#endif
    }

    // Add function that detects custom tap gestures
    func detectCustomTaps() -> Int? {
        // Make sure both are tracked
        guard let leftHandAnchor = latestHandTracking.left,
              let rightHandAnchor = latestHandTracking.right,
              leftHandAnchor.isTracked, rightHandAnchor.isTracked else {
            return nil
        }
        

        return 0
    }
    
    
    var labelFontSize: Double {
        self.lineLength < 1.2 ? 24 : 42
    }
    
    func changeSelection(_ targetedEntity: Entity) {
        guard !self.coolDownSelection else { return }
        switch targetedEntity.name {
            case 🧩Name.fingerLeft:
                self.selectedLeft.toggle()
                self.fingerEntities[.left]?.components.set(🧩Model.fingerTip(self.selectedLeft))
                let player = targetedEntity.prepareAudio(self.selectedLeft ? self.sound1 : self.sound2)
                player.gain = -8
                player.play()
            case 🧩Name.fingerRight:
                self.selectedRight.toggle()
                self.fingerEntities[.right]?.components.set(🧩Model.fingerTip(self.selectedRight))
                let player = targetedEntity.prepareAudio(self.selectedRight ? self.sound1 : self.sound2)
                player.gain = -8
                player.play()
            default:
                assertionFailure()
                break
        }
        Task {
            self.coolDownSelection = true
            try? await Task.sleep(for: .seconds(1))
            self.coolDownSelection = false
        }
    }
}

private extension 🥽AppModel {
    private func processHandUpdates() async {
        for await update in self.handTracking.anchorUpdates {
            let handAnchor = update.anchor
            guard handAnchor.isTracked else { continue }
            
            // Update published hand pose
            if handAnchor.chirality == .left {
                latestHandTracking.left = handAnchor
            } else if handAnchor.chirality == .right { // Update right hand info.
                latestHandTracking.right = handAnchor
            }
            
            // Get all required joints and check if they are tracked.
            // guard
            //     for joint in handJoints {
            //         handAnchor.handSkeleton?.joint(joint)?.isTracked == true

            // else {
            //     continue
            // }
            

            // Put genericBalls on the joints

            // start with just the thumb
            // let pos = handAnchor.handSkeleton?.joint(.thumbTip)
            // let worldThumbTip = handAnchor.originFromAnchorTransform * leftHandThumbTipPosition.anchorFromJointTransform
            // self.genericBalls[0].setTransformMatrix(worldThumbTip, relativeTo:nil)

            // Now do it all. If it's the left hand, start at 0, if it's the right hand, start at 16.
            let start = handAnchor.chirality == .left ? 0 : 16
            for i in 0..<16 {
                let pos = handAnchor.handSkeleton?.joint(handJoints[i])
                let worldPos = handAnchor.originFromAnchorTransform * pos!.anchorFromJointTransform
                self.genericBalls[i + start].setTransformMatrix(worldPos, relativeTo:nil)
            }
            
            guard handAnchor.isTracked,
                  let fingerTip = handAnchor.handSkeleton?.joint(.indexFingerTip),
                  fingerTip.isTracked else {
                continue
            }
            
            if self.selectedLeft, handAnchor.chirality == .left { continue }
            if self.selectedRight, handAnchor.chirality == .right { continue }
            
            let originFromWrist = handAnchor.originFromAnchorTransform
            
            let wristFromIndex = fingerTip.anchorFromJointTransform
            let originFromIndex = originFromWrist * wristFromIndex
            self.fingerEntities[handAnchor.chirality]?.setTransformMatrix(originFromIndex,
                                                                          relativeTo: nil)
        }
    }
    
    private func updateLine() {
        self.lineEntity.position = self.centerPosition
        self.lineEntity.components.set(🧩Model.line(self.lineLength))
        self.lineEntity.look(at: self.leftPosition,
                             from: self.centerPosition,
                             relativeTo: nil)
    }
    
    private var lineLength: Float {
        distance(self.leftPosition, self.rightPosition)
    }
    
    private var centerPosition: SIMD3<Float> {
        (self.leftPosition + self.rightPosition) / 2
    }
    
    public var leftPosition: SIMD3<Float> {
        self.fingerEntities[.left]?.position ?? .zero
    }
    
    public var rightPosition: SIMD3<Float> {
        self.fingerEntities[.right]?.position ?? .zero
    }
}

//MARK: Simulator
extension 🥽AppModel {
    func setUp_simulator() {
#if targetEnvironment(simulator)
        self.updateLine()
#endif
    }
    func setRandomPosition_simulator() {
#if targetEnvironment(simulator)
        if !self.selectedLeft {
            self.fingerEntities[.left]?.position = .init(x: .random(in: -0.8 ..< -0.05),
                                                         y: .random(in: 1 ..< 1.5),
                                                         z: .random(in: -1 ..< -0.5))
        }
        if !self.selectedRight {
            self.fingerEntities[.right]?.position = .init(x: .random(in: 0.05 ..< 0.8),
                                                          y: .random(in: 1 ..< 1.5),
                                                          z: .random(in: -1 ..< -0.5))
        }
        self.updateLine()
#endif
    }
}
