import Foundation
import Metal
import simd
import MetalSplatter

public struct ModelRendererViewportDescriptor {
    var viewport: MTLViewport
    var projectionMatrix: simd_float4x4
    // splats
    var viewMatrix: simd_float4x4
    // balls
    var viewMatrix2: simd_float4x4
    var screenSize: SIMD2<Int>
}

public protocol ModelRenderer {
    func render(viewports: [ModelRendererViewportDescriptor],
                colorTexture: MTLTexture,
                colorStoreAction: MTLStoreAction,
                depthTexture: MTLTexture?,
                stencilTexture: MTLTexture?,
                rasterizationRateMap: MTLRasterizationRateMap?,
                renderTargetArrayLength: Int,
                to commandBuffer: MTLCommandBuffer)
    func addBalls(balls: [[Float]]) throws
    func resort()
    func get_center() -> [Double]
}
