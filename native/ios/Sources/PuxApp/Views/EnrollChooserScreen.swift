#if os(iOS)
import SwiftUI
import PuxCore

public struct EnrollChooserScreen: View {
    let onEnrolled: () -> Void

    public init(onEnrolled: @escaping () -> Void) {
        self.onEnrolled = onEnrolled
    }

    public var body: some View {
        PuxStackNavigation {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 20)

                    Image(systemName: "lock.shield")
                        .font(.system(size: 64))
                        .foregroundColor(PuxTheme.primary)
                        .padding(.bottom, 8)

                    Text("Create a new encrypted OTP relay, or add this device to an existing one.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                        .padding(.horizontal)

                    VStack(spacing: 16) {
                        NavigationLink(destination: CreateRelayScreen(onEnrolled: onEnrolled)) {
                            Text("Create new relay")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(PuxTheme.primary)
                                .foregroundColor(PuxTheme.onPrimary)
                                .cornerRadius(12)
                        }

                        NavigationLink(destination: EnrollScreen(onEnrolled: onEnrolled)) {
                            Text("Add to existing relay")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.clear)
                                .foregroundColor(PuxTheme.primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(PuxTheme.border, lineWidth: 2)
                                )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    Text("Keys are generated on this phone. The private key leaves it only if you add another device.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)

                    Spacer(minLength: 20)
                }
                .padding(.vertical)
            }
            .background(PuxTheme.background.ignoresSafeArea())
            .navigationTitle("Set up pux")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
