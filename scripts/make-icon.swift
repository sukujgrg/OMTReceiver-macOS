import AppKit
let output=CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
        let c=NSGraphicsContext.current!.cgContext
        c.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        let path=NSBezierPath(roundedRect:NSRect(x:72,y:72,width:880,height:880),xRadius:196,yRadius:196)
        let gradient=NSGradient(starting:NSColor(srgbRed:0.14,green:0.21,blue:0.25,alpha:1),ending:NSColor(srgbRed:0.04,green:0.07,blue:0.09,alpha:1))!
        gradient.draw(in:path,angle:90)
        let screen=NSBezierPath(roundedRect:NSRect(x:208,y:300,width:608,height:440),xRadius:52,yRadius:52)
        NSColor(srgbRed:0.64,green:0.95,blue:0.83,alpha:1).setStroke();screen.lineWidth=28;screen.stroke()
        let play=NSBezierPath();play.move(to:.init(x:445,y:418));play.line(to:.init(x:445,y:622));play.line(to:.init(x:610,y:520));play.close()
        NSColor(srgbRed:0.36,green:0.91,blue:0.68,alpha:1).setFill();play.fill()
        let foot=NSBezierPath();foot.move(to:.init(x:402,y:228));foot.line(to:.init(x:622,y:228));foot.lineWidth=28;foot.lineCapStyle = .round;foot.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix=scale==2 ? "@2x" : ""
        let url=URL(fileURLWithPath:output).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
}
