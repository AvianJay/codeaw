import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
  private func extra(corner: CGFloat, bar: CGRect, safe: CGFloat, previous: CGFloat = 0,
                     hosted: Bool = false, fillsScreen: Bool = false) -> CGFloat {
    CodeawViewController.additionalTop(
      bounds: bounds, cornerBand: CGRect(x: 0, y: 0, width: bounds.width, height: corner),
      statusBar: bar, safeTop: safe, previous: previous, hosted: hosted, fillsScreen: fillsScreen)
  }

  func testOverlappingStatusBarAndControlsReserveOneBand() {
    let bar = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 0, bar: bar, safe: 0), 24)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 24), 40)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 64, previous: 40), 40)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 72), 0)
  }

  func testHostedWindowWithMissingOrPartialMetrics() {
    XCTAssertEqual(extra(corner: 0, bar: .zero, safe: 0, hosted: true, fillsScreen: true), 68)
    XCTAssertEqual(extra(corner: 0, bar: .zero, safe: 68, previous: 68, hosted: true), 44)
    let bar = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 24, bar: bar, safe: 24, hosted: true), 44)
    XCTAssertEqual(extra(corner: 80, bar: bar, safe: 80, hosted: true), 0)
  }

  func testMovingWindowReleasesObsoleteInset() {
    let aboveWindow = CGRect(x: 0, y: -32, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 44, bar: aboveWindow, safe: 64, previous: 64), 44)
    XCTAssertEqual(extra(corner: 0, bar: aboveWindow, safe: 44, previous: 44), 0)
    XCTAssertEqual(extra(corner: 0, bar: .zero, safe: 0), 0)
  }
}
