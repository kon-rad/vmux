import XCTest
import RealityKit
@testable import vmux

@MainActor
final class SkydomeBuilderTests: XCTestCase {
    func testInwardFacingSphereProducesExpectedTopology() throws {
        let segments = 4
        let stacks = segments
        let slices = segments * 2
        let expectedVertexCount = (stacks + 1) * (slices + 1)
        let expectedTriangleCount = stacks * slices * 2

        let mesh = try SkydomeBuilder.inwardFacingSphere(radius: 30, segments: segments)
        let contents = mesh.contents
        guard let part = contents.models.first?.parts.first(where: { _ in true }) else {
            XCTFail("Generated mesh has no model parts")
            return
        }

        let positionCount = part.positions.elements.count
        XCTAssertEqual(positionCount, expectedVertexCount,
                       "Expected \(expectedVertexCount) vertices, got \(positionCount)")

        let triangleIndexCount = part.triangleIndices?.elements.count ?? 0
        XCTAssertEqual(triangleIndexCount, expectedTriangleCount * 3,
                       "Expected \(expectedTriangleCount * 3) triangle indices, got \(triangleIndexCount)")
    }

    func testInwardFacingSphereVerticesLieOnGivenRadius() throws {
        let radius: Float = 30
        let mesh = try SkydomeBuilder.inwardFacingSphere(radius: radius, segments: 8)
        guard let positions = mesh.contents.models.first?.parts.first?.positions.elements else {
            XCTFail("Generated mesh has no positions buffer")
            return
        }
        for p in positions {
            let len = simd_length(p)
            XCTAssertEqual(len, radius, accuracy: 1e-3,
                           "Vertex \(p) is not on sphere of radius \(radius); got \(len)")
        }
    }

    func testInwardFacingSphereNormalsPointInward() throws {
        let radius: Float = 30
        let mesh = try SkydomeBuilder.inwardFacingSphere(radius: radius, segments: 8)
        guard let part = mesh.contents.models.first?.parts.first,
              let normals = part.normals?.elements else {
            XCTFail("Generated mesh has no normals buffer")
            return
        }
        let positions = part.positions.elements
        XCTAssertEqual(positions.count, normals.count)
        for (p, n) in zip(positions, normals) {
            let len = simd_length(p)
            guard len > 1e-3 else { continue }
            let outward = p / len
            // dot of inward normal with outward radial should be approximately -1
            let dot = simd_dot(SIMD3<Float>(n), outward)
            XCTAssertEqual(dot, -1, accuracy: 1e-3,
                           "Normal \(n) at position \(p) is not inward-facing; dot=\(dot)")
        }
    }
}
