import Metal
import MetalKit
import os
import simd

public class SampleBoxRenderer {
    enum Constants {
        // Keep in sync with Shaders.metal : maxViewCount
        static let maxViewCount = 2
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier!,
               category: "SampleBoxRenderer")

    enum Error: Swift.Error {
        case bufferCreationFailed
        case badVertexDescriptor
        case depthStencilStateCreationFailed
    }

    public typealias CameraMatrices = ( projection: simd_float4x4, view: simd_float4x4 )

    enum BufferIndex: NSInteger {
        case meshPositions = 0
        case meshGenerics  = 1
        case uniforms      = 2
    }

    enum VertexAttribute: NSInteger {
        case position = 0
        case texcoord = 1
    }

    enum TextureIndex: NSInteger {
        case color = 0
    }

    struct Uniforms {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
    }

    struct UniformsArray {
        // maxViewCount = 2, so we have 2 entries
        var uniforms0: Uniforms
        var uniforms1: Uniforms

        // The 256 byte aligned size of our uniform structure
        static var alignedSize: Int { (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100 }

        mutating func setUniforms(index: Int, _ uniforms: Uniforms) {
            switch index {
            case 0: uniforms0 = uniforms
            case 1: uniforms1 = uniforms
            default: break
            }
        }
    }

    public let device: MTLDevice
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var colorMap: MTLTexture
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>

    var mesh: MTKMesh

    public init(device: MTLDevice,
                colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat,
                stencilFormat: MTLPixelFormat,
                sampleCount: Int,
                maxViewCount: Int,
                maxSimultaneousRenders: Int) throws {
        self.device = device
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders

        let uniformBufferSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffer = device.makeBuffer(length: uniformBufferSize,
                                                      options: .storageModeShared)!
        self.dynamicUniformBuffer.label = "UniformBuffer"
        self.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to: UniformsArray.self, capacity: 1)

        let mtlVertexDescriptor = Self.buildMetalVertexDescriptor()

        do {
            pipelineState = try Self.buildRenderPipelineWithDevice(device: device,
                                                                   colorFormat: colorFormat,
                                                                   depthFormat: depthFormat,
                                                                   stencilFormat: stencilFormat,
                                                                   sampleCount: sampleCount,
                                                                   maxViewCount: self.maxViewCount,
                                                                   mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            Self.log.error("Unable to compile render pipeline state. Error info: \(error)")
            throw error
        }

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depthStateDescriptor) else {
            throw Error.depthStencilStateCreationFailed
        }
        depthState = state

        do {
            mesh = try Self.buildMesh(device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            Self.log.error("Unable to build MetalKit Mesh. Error info: \(error)")
            throw error
        }

        do {
            colorMap = try Self.loadTexture(device: device, textureName: "ColorMap")
        } catch {
            Self.log.error("Unable to load texture. Error info: \(error)")
            throw error
        }
    }

    public func willRender(viewportCameras: [CameraMatrices]) {}

    private func updateDynamicBufferState() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxSimultaneousRenders
        uniformBufferOffset = UniformsArray.alignedSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(forViewportCameras viewportCameras: [CameraMatrices]) {
        for (i, viewportCamera) in viewportCameras.enumerated() where i <= maxViewCount {
            uniforms.pointee.setUniforms(index: i, Uniforms(projectionMatrix: viewportCamera.projection, viewMatrix: viewportCamera.view))
        }
    }

    public func render(viewportCameras: [CameraMatrices], to renderEncoder: MTLRenderCommandEncoder) {
        updateDynamicBufferState()
        updateUniforms(forViewportCameras: viewportCameras)

        renderEncoder.pushDebugGroup("Draw Box")

        renderEncoder.setCullMode(.back)

        renderEncoder.setFrontFacing(.counterClockwise)

        renderEncoder.setRenderPipelineState(pipelineState)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        for (index, element) in mesh.vertexDescriptor.layouts.enumerated() {
            guard let layout = element as? MDLVertexBufferLayout else {
                return
            }

            if layout.stride != 0 {
                let buffer = mesh.vertexBuffers[index]
                renderEncoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
            }
        }

        renderEncoder.setFragmentTexture(colorMap, index: TextureIndex.color.rawValue)

        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                indexCount: submesh.indexCount,
                                                indexType: submesh.indexType,
                                                indexBuffer: submesh.indexBuffer.buffer,
                                                indexBufferOffset: submesh.indexBuffer.offset)
        }

        renderEncoder.popDebugGroup()
    }

    private class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        let mtlVertexDescriptor = MTLVertexDescriptor()

        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshGenerics.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 12
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stride = 8
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    private class func buildRenderPipelineWithDevice(device: MTLDevice,
                                                     colorFormat: MTLPixelFormat,
                                                     depthFormat: MTLPixelFormat,
                                                     stencilFormat: MTLPixelFormat,
                                                     sampleCount: Int,
                                                     maxViewCount: Int,
                                                     mtlVertexDescriptor: MTLVertexDescriptor)
    throws -> MTLRenderPipelineState {
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)

        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = stencilFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    private class func buildMesh(device: MTLDevice,
                                 mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTKMesh {
        let metalAllocator = MTKMeshBufferAllocator(device: device)

        let mdlMesh = MDLMesh.newBox(withDimensions: SIMD3<Float>(4, 4, 4),
                                     segments: SIMD3<UInt32>(2, 2, 2),
                                     geometryType: MDLGeometryType.triangles,
                                     inwardNormals: false,
                                     allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)

        guard let attributes = mdlVertexDescriptor.attributes as? [MDLVertexAttribute] else {
            throw Error.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name = MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name = MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh: mdlMesh, device: device)
    }

    private class func loadTexture(device: MTLDevice,
                                   textureName: String) throws -> MTLTexture {
        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
        ]

        return try textureLoader.newTexture(name: textureName,
                                            scaleFactor: 1.0,
                                            bundle: Bundle.module,
                                            options: textureLoaderOptions)
    }
}
