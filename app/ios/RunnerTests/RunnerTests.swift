import UIKit
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  private let bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
  private func extra(corner: CGFloat, bar: CGRect, safe: CGFloat, previous: CGFloat = 0) -> CGFloat {
    CodeawViewController.additionalTop(
      bounds: bounds, cornerBand: CGRect(x: 0, y: 0, width: bounds.width, height: corner),
      statusBar: bar, safeTop: safe, previous: previous)
  }

  func testOverlappingStatusBarAndControlsReserveOneBand() {
    let bar = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 0, bar: bar, safe: 0), 24)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 24), 40)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 64, previous: 40), 40)
    XCTAssertEqual(extra(corner: 64, bar: bar, safe: 72), 0)
  }

  func testStatusBarAloneDoesNotReserveAWindowControlRow() {
    let bar = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 0, bar: bar, safe: 24), 0)
    XCTAssertEqual(extra(corner: 24, bar: bar, safe: 24), 0)
    XCTAssertEqual(extra(corner: 24, bar: bar, safe: 68, previous: 44), 0)
  }

  func testMovingWindowReleasesObsoleteInset() {
    let aboveWindow = CGRect(x: 0, y: -32, width: bounds.width, height: 24)
    XCTAssertEqual(extra(corner: 44, bar: aboveWindow, safe: 64, previous: 40), 20)
    XCTAssertEqual(extra(corner: 0, bar: aboveWindow, safe: 44, previous: 20), 0)
    XCTAssertEqual(extra(corner: 0, bar: .zero, safe: 0), 0)
  }
}
