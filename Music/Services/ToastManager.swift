//  Global toast manager for showing notifications above all views including sheets

import SwiftUI
import UIKit

// MARK: - Toast Window (appears above all sheets)

class ToastWindow: UIWindow {
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        // Set window level above alerts to ensure it's always on top
        windowLevel = .alert + 1
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Allow touches to pass through to views below when not hitting the toast
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        // If the hit view is the window itself or the hosting controller's root view, pass through
        if view == self || view == rootViewController?.view {
            return nil
        }
        return view
    }
}

final class ToastWindowHolder: @unchecked Sendable {
    static let shared = ToastWindowHolder()
    var window: ToastWindow?
}

@MainActor
class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var isShowing = false
    @Published var message = ""
    @Published var icon = "checkmark.circle.fill"
    @Published var color: Color = .green

    private var hideTask: Task<Void, Never>?

    private init() {
        setupNotificationListener()
    }

    private func setupNotificationListener() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowAddedToPlaylistToast"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let userInfo = notification.userInfo,
               let playlistName = userInfo["playlistName"] as? String {
                Task { @MainActor in
                    self.show(
                        message: String(format: NSLocalizedString("added_to_playlist", value: "Added to %@", comment: "Toast message when track added to playlist"), playlistName),
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowRemovedFromPlaylistToast"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            if let userInfo = notification.userInfo,
               let playlistName = userInfo["playlistName"] as? String {
                Task { @MainActor in
                    self.show(
                        message: String(format: NSLocalizedString("removed_from_playlist", value: "Removed from %@", comment: "Toast message when track removed from playlist"), playlistName),
                        icon: "minus.circle.fill",
                        color: .red
                    )
                }
            }
        }
    }

    func show(message: String, icon: String = "checkmark.circle.fill", color: Color = .green, duration: TimeInterval = 3.0) {
        // Cancel any pending hide task
        hideTask?.cancel()

        self.message = message
        self.icon = icon
        self.color = color

        withAnimation(.easeInOut(duration: 0.2)) {
            isShowing = true
        }

        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.isShowing = false
                    }
                }
            }
        }
    }
}

struct GlobalToastOverlay: View {
    @ObservedObject var toastManager = ToastManager.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear

                if toastManager.isShowing {
                    VStack {
                        Spacer()

                        HStack {
                            Image(systemName: toastManager.icon)
                                .foregroundColor(toastManager.color)
                                .font(.system(size: 16, weight: .medium))
                            Text(toastManager.message)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 120 + geometry.safeAreaInsets.bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: toastManager.isShowing)
        }
        .ignoresSafeArea()
    }
}
