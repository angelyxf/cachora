import SwiftUI

struct ScanIssuesView: View {
    let issues: [ScanIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Scan incomplete", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text("Some locations could not be read. Their sizes are unknown and are not included in the total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(issues) { issue in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.kind == .permissionDenied ? "Permission required" : "Read failed")
                                        .font(.caption.weight(.medium))
                                    Text(issue.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(issue.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Text(String(format: String(localized: "Skipped locations (%lld)"), Int64(issues.count)))
                        .font(.caption)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.22)))
        }
    }
}
