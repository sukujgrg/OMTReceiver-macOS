import XCTest
import Metal
import simd
@testable import OMTReceiver

/// Offscreen renders exercise the shipped shader, with actual GPU readback.
/// These checks establish pixel math, not physical display colorimetry/scanout.
final class VideoRenderingTests: XCTestCase {
    private struct Uniforms {
        var dimensions: SIMD4<UInt32>
        var options: SIMD4<Int32>
        var output: SIMD4<Float>
    }
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal device unavailable; run these checks with GPU access.")
        queue = try XCTUnwrap(device.makeCommandQueue())
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VideoShaders.metal", withExtension: "txt"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "omt_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "omt_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func render(_ bytes: [UInt8], width: Int = 2, height: Int = 2,
                        stride: Int, codec: UInt32, flags: Int32 = 0,
                        field: Int32 = -1, background: Int32 = 0,
                        outputWidth: Int? = nil, outputHeight: Int? = nil) throws -> [[UInt8]] {
        let outWidth = outputWidth ?? width, outHeight = outputHeight ?? height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: outWidth, height: outHeight, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        let buffer = try XCTUnwrap(bytes.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        var uniforms = Uniforms(dimensions: SIMD4(UInt32(width), UInt32(height), UInt32(stride), codec),
            options: SIMD4(flags, 709, field, background),
            output: SIMD4(Float(outWidth), Float(outHeight), Float(outWidth)/Float(outHeight), 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        texture.getBytes(&result, bytesPerRow: outWidth * 4,
                         from: MTLRegionMake2D(0, 0, outWidth, outHeight), mipmapLevel: 0)
        return Swift.stride(from: 0, to: result.count, by: 4).map { Array(result[$0..<$0+4]) }
    }

    private func assertPixel(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 2,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (got, want) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(Int(got)-Int(want)), tolerance,
                                    "BGRA \(actual) differs from \(expected)", file: file, line: line)
        }
    }

    func testRec709UYVYLimitedRangeBlackAndWhite() throws {
        let row: [UInt8] = [128, 16, 128, 16, 128, 235, 128, 235]
        let pixels = try render(row + row, width: 4, stride: 8, codec: 0x59565955)
        assertPixel(pixels[0], [0, 0, 0, 255])
        assertPixel(pixels[1], [0, 0, 0, 255])
        assertPixel(pixels[2], [255, 255, 255, 255])
        assertPixel(pixels[3], [255, 255, 255, 255])
    }

    func testRec709UYVYRedChromaUses709Matrix() throws {
        let pixels = try render([102, 63, 240, 63, 102, 63, 240, 63],
                                stride: 4, codec: 0x59565955)
        assertPixel(pixels[0], [0, 0, 255, 255], tolerance: 8)
    }

    func testStraightAndPremultipliedAlphaCompositeInLinearLight() throws {
        let straight = Array(repeating: [UInt8](arrayLiteral: 0, 0, 255, 128), count: 4).flatMap { $0 }
        let premultiplied = Array(repeating: [UInt8](arrayLiteral: 0, 0, 128, 128), count: 4).flatMap { $0 }
        let a = try render(straight, stride: 8, codec: 0x41524742, flags: 2)
        let b = try render(premultiplied, stride: 8, codec: 0x41524742, flags: 6)
        assertPixel(a[0], [0, 0, 188, 255])
        assertPixel(b[0], a[0])
    }

    func testTransparentBGRARevealsCheckerboard() throws {
        let pixels = try render([UInt8](repeating: 0, count: 16), stride: 8,
                                codec: 0x41524742, flags: 2, background: 1,
                                outputWidth: 40, outputHeight: 2)
        assertPixel(pixels[0], [101, 101, 101, 255])
        assertPixel(pixels[25], [149, 149, 149, 255])
    }

    func testPA16UsesFullResolution16BitAlphaPlane() throws {
        let luma: [UInt8] = [0, 235, 0, 235, 0, 235, 0, 235]
        let chroma: [UInt8] = [0, 128, 0, 128, 0, 128, 0, 128]
        // Half alpha in the first pixel, zero in the second, full in the third.
        let alpha: [UInt8] = [0, 128, 0, 0, 255, 255, 0, 128]
        let pixels = try render(luma + chroma + alpha, stride: 4,
                                codec: 0x36314150, flags: 2)
        assertPixel(pixels[0], [188, 188, 188, 255])
        assertPixel(pixels[1], [0, 0, 0, 255])
        assertPixel(pixels[2], [255, 255, 255, 255])
    }

    func testUYVAUsesSeparateStraightAlphaPlane() throws {
        let pixels = try render([128,235,128,235,128,235,128,235,128,0,255,128],
                                stride: 4, codec: 0x41565955, flags: 2)
        assertPixel(pixels[0], [188, 188, 188, 255])
        assertPixel(pixels[1], [0, 0, 0, 255])
        assertPixel(pixels[2], [255, 255, 255, 255])
    }

    func testBobKeepsFieldsTemporallySeparateWhileWeavePreservesBoth() throws {
        let white: [UInt8] = [255,255,255,255,255,255,255,255]
        let black: [UInt8] = [0,0,0,255,0,0,0,255]
        let bytes = white + black + white + black
        let weave = try render(bytes, height: 4, stride: 8, codec: 0x41524742, flags: 1)
        let top = try render(bytes, height: 4, stride: 8, codec: 0x41524742, flags: 1, field: 0)
        let bottom = try render(bytes, height: 4, stride: 8, codec: 0x41524742, flags: 1, field: 1)
        assertPixel(weave[0], [255,255,255,255]); assertPixel(weave[2], [0,0,0,255])
        for pixel in top { assertPixel(pixel, [255,255,255,255]) }
        for pixel in bottom { assertPixel(pixel, [0,0,0,255]) }
    }
    func testFloatDrawablePreservesSourceGradientFinerThanEightBits() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VideoShaders.metal", withExtension: "txt"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "omt_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "omt_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let floatPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: 2, height: 2, mipmapped: false)
        target.usage = .renderTarget; target.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: target))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        // Two P216 luma values one 10-bit step apart, with neutral chroma.
        let bytes: [UInt8] = [0,128,64,128,0,128,64,128,0,128,0,128,0,128,0,128]
        let buffer = try XCTUnwrap(bytes.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        var uniforms = Uniforms(dimensions: SIMD4(2,2,4,0x36313250),
            options: SIMD4(0,709,-1,0), output: SIMD4(2,2,1,0))
        encoder.setRenderPipelineState(floatPipeline)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var result = [UInt16](repeating: 0, count: 16)
        texture.getBytes(&result, bytesPerRow: 16, from: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0)
        let first = Float(Float16(bitPattern: result[0]))
        let second = Float(Float16(bitPattern: result[4]))
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThan(second - first, 1.0 / 255.0)
    }

}
