import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query private var allTabs: [Tab]
    @State private var selectedProjectID: UUID?
    @State private var showingNewProjectSheet = false

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    private var visibleTabs: [Tab] {
        guard let id = selectedProjectID else { return [] }
        return allTabs
            .filter { $0.project?.id == id }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                projectsSection

                if let project = selectedProject {
                    tabsSection(for: project)
                }
            }

            Divider()

            HStack {
                Button {
                    openWindow(id: "settings")
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)

                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 340, minHeight: 640)
        .sheet(isPresented: $showingNewProjectSheet) {
            NewProjectSheet()
        }
    }

    private var projectsSection: some View {
        Section("Projects") {
            ForEach(projects, id: \.id) { project in
                Button {
                    selectedProjectID = project.id
                } label: {
                    HStack {
                        Text(project.name)
                        Spacer()
                        if selectedProjectID == project.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        deleteProject(project)
                    }
                }
            }

            Button(action: addProject) {
                Label("New Project", systemImage: "plus")
            }
        }
    }

    private func tabsSection(for project: Project) -> some View {
        Section("Tabs in \(project.name)") {
            ForEach(visibleTabs, id: \.id) { tab in
                Button {
                    openWindow(id: "terminal", value: tab.id)
                } label: {
                    HStack {
                        Circle()
                            .fill(.gray)
                            .frame(width: 8, height: 8)
                        Text(tab.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Close", role: .destructive) {
                        closeTab(tab)
                    }
                }
            }

            Button {
                addTab(in: project)
            } label: {
                Label("New Tab", systemImage: "plus")
            }
        }
    }

    private func addProject() {
        showingNewProjectSheet = true
    }

    private func addTab(in project: Project) {
        _ = project
    }

    private func deleteProject(_ project: Project) {
        if selectedProjectID == project.id {
            selectedProjectID = nil
        }
        modelContext.delete(project)
    }

    private func closeTab(_ tab: Tab) {
        modelContext.delete(tab)
    }
}

#Preview {
    SidebarView()
        .modelContainer(for: [Project.self, Tab.self, AppSettings.self], inMemory: true)
}
