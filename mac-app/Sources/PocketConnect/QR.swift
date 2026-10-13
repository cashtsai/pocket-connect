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
