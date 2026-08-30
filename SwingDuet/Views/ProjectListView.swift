import SwiftUI

struct ProjectListView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var path: [UUID] = []
    @State private var showingNew = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView(
                        "比較プロジェクトがありません",
                        systemImage: "figure.golf",
                        description: Text("右上の＋から、自分のスイングとお手本の動画を読み込んで比較を始めましょう。"))
                } else {
                    List {
                        ForEach(store.projects) { project in
                            NavigationLink(value: project.id) {
                                ProjectRow(project: project)
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("スイング比較")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let project = store.projects.first(where: { $0.id == id }) {
                    ComparisonView(project: project, store: store)
                } else {
                    Text("プロジェクトが見つかりません")
                }
            }
            .sheet(isPresented: $showingNew) {
                NewComparisonView { project in
                    path.append(project.id)
                }
                .environmentObject(store)
            }
        }
    }
}

private struct ProjectRow: View {
    let project: ComparisonProject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack(spacing: 12) {
                Text(project.createdAt, format: .dateTime.month().day().hour().minute())
                Text("自分 \(project.mine.phases.tempoText)")
                Text("お手本 \(project.model.phases.tempoText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
