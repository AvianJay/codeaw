import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { swiftIconPath, swiftMenuIcon } from "../bridge/scripts/macos-icon.mjs";

test("macOS icon uses the Flutter vector with transparent terminal cutouts", () => {
  const xml = readFileSync(new URL("../app/android/app/src/main/res/drawable/ic_launcher_monochrome.xml", import.meta.url), "utf8");
  const source = swiftMenuIcon(xml);
  assert.match(source, /path.move\(to: CGPoint\(x: 44, y: 31\)\)/);
  assert.equal((source.match(/path.closeSubpath\(\)/g) ?? []).length, 3);
  assert.match(source, /drawPath\(using: \.eoFill\)/);
  assert.match(source, /image.isTemplate = true/);
  assert.doesNotMatch(source, /NaN|Infinity|systemSymbolName/);
});

test("circular SVG arcs retain endpoints and become native vector curves", () => {
  const result = swiftIconPath('<path android:pathData="M0,0A10,10 0 0 1 10,10Z"/>');
  assert.match(result, /path.addCurve\(to: CGPoint\(x: 10, y: 10\), control1: CGPoint\(x: 5.522847, y: 0\), control2: CGPoint\(x: 10, y: 4.477153\)\)/);
  assert.throws(() => swiftIconPath('<path android:pathData="M0,0A10,8 0 0 1 10,10Z"/>'), /elliptical/);
});

test("invalid paths fail the build rather than silently changing the icon", () => {
  assert.throws(() => swiftIconPath("<vector/>"), /no vector/);
  assert.throws(() => swiftIconPath('<path android:pathData="M0,0Q1,2 3,4Z"/>'), /Unsupported/);
  assert.throws(() => swiftIconPath('<path android:pathData="M0,0L1Z"/>'), /coordinates/);
});
