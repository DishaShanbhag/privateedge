import SwiftUI

// Shared pieces of the user-facing screens (Calendar and Notes).

/// "On device · works offline": the app's core promise, always visible.
struct PrivacyPill: View {
    var body: some View {
        Label("On device · works offline", systemImage: "lock.shield.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(.green)
            .accessibilityLabel("Private: runs on this phone and works offline")
    }
}

/// Shown until the model is ready (first launch reads a 2 GB file).
struct ModelBanner: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        switch app.state {
        case .ready:
            EmptyView()
        case .loading, .idle:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Getting the assistant ready…").font(.subheadline.weight(.semibold))
                    Text("Loading the on-device model. This takes a few seconds.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        case .missing:
            banner("The model file is missing", "Open Lab › Model to see how to add it.", "exclamationmark.triangle.fill", .orange)
        case .failed(let e):
            banner("The model could not load", e, "xmark.octagon.fill", .red)
        }
    }
    private func banner(_ title: String, _ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The user's own message, right-aligned like a chat.
struct UserBubble: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }
}

/// While the model works: a spinner, elapsed seconds, and what it has written so far.
struct ThinkingCard: View {
    let started: Date
    let partial: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Thinking on your phone…").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(ctx.date.timeIntervalSince(started))) s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                #if targetEnvironment(simulator)
                Text("The Simulator runs the model on the Mac's CPU, so this takes a few minutes here; seconds on an iPhone.")
                    .font(.caption2).foregroundStyle(.secondary)
                #endif
                if !partial.isEmpty {
                    Text(partial).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
    }
}

/// A card with a coloured icon, used for every kind of answer.
struct AnswerCard<Content: View>: View {
    let icon: String
    let color: Color
    let kind: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color, in: RoundedRectangle(cornerRadius: 8))
                Text(kind.uppercased()).font(.caption.weight(.bold)).foregroundStyle(color)
                Spacer()
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Bottom input bar: text, microphone, send.
struct ChatInputBar: View {
    @Binding var text: String
    let placeholder: String
    let busy: Bool
    let enabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }
            MicButton(text: $text)
                .padding(.bottom, 6)
            Button(action: onSend) {
                Image(systemName: busy ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        enabled && !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Tappable example prompts for an empty screen.
struct ExampleChips: View {
    let title: String
    let examples: [String]
    let pick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { ex in
                Button { pick(ex) } label: {
                    HStack {
                        Text(ex).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.caption)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Launch-argument hook for screenshots and checks: `-demoCalendar "msg"`, `-demoNotes "q"`.
func demoArgument(_ flag: String) -> String? {
    let args = ProcessInfo.processInfo.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
