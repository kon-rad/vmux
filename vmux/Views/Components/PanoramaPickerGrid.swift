import SwiftUI
import UIKit

struct PanoramaPickerGrid: View {
    @Bindable var store: PanoramaStore
    var onSetActive: (String) -> Void

    @State private var deletionTarget: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)]

    var body: some View {
        Group {
            if store.availableFilenames.isEmpty {
                Text("No panoramas saved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.availableFilenames, id: \.self) { filename in
                        PanoramaThumbnail(
                            url: store.url(for: filename),
                            isActive: store.activeFilename == filename
                        )
                        .onTapGesture { onSetActive(filename) }
                        .contextMenu {
                            Button(role: .destructive) {
                                deletionTarget = filename
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel(Text(filename))
                        .accessibilityAddTraits(store.activeFilename == filename ? .isSelected : [])
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete panorama?",
            isPresented: deletionPresented,
            titleVisibility: .visible,
            presenting: deletionTarget
        ) { name in
            Button("Delete", role: .destructive) {
                try? store.delete(filename: name)
                deletionTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: { _ in
            Text("This panorama PNG will be removed from disk.")
        }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { presented in if !presented { deletionTarget = nil } }
        )
    }
}

private struct PanoramaThumbnail: View {
    let url: URL
    let isActive: Bool

    private static let side: CGFloat = 120

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnailImage
                .frame(width: Self.side, height: Self.side)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? Color.accentColor : Color.white.opacity(0.15),
                                lineWidth: isActive ? 3 : 1)
                )

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title3)
                    .padding(6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.25)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    PanoramaPickerGrid(store: .shared, onSetActive: { _ in })
        .padding()
}
