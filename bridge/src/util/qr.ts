import QRCode from "qrcode";

/** Renders a QR code with half-block characters (two modules per text row). */
export async function terminalQr(text: string): Promise<string> {
  return QRCode.toString(text, { type: "terminal", small: true, errorCorrectionLevel: "L" });
}
