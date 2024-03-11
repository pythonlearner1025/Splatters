#if os(visionOS)
import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import Spatial
import SwiftUI
import Combine
import ARKit
import RealityKit

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}
// ball pos
struct BallCoords {
    var coords: [simd_float4x4]

    init() {
        coords = Array(repeating: simd_float4x4(1), count: 32)
    }
}
//@MainActor
class VisionSceneRenderer {
    // add AppModel
    var latestHandTracking: HandsUpdates = .init(left: nil, right: nil)
    var latestBallCoords: BallCoords = .init()
    
    private static let log =
    Logger(subsystem: Bundle.main.bundleIdentifier!,
           category: "CompsitorServicesSceneRenderer")
    
    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var firstRender: Bool = false
    
    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?
    
    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)
    
    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero
    
    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    
    var modelSubscription: AnyCancellable?
    var ballScription: AnyCancellable?
    
    @MainActor
    init(_ layerRenderer: LayerRenderer, _ appModel: 🥽AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!
        
        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
        modelSubscription = appModel.$latestHandTracking.sink { [weak self] pos in
            self?.updateHandSkeletonPositions(pos)
        }
        
        ballScription = appModel.$genericBallCoords.sink { [weak self] coords in
            self?.updateGenericBalls(coords.coords)
        }
    }
     
    func updateHandSkeletonPositions(_ pos: HandsUpdates) {
        latestHandTracking.left = pos.left
        latestHandTracking.right = pos.right
    }
        
    func updateGenericBalls(_ balls: [simd_float4x4]) {
        let r = 15
        for i in 0..<balls.count {
        
            latestBallCoords.coords[i] = balls[i]
            // 4, 7, 10, 13
            isSwipe(balls[r+5], balls[r+8], balls[r+11], balls[r+15])
            isPinchActivated(balls[r+2], balls[r+5])
            calcZoom(balls[r+2], balls[r+5])
        }
    }    
    
    func dist(_ x1: Float, _ y1: Float, _ z1: Float, _ x2: Float, _ y2: Float, _ z2: Float) -> Float {
        let distance = sqrt(((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1) + (z2 - z1) * (z2 - z1)))
        return distance
    }
    
    // Time tracking variable
    var pinchActivated = false
    var lP : simd_float3 = [Float(0), Float(0), Float(0)]
    var dV : simd_float3 = [Float(0), Float(0), Float(0)]
    var lastPinchUpdateTime: TimeInterval = 0

    func isPinchActivated(_ thumbTip: simd_float4x4, _ indexTip: simd_float4x4) {
        let currentTime = CACurrentMediaTime() // Get current time
        let updateInterval: TimeInterval = 0.01 // 100 milliseconds

        // Proceed only if 100ms have passed since the last update
        if currentTime - lastPinchUpdateTime >= updateInterval {
            let p1 = thumbTip.columns.3
            let p2 = indexTip.columns.3
            let x1 = p1.x; let x2 = p2.x
            let y1 = p1.y; let y2 = p2.y
            let z1 = p1.z; let z2 = p2.z
            let thresh = Float(0.070)
            let d = dist(x1, y1, z1, x2, y2, z2)
            let zero = Float(0.0)
            
            if d != zero {
                if d < thresh {
                    pinchActivated = true
                    dV[0] = x1 - lP[0]
                    dV[1] = y1 - lP[1]
                    dV[2] = z1 - lP[2]
                   // print(dV)
                    lP = [x1, y1, z1]
                    
                    // Update the last update time
                    lastPinchUpdateTime = currentTime
                } else {
                    pinchActivated = false
                    lP = [x1, y1, z1]
                }
            }
        }
    }

    var lastDist : Float = 0
    var zoom : Float = 0
    var maxZoomDist : Float = 1
    func calcZoom (_ thumbTip : simd_float4x4, _ indexTip : simd_float4x4) {
        let p1 = thumbTip.columns.3
        let p2 = indexTip.columns.3
        let x1 = p1.x; let x2 = p2.x
        let y1 = p1.y; let y2 = p2.y
        let z1 = p1.z; let z2 = p2.z
        let d = dist(x1,y1,z1,x2,y2,z2)
        let v = d - lastDist
        lastDist = d
        zoom = v / maxZoomDist
    }
    
    // swipe
    // 4 middle joints of each finger within some proximity
    // rotate splats in dir of rotation
    var swipeActivated : Bool = false
    var rotationAxis = Constants.rotationAxis
    var lastSwipeZ : Float = 0
    var lastSwipeUpdateTime: TimeInterval = 0
    
    // apparently Y - up, X - left, Z - bottom
    
    func isSwipe(_ indexMid : simd_float4x4, _ middleMid : simd_float4x4, _ ringMid : simd_float4x4, _ littleMid : simd_float4x4) {
          let currentTime = CACurrentMediaTime() // Get current time
          let updateInterval: TimeInterval = 0.05 // 100 milliseconds
        
        if true {
              let thresh : Float = 0.035
              let pIndex = indexMid.columns.3
              let pMiddle = middleMid.columns.3
              let pRing = ringMid.columns.3
              let pLittle = littleMid.columns.3
              
              // Calculate distances between the joints
              let dIndexMiddle = dist(pIndex.x, pIndex.y, pIndex.z, pMiddle.x, pMiddle.y, pMiddle.z)
              let dMiddleRing = dist(pMiddle.x, pMiddle.y, pMiddle.z, pRing.x, pRing.y, pRing.z)
              let dRingLittle = dist(pRing.x, pRing.y, pRing.z, pLittle.x, pLittle.y, pLittle.z)
              let zero : Float = 0.0
            
            if dIndexMiddle == zero || dMiddleRing == zero || dRingLittle == zero {
                return
            }
            
            if dIndexMiddle < thresh && dMiddleRing < thresh  {
                swipeActivated = true
                // y-axis
                rotationAxis = simd_float3(indexMid.columns.1.x, indexMid.columns.1.y, indexMid.columns.1.z)
                var dz = indexMid.columns.3.z - lastSwipeZ
                rotation += Angle.degrees(dz > Float(0) ? 0.002 : -0.002)
                lastSwipeZ = indexMid.columns.3.z
                lastSwipeUpdateTime = currentTime
            } else {
                //print("swipe false")
                swipeActivated = false
            }
        }
    }
    
    func load(_ model: ModelIdentifier?) throws {
        guard model != self.model else { return }
        self.model = model
        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            print("loading gaussian splat")
            let splat = try SplatRenderer(device: device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          stencilFormat: .invalid,
                                          sampleCount: 1,
                                          maxViewCount: layerRenderer.properties.viewCount,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            // Store depth on visionOS because it's used for reprojection by the frame interpolator, since we don't hit a solid 90fps
            splat.storeDepth = true
            try splat.readPLY(from: url)
            modelRenderer = splat
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: layerRenderer.configuration.colorFormat,
                                                   depthFormat: layerRenderer.configuration.depthFormat,
                                                   stencilFormat: .invalid,
                                                   sampleCount: 1,
                                                   maxViewCount: layerRenderer.properties.viewCount,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }
    
    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }
            
            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }
    
    var x : Float = 0.0
    var y : Float = 0.0
    var z : Float = 0.0
    
    
    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [ModelRendererViewportDescriptor] {
       
        
        if let c = modelRenderer?.get_center() {
            if !firstRender {
            x = (!firstRender) ? Float(c[0]) : 0.0
            y = (!firstRender) ? Float(c[1]) : 0.0
            z = (!firstRender) ? Float(c[2]) : 0.0
            firstRender = true
        }
            // for splats
            var rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                    axis: rotationAxis)
            var rotationMatrix2 = matrix4x4_rotation(radians: Float(0),
                                                     axis: Constants.rotationAxis )
            
            let translationMatrix2 = matrix4x4_translation(0.0, 0.0, 0.0) // keep constant hands // for splats
            if pinchActivated {
                x += dV[0]
                y += dV[1]
                z += dV[2]
            }
            
            let translationMatrix = matrix4x4_translation(x, y, z) // TODO for pinch translate splats
            
            // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
            // happens to be a useful default for the most common datasets at the moment.
            let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
            
            let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
            return drawable.views.map { view in
                let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
                
                let projectionMatrix = ProjectiveTransform3D(leftTangent: Double(view.tangents[0]),
                                                             rightTangent: Double(view.tangents[1]),
                                                             topTangent: Double(view.tangents[2]),
                                                             bottomTangent: Double(view.tangents[3]),
                                                             nearZ: Double(drawable.depthRange.y),
                                                             farZ: Double(drawable.depthRange.x),
                                                             reverseZ: true)
                
                let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                       y: Int(view.textureMap.viewport.height))
                
                return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                       projectionMatrix: .init(projectionMatrix),
                                                       viewMatrix: userViewpointMatrix * translationMatrix * rotationMatrix, //* commonUpCalibration,
                                                       viewMatrix2: userViewpointMatrix * translationMatrix2 * rotationMatrix2,
                                                       screenSize: screenSize)
            }
        }
        return []
    }
        
    // input events
    public func updateRotation() {
       // get the metal balls and draw it
        
    }
    
    private func defaultRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }
        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * 0 //now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        guard let drawable = frame.queryDrawable() else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }
        
        var balls : [[Float]] = []
        for i in 0..<latestBallCoords.coords.count {
            let mat = latestBallCoords.coords[i]
            let x = mat.columns.3.x
            let y = mat.columns.3.y
            let z = mat.columns.3.z
            balls.append([Float(x),Float(y),Float(z)])
        }
        
        do {
            try modelRenderer?.addBalls(balls: balls)
        } catch {
            print(error)
        }
        //modelRenderer?.addBalls(latestBallCoords)

        let viewports = self.viewports(drawable: drawable, deviceAnchor: deviceAnchor)
        
        modelRenderer?.render(viewports: viewports,
                              colorTexture: drawable.colorTextures[0],
                              colorStoreAction: .store,
                              depthTexture: drawable.depthTextures[0],
                              stencilTexture: nil,
                              rasterizationRateMap: drawable.rasterizationRateMaps.first,
                              renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                              to: commandBuffer)

        drawable.encodePresent(commandBuffer: commandBuffer)

        commandBuffer.commit()

        frame.endSubmission()
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.warning("Layer is invalidated")
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

#endif // os(visionOS)

