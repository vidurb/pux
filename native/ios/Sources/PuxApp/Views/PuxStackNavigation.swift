#if os(iOS)
import SwiftUI

/// Full-width navigation on iPhone and iPad (avoids split-column `NavigationView` on iPad).
public struct PuxStackNavigation<Content: View>: View {
  @ViewBuilder private let content: () -> Content

  public init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  public var body: some View {
    if #available(iOS 16.0, *) {
      NavigationStack(root: content)
    } else {
      NavigationView(content: content)
        .navigationViewStyle(.stack)
    }
  }
}
#endif
