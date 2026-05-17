import SwiftUI
import RealityKit
import UIKit

struct SkydomeView: View {
    @State private var store: PanoramaStore = .shared
    @State private var skydomeEntity: ModelEntity?

    var body: some View {
        RealityView { content in
            let entity = await SkydomeBuilder.makeSkydome(image: store.activeImage)
            entity.name = SkydomeBuilder.entityName
            content.add(entity)
            skydomeEntity = entity
        }
        .onChange(of: store.activeFilename) { _, _ in
            let entity = skydomeEntity
            let image = store.activeImage
            Task { @MainActor in
                guard let entity else { return }
                await SkydomeBuilder.applyMaterial(to: entity, image: image)
            }
        }
    }
}

enum SkydomeBuilder {
    static let radius: Float = 30
    static let placeholderAssetName = "PlaceholderPanorama"
    static let entityName = "skydome"

    @MainActor
    static func makeSkydome(image: UIImage? = nil) async -> ModelEntity {
        let entity = ModelEntity()
        let mesh: MeshResource
        do {
            mesh = try inwardFacingSphere(radius: radius)
        } catch {
            mesh = .generateSphere(radius: radius)
            entity.scale = SIMD3<Float>(-1, 1, 1)
        }
        let material = await makeMaterial(image: image)
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        return entity
    }

    @MainActor
    static func applyMaterial(to entity: ModelEntity, image: UIImage?) async {
        let material = await makeMaterial(image: image)
        guard var component = entity.components[ModelComponent.self] else { return }
        component.materials = [material]
        entity.components.set(component)
    }

    @MainActor
    static func makeMaterial(image: UIImage?) async -> UnlitMaterial {
        var material = UnlitMaterial()
        if let image, let texture = await texture(for: image) {
            material.color = .init(texture: .init(texture))
        } else if let placeholder = await loadPlaceholderTexture() {
            material.color = .init(texture: .init(placeholder))
        } else {
            material.color = .init(tint: .darkGray)
        }
        return material
    }

    @MainActor
    private static func loadPlaceholderTexture() async -> TextureResource? {
        try? await TextureResource(named: placeholderAssetName)
    }

    @MainActor
    private static func texture(for image: UIImage) async -> TextureResource? {
        guard let cgImage = image.cgImage else { return nil }
        do {
            return try await TextureResource(image: cgImage, options: .init(semantic: .color))
        } catch {
            return nil
        }
    }

    @MainActor
    static func inwardFacingSphere(radius: Float, segments: Int = 48) throws -> MeshResource {
        precondition(segments >= 4, "segments must be at least 4")
        let stacks = segments
        let slices = segments * 2

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texCoords: [SIMD2<Float>] = []
        positions.reserveCapacity((stacks + 1) * (slices + 1))
        normals.reserveCapacity(positions.capacity)
        texCoords.reserveCapacity(positions.capacity)

        for stack in 0...stacks {
            let v = Float(stack) / Float(stacks)
            let phi = Float.pi * v
            let sinPhi = sin(phi)
            let cosPhi = cos(phi)
            for slice in 0...slices {
                let u = Float(slice) / Float(slices)
                let theta = 2 * Float.pi * u
                let x = radius * sinPhi * cos(theta)
                let y = radius * cosPhi
                let z = radius * sinPhi * sin(theta)
                positions.append(SIMD3<Float>(x, y, z))
                let outward = SIMD3<Float>(x, y, z)
                let len = simd_length(outward)
                let unit = len > 0 ? outward / len : SIMD3<Float>(0, 1, 0)
                normals.append(-unit)
                texCoords.append(SIMD2<Float>(u, v))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(stacks * slices * 6)
        let cols = slices + 1
        for stack in 0..<stacks {
            for slice in 0..<slices {
                let tl = UInt32(stack * cols + slice)
                let tr = UInt32(stack * cols + slice + 1)
                let bl = UInt32((stack + 1) * cols + slice)
                let br = UInt32((stack + 1) * cols + slice + 1)
                indices.append(tl); indices.append(tr); indices.append(bl)
                indices.append(tr); indices.append(br); indices.append(bl)
            }
        }

        var descriptor = MeshDescriptor(name: "skydome")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}

#Preview {
    SkydomeView()
}
