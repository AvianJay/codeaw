import Flutter
import UIKit

final class CodeawViewController: FlutterViewController {
  // LiveContainer sets this marker in its guest bootstrap. Its host can draw
  // controls outside the guest scene, so UIKit alone cannot always see them.
  private static let isLiveContainerGuest = getenv("LC_HOME_PATH") != nil

  override func viewDidLayoutSubviews() {
    if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .pad,
       let window = view.window, let scene = window.windowScene {
      // Measure the window, not our already-adjusted safe area. The traffic
      // lights occupy a corner that ordinary four-edge insets can omit.
      let cornerTop = window.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
      let cornerBand = CGRect(origin: window.bounds.origin,
                              size: CGSize(width: window.bounds.width, height: cornerTop))
      let statusBar = scene.statusBarManager?.statusBarFrame ?? .zero
      let screen = scene.screen.coordinateSpace
      let fillsScreen = window.convert(window.bounds, to: screen) == screen.bounds
      let extra = Self.additionalTop(
        bounds: view.bounds,
        cornerBand: view.convert(cornerBand, from: window),
        statusBar: view.convert(statusBar, from: scene.coordinateSpace),
        safeTop: view.safeAreaInsets.top, previous: additionalSafeAreaInsets.top,
        hosted: Self.isLiveContainerGuest, fillsScreen: fillsScreen)
      if extra != additionalSafeAreaInsets.top {
        additionalSafeAreaInsets.top = extra
      }
    }
    super.viewDidLayoutSubviews()
  }

  // All rectangles are in the Flutter view's coordinates. In a floating
  // window the status bar can be entirely outside the view.
  nonisolated static func additionalTop(bounds: CGRect, cornerBand: CGRect, statusBar: CGRect,
                            safeTop: CGFloat, previous: CGFloat,
                            hosted: Bool, fillsScreen: Bool) -> CGFloat {
    func occupiedTop(_ rect: CGRect) -> CGFloat {
      let overlap = bounds.intersection(rect)
      return overlap.isEmpty ? 0 : overlap.maxY - bounds.minY
    }
    let statusTop = occupiedTop(statusBar)
    // A hosted floating window needs one control row. A hosted full-screen
    // window can also have a status row, even if both guest metrics are zero.
    let hostTop: CGFloat = hosted ? max(statusTop, fillsScreen ? 24 : 0) + 44 : 0
    let required = max(occupiedTop(cornerBand), statusTop, hostTop)
    let systemTop = max(0, safeTop - previous)
    return max(0, required - systemTop)
  }
}
