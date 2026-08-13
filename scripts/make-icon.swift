import AppKit
import Foundation

// 元画像を macOS のアプリアイコンの形へ収めて PNG に書き出す。
//
// 使い方: swift scripts/make-icon.swift <入力画像> <出力.png>
//
// **角丸と余白は必須。** 全面が絵柄のままだと Dock や Finder で他のアプリと
// 並んだときに浮いて見える。Apple のアイコングリッドに合わせて、1024 の
// キャンバスへ 824 の角丸四角形を中央に置く（周囲の余白は影を落とす領域）。

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data("使い方: swift scripts/make-icon.swift <入力画像> <出力.png>\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("画像を読めなかった: \(inputURL.path)\n".utf8))
    exit(1)
}

/// Apple のアイコングリッド。1024 のキャンバスに 824 の角丸四角形。
let canvas: CGFloat = 1024
let content: CGFloat = 824
let cornerRadius: CGFloat = 185.4

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let inset = (canvas - content) / 2
let frame = NSRect(x: inset, y: inset, width: content, height: content)
NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

// 元画像が正方形でなくてもよいように、中央を正方形で切り出して枠いっぱいに描く。
let size = source.size
let side = min(size.width, size.height)
let sourceRect = NSRect(
    x: (size.width - side) / 2,
    y: (size.height - side) / 2,
    width: side,
    height: side
)
source.draw(in: frame, from: sourceRect, operation: .sourceOver, fraction: 1)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("PNG へ変換できなかった\n".utf8))
    exit(1)
}

do {
    try png.write(to: outputURL)
} catch {
    FileHandle.standardError.write(Data("書き出せなかった: \(error)\n".utf8))
    exit(1)
}

print("    \(Int(canvas))x\(Int(canvas)) を書き出した（絵柄 \(Int(content))、角丸 \(cornerRadius)）")
