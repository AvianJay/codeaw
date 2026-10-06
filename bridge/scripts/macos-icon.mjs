const number = (value) => Number(value.toFixed(6)).toString();
const point = (horizontal, vertical) => `CGPoint(x: ${number(horizontal)}, y: ${number(vertical)})`;

export function swiftIconPath(xml) {
  const data = xml.match(/android:pathData="([^"]+)"/)?.[1];
  if (!data) throw new Error("The Flutter monochrome icon has no vector path");
  const tokens = data.match(/[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?/g) ?? [];
  const commands = [];
  let index = 0;
  let horizontal = 0;
  let vertical = 0;
  let startHorizontal = 0;
  let startVertical = 0;
  const values = (count) => {
    const result = tokens.slice(index, index + count).map(Number);
    if (result.length !== count || result.some((value) => !Number.isFinite(value))) throw new Error("Invalid Flutter icon path coordinates");
    index += count;
    return result;
  };
  while (index < tokens.length) {
    const command = tokens[index++];
    if (command === "M" || command === "L") {
      [horizontal, vertical] = values(2);
      if (command === "M") { startHorizontal = horizontal; startVertical = vertical; }
      commands.push(`path.${command === "M" ? "move" : "addLine"}(to: ${point(horizontal, vertical)})`);
    } else if (command === "C") {
      const [firstHorizontal, firstVertical, secondHorizontal, secondVertical, endHorizontal, endVertical] = values(6);
      commands.push(`path.addCurve(to: ${point(endHorizontal, endVertical)}, control1: ${point(firstHorizontal, firstVertical)}, control2: ${point(secondHorizontal, secondVertical)})`);
      horizontal = endHorizontal; vertical = endVertical;
    } else if (command === "A") {
      const [radiusHorizontal, radiusVertical, rotation, largeArc, sweep, endHorizontal, endVertical] = values(7);
      if (radiusHorizontal !== radiusVertical || radiusHorizontal <= 0 || rotation !== 0 || ![0, 1].includes(largeArc) || ![0, 1].includes(sweep)) {
        throw new Error("Flutter icon requires an unsupported elliptical arc");
      }
      const deltaHorizontal = (horizontal - endHorizontal) / 2;
      const deltaVertical = (vertical - endVertical) / 2;
      const distanceSquared = deltaHorizontal ** 2 + deltaVertical ** 2;
      if (!distanceSquared) throw new Error("Flutter icon has a zero-length arc");
      const radius = Math.max(radiusHorizontal, Math.sqrt(distanceSquared));
      const factor = (largeArc === sweep ? -1 : 1) * Math.sqrt(Math.max(0, (radius ** 2 - distanceSquared) / distanceSquared));
      const centerHorizontal = (horizontal + endHorizontal) / 2 + factor * deltaVertical;
      const centerVertical = (vertical + endVertical) / 2 - factor * deltaHorizontal;
      const start = Math.atan2(vertical - centerVertical, horizontal - centerHorizontal);
      let angle = Math.atan2(endVertical - centerVertical, endHorizontal - centerHorizontal) - start;
      if (sweep === 1 && angle < 0) angle += 2 * Math.PI;
      if (sweep === 0 && angle > 0) angle -= 2 * Math.PI;
      const segments = Math.ceil(Math.abs(angle) / (Math.PI / 2));
      for (let segment = 0; segment < segments; segment++) {
        const first = start + angle * segment / segments;
        const second = start + angle * (segment + 1) / segments;
        const tangent = 4 / 3 * Math.tan((second - first) / 4);
        const firstHorizontal = centerHorizontal + radius * (Math.cos(first) - tangent * Math.sin(first));
        const firstVertical = centerVertical + radius * (Math.sin(first) + tangent * Math.cos(first));
        const secondHorizontal = centerHorizontal + radius * (Math.cos(second) + tangent * Math.sin(second));
        const secondVertical = centerVertical + radius * (Math.sin(second) - tangent * Math.cos(second));
        const targetHorizontal = segment === segments - 1 ? endHorizontal : centerHorizontal + radius * Math.cos(second);
        const targetVertical = segment === segments - 1 ? endVertical : centerVertical + radius * Math.sin(second);
        commands.push(`path.addCurve(to: ${point(targetHorizontal, targetVertical)}, control1: ${point(firstHorizontal, firstVertical)}, control2: ${point(secondHorizontal, secondVertical)})`);
      }
      horizontal = endHorizontal; vertical = endVertical;
    } else if (command === "Z") {
      commands.push("path.closeSubpath()");
      horizontal = startHorizontal; vertical = startVertical;
    } else throw new Error(`Unsupported Flutter icon path command: ${command}`);
  }
  return commands.join("\n    ");
}

export function swiftMenuIcon(xml) {
  return `import AppKit

func codeawMenuIcon() -> NSImage {
    let path = CGMutablePath()
    ${swiftIconPath(xml)}
    let bounds = path.boundingBoxOfPath
    let size = NSSize(width: 18, height: 18)
    let scale = 16 / max(bounds.width, bounds.height)
    let image = NSImage(size: size, flipped: true) { _ in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.drawPath(using: .eoFill)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "codeaw"
    return image
}
`;
}
