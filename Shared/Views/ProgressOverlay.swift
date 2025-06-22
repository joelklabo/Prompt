import SwiftUI

struct ProgressOverlay: View {
    let progressState: ProgressState

    var body: some View {
        if progressState.isShowingProgress, let operation = progressState.currentOperation {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)

                VStack(spacing: 16) {
                    if operation.isIndeterminate {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(1.5)
                    } else if let progress = operation.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                    }

                    Text(operation.message ?? "")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                        .shadow(radius: 10)
                )
                .transition(.scale.combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.2), value: progressState.isShowingProgress)
        }
    }
}

extension View {
    func progressOverlay(_ progressState: ProgressState) -> some View {
        self.overlay(ProgressOverlay(progressState: progressState))
    }
}
