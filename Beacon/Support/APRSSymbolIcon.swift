import SwiftUI
import UIKit

struct APRSSymbolIcon: View {
    let symbol: APRSSymbol
    var size: CGFloat = 32
    var overlay: Character?

    var body: some View {
        ZStack {
            if let image = symbol.spriteImage {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol.systemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
                    .padding(4)
            }
            if let overlay {
                Text(String(overlay))
                    .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1, x: 0, y: 1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private extension APRSSymbol {
    var spriteImage: UIImage? {
        guard let ascii = code.asciiValue, ascii >= 33, ascii <= 126 else { return nil }
        let sheetName = table == .primary ? "aprs-symbols-64-0" : "aprs-symbols-64-1"
        guard let sheet = UIImage(named: sheetName)?.cgImage else { return nil }

        let symbolIndex = Int(ascii) - 33
        let column = symbolIndex % 16
        let row = symbolIndex / 16
        let cellWidth = sheet.width / 16
        let cellHeight = sheet.height / 6
        let crop = CGRect(
            x: column * cellWidth,
            y: row * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        guard let image = sheet.cropping(to: crop) else { return nil }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}
