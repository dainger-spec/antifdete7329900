import SwiftUI
import VMControllerCore

/// Full-window setup screen shown while the environment comes up (first launch
/// and image download). Light, SF Pro, with an auto-advancing carousel of
/// benefit cards so the wait reads as progress, not a hang. Stage text + a thin
/// bar + Cancel sit at the bottom.
struct SplashView: View {
    @ObservedObject var model: LauncherModel
    @State private var card = 0

    private let cards = CarouselDeck.cards
    private let tick = Timer.publish(every: CarouselDeck.interval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            carousel
            Spacer()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(tick) { _ in
            withAnimation(.easeInOut(duration: 0.5)) { card = CarouselDeck.next(after: card) }
        }
    }

    private var carousel: some View {
        VStack(spacing: 20) {
            ForEach(cards) { item in
                if item.id == card {
                    VStack(spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(height: 56)
                        Text(item.title)
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)
                        Text(item.subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                                            removal: .opacity.combined(with: .move(edge: .leading))))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)

        .overlay(alignment: .bottom) { dots.offset(y: 44) }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(cards) { item in
                Circle()
                    .fill(item.id == card ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Отмена", role: .cancel) { model.cancel() }
                    .disabled(!model.canCancel)
            }
            ProgressView(value: model.progress.fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: model.progress.fraction)
            Text("Повторный запуск будет быстрее — результат проверки окружения кэшируется.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(.regularMaterial)
    }
}
