import SwiftUI

/// First-launch setup: permissions and the hotkey. (Placeholder, replaced by the UI slice.)
public struct OnboardingView: View {
    let context: DictationUIContext
    let onFinish: @MainActor () -> Void

    public init(context: DictationUIContext, onFinish: @escaping @MainActor () -> Void) {
        self.context = context
        self.onFinish = onFinish
    }

    public var body: some View {
        Button("Done") { onFinish() }
    }
}
