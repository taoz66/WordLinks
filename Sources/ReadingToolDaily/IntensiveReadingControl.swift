import AppKit
import SwiftUI

/// Keep the toolbar action native; selection is an icon state, not a primary-action tint.
struct IntensiveReadingControl: View {
    @ObservedObject var model: IntensiveReadingModel
    @State private var isProgressPresented = false

    private var state: IntensiveReadingToolbarState {
        IntensiveReadingToolbarState(isGenerating: model.isGenerating, isActivated: model.isActivated)
    }

    var body: some View {
        Button {
            if model.isGenerating {
                isProgressPresented = true
            } else {
                model.setActivated(!model.isActivated)
                isProgressPresented = model.isGenerating || model.progress.issue != nil
            }
        } label: {
            Label {
                Text(L("精读", "Intensive Reading"))
            } icon: {
                ReaderToolbarIcon(systemName: "append.page", activeSystemName: "append.page.fill",
                                  isActive: model.isActivated, isLoading: model.isGenerating)
            }
        }
        .labelStyle(.iconOnly)
        .background {
            IntensiveReadingToolbarHitTarget()
                .frame(width: 28, height: 28)
        }
        .accessibilityLabel(L("精读", "Intensive Reading"))
        .accessibilityIdentifier("reader.intensive.toggle")
        .accessibilityAddTraits(model.isActivated ? .isSelected : [])
        .accessibilityValue(state == .loading
                            ? L("正在分析文本", "Analyzing text")
                            : (state == .active ? L("已开启", "On") : L("已关闭", "Off")))
        .help(L("切换精读；生成时点击查看本篇进度", "Toggle intensive reading; click during generation for this article’s progress"))
        .popover(isPresented: $isProgressPresented, arrowEdge: .bottom) {
            IntensiveReadingProgressPopover(model: model, onCancel: {
                model.cancel()
                isProgressPresented = false
            })
        }
        .onChange(of: model.progress) { _, progress in
            if progress.isComplete { isProgressPresented = false }
        }
    }
}

/// Native geometry for the window's toolbar context-menu routing. This view
/// draws nothing and never participates in mouse or accessibility handling.
struct IntensiveReadingToolbarHitTarget: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("reader.intensive.hitTarget")

    func makeNSView(context: Context) -> HitTargetView {
        let view = HitTargetView()
        view.identifier = Self.identifier
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: HitTargetView, context: Context) {}

    final class HitTargetView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Reserve the same symbol slot through loading and mode changes; AppKit owns
/// the toolbar button's outside dimensions, glass, hover and press treatment.
struct ReaderToolbarIcon: View {
    let systemName: String
    var activeSystemName: String? = nil
    var isActive = false
    var isLoading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: isActive ? (activeSystemName ?? systemName) : systemName)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : isActive)
                .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        // No imageScale or font here: the toolbar supplies the system symbol
        // size, so the icons match other Mac apps. The minimum slot only keeps
        // the symbol from shifting while it swaps or loads.
        .frame(minWidth: 18, minHeight: 18)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isLoading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isActive)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

private struct IntensiveReadingProgressPopover: View {
    @ObservedObject var model: IntensiveReadingModel
    let onCancel: () -> Void

    private var fractionCompleted: Double {
        guard model.progress.totalCount > 0 else { return 0 }
        return min(1, Double(model.progress.completedCount) / Double(model.progress.totalCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.progress.issue ?? L("正在调用AI分析文本，模型水平会影响分析质量",
                                           "Asking AI to analyze the text. Model capability influences analysis quality."))
                .font(.caption)
            HStack(spacing: 10) {
                ProgressView(value: fractionCompleted)
                    .accessibilityLabel(L("精读生成进度", "Intensive reading generation progress"))
                    .accessibilityValue("\(model.progress.completedCount) / \(model.progress.totalCount)")
                if model.isGenerating {
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L("取消生成", "Cancel generation"))
                }
            }
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
    }
}
