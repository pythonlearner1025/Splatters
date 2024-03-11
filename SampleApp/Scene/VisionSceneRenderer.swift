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
        
   // var ballsToRender =
    
    func updateHandSkeletonPositions(_ pos: HandsUpdates) {
        latestHandTracking.left = pos.left
        latestHandTracking.right = pos.right
    }
        
    func updateGenericBalls(_ balls: [simd_float4x4]) {
        for i in 0..<balls.count {
            latestBallCoords.coords[i] = balls[i]
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
    
    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [ModelRendererViewportDescriptor] {
       
        if !firstRender {
            print("First render")
            modelRenderer?.resort()
            firstRender = true
        }
        
        if let c = modelRenderer?.get_center() {
            var x =  (!firstRender) ? Float(c[0]) : 0.0
            var y =  (!firstRender) ? Float(c[1]) : 0.0
            var z =  (!firstRender) ? Float(c[2]) : 0.0
            let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                    axis: Constants.rotationAxis)
            // get w,h,l
            let translationMatrix = matrix4x4_translation(x, y, z)
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

