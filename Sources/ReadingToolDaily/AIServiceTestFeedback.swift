import SwiftUI

enum AIServiceTestState: Equatable {
    case idle, testing, available, unavailable
}

/// All providers use the same compact feedback immediately after the Test button.
struct AIServiceTestFeedback: View {
    let state: AIServiceTestState

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .testing:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 16)
                    .accessibilityLabel(L("正在测试", "Testing"))
            case .available, .unavailable:
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .accessibilityHidden(true)
                    Text(state == .available ? L("服务可用", "Service available") : L("服务不可用", "Service unavailable"))
                        .font(.caption)
                }
                .foregroundStyle(state == .available ? Color.green : Color.red)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
