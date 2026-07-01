import AppKit
import CoreImage.CIFilterBuiltins

// Shared QR generator (CoreImage). Used for both the "download app" QR and the
// "pair this desktop" QR so the two stay pixel-consistent.
func makeQR(_ string: String, size: CGFloat) -> NSImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let ci = filter.outputImage else { return NSImage(size: .init(width: size, height: size)) }
    let scale = size / ci.extent.width
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
}

// Build the pairing QR payload — MUST stay identical to pocket-pair.py:
//   pocket://pair?scheme=<scheme>&host=<host>&code=<code>
func pairingPayload(scheme: String, host: String, code: String) -> String {
    let allowed = CharacterSet.urlQueryAllowed
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    return "pocket://pair?scheme=\(enc(scheme))&host=\(enc(host))&code=\(enc(code))"
}
