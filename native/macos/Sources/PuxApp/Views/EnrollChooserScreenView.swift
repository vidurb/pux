import SwiftUI

public struct EnrollChooserScreenView: View {
    public let onImport: () -> Void

    public init(onImport: @escaping () -> Void) {
        self.onImport = onImport
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.shield")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundColor(.accentColor)

            Text("Set up pux")
                .font(.title)
                .bold()

            Text("Import an existing relay to receive OTP codes on this computer.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 32)

            Button(action: onImport) {
                Text("Import enrollment")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Keys are created on your phone. Importing its enrollment gives this computer a copy, so it decrypts codes itself.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 48)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 450, minHeight: 400)
    }
}
