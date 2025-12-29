import SwiftUI

struct StartupLoadingView: View {
    var body: some View {
        ZStack {
            // Background
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Arkansas Benchmarks")
                        .font(.headline)

                    Text("Loading benchmarks…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .padding(.top, 8)
            }
        }
    }
}
