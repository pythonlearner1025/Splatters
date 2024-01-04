import Foundation
import SwiftUI

enum Constants {
    // For testing, try setting model = .sampleBox
    static let model: ModelIdentifier =
        .gaussianSplat("PATH/TO/PLY")

    static let maxSimultaneousRenders = 3
    static let rotationPerSecond = Angle(degrees: 7)
    static let rotationAxis = SIMD3<Float>(0, 1, 0)
#if !os(visionOS)
    static let fovy = Angle(degrees: 65)
#endif
    static let modelCenterZ: Float = -8
}

