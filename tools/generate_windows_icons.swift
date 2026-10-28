import AppKit
import Foundation

// Windows-only artwork, authored on a 48-unit vector grid. Existing platform
// logos are intentionally outside this generator's output paths.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let artwork = root.appendingPathComponent("assets/images/windows")
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

func shield() -> NSBezierPath {
  let p = NSBezierPath()
  p.move(to: NSPoint(x:24,y:45))
  p.curve(to:NSPoint(x:41,y:39),controlPoint1:NSPoint(x:29,y:42),controlPoint2:NSPoint(x:36,y:40))
  p.line(to:NSPoint(x:41,y:25))
  p.curve(to:NSPoint(x:24,y:3),controlPoint1:NSPoint(x:41,y:16),controlPoint2:NSPoint(x:34,y:8))
  p.curve(to:NSPoint(x:7,y:25),controlPoint1:NSPoint(x:14,y:8),controlPoint2:NSPoint(x:7,y:16))
  p.line(to:NSPoint(x:7,y:39))
  p.curve(to:NSPoint(x:24,y:45),controlPoint1:NSPoint(x:12,y:40),controlPoint2:NSPoint(x:19,y:42))
  p.close()
  p.lineJoinStyle = .round
  return p
}
func routeMark() -> NSBezierPath {
  let p = NSBezierPath()
  p.move(to:NSPoint(x:18,y:14));p.line(to:NSPoint(x:18,y:34));p.line(to:NSPoint(x:25,y:34))
  p.curve(to:NSPoint(x:25,y:24),controlPoint1:NSPoint(x:34,y:34),controlPoint2:NSPoint(x:34,y:24))
  p.line(to:NSPoint(x:18,y:24))
  p.lineCapStyle = .round;p.lineJoinStyle = .round
  return p
}
func drawApp(_ size:Int) {
  let p=shield()
  let gradient=NSGradient(starting:NSColor(srgbRed:0.18,green:0.67,blue:1,alpha:1),ending:NSColor(srgbRed:0.08,green:0.25,blue:0.72,alpha:1))!
  gradient.draw(in:p,angle:-65)
  NSColor(srgbRed:0.03,green:0.20,blue:0.48,alpha:0.24).setStroke()
  p.lineWidth=0.6;p.stroke()
  let mark=routeMark();mark.lineWidth=size<=24 ? 4.2 : 3.8
  NSColor.white.setStroke();mark.stroke()
}
func drawTray(_ size:Int,_ state:String,_ dark:Bool) {
  let ink=dark ? NSColor(srgbRed:0.96,green:0.96,blue:0.96,alpha:1) : NSColor(srgbRed:0.16,green:0.16,blue:0.16,alpha:1)
  // A contrasting halo also keeps the glyph readable when the taskbar uses
  // a different theme from applications (a supported Windows customization).
  let halo=dark ? NSColor.black.withAlphaComponent(0.65) : NSColor.white.withAlphaComponent(0.9)
  let p=shield();p.lineWidth=size<=24 ? 4.8 : 3.8;halo.setStroke();p.stroke()
  p.lineWidth=size<=24 ? 2.8 : 2.2;ink.setStroke();p.stroke()
  let m=routeMark();m.lineWidth=size<=24 ? 3.2 : 2.5;ink.setStroke();m.stroke()
  if state=="idle" {return}
  let center=NSPoint(x:37,y:12)
  let badge=NSBezierPath(ovalIn:NSRect(x:29,y:4,width:16,height:16))
  halo.setStroke();badge.lineWidth=3;badge.stroke()
  let color:NSColor = state=="connected" ? NSColor(srgbRed:0.06,green:0.49,blue:0.06,alpha:1) : state=="error" ? NSColor(srgbRed:0.77,green:0.17,blue:0.11,alpha:1) : NSColor(srgbRed:0,green:0.40,blue:0.75,alpha:1)
  color.setFill();badge.fill()
  let symbol=NSBezierPath();symbol.lineWidth=2.3;symbol.lineCapStyle = .round;symbol.lineJoinStyle = .round
  if state=="connected" {
    symbol.move(to:NSPoint(x:33,y:12));symbol.line(to:NSPoint(x:36,y:9));symbol.line(to:NSPoint(x:41,y:15))
  } else if state=="error" {
    symbol.move(to:NSPoint(x:34,y:9));symbol.line(to:NSPoint(x:40,y:15));symbol.move(to:NSPoint(x:34,y:15));symbol.line(to:NSPoint(x:40,y:9))
  } else {
    symbol.appendArc(withCenter:center,radius:4,startAngle:0,endAngle:360)
    symbol.move(to:center);symbol.line(to:NSPoint(x:37,y:15));symbol.move(to:center);symbol.line(to:NSPoint(x:40,y:12))
  }
  NSColor.white.setStroke();symbol.stroke()
}
func png(_ size:Int,_ state:String="app",_ dark:Bool=false) -> Data {
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
  NSGraphicsContext.current!.shouldAntialias=true
  let transform=NSAffineTransform();transform.scale(by:CGFloat(size)/48);transform.concat()
  if state=="app" {drawApp(size)} else {drawTray(size,state,dark)}
  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using:.png,properties:[:])!
}
func u16(_ v:Int)->Data {Data([UInt8(v&255),UInt8((v>>8)&255)])}
func u32(_ v:Int)->Data {Data([UInt8(v&255),UInt8((v>>8)&255),UInt8((v>>16)&255),UInt8((v>>24)&255)])}
func ico(_ sizes:[Int],_ state:String="app",_ dark:Bool=false)->Data {
  let frames=sizes.map{png($0,state,dark)}
  var data=u16(0)+u16(1)+u16(sizes.count);var offset=6+16*sizes.count
  for (size,frame) in zip(sizes,frames) {
    data += Data([UInt8(size==256 ? 0:size),UInt8(size==256 ? 0:size),0,0])+u16(1)+u16(32)+u32(frame.count)+u32(offset)
    offset += frame.count
  }
  for frame in frames {data += frame}
  return data
}
let app=ico([16,20,24,32,40,48,64,96,128,256])
try app.write(to:root.appendingPathComponent("windows/runner/resources/app_icon.ico"))
try app.write(to:artwork.appendingPathComponent("app_icon.ico"))
try png(512).write(to:artwork.appendingPathComponent("app_icon.png"))
for state in ["idle","connected","busy","error"] {
  for dark in [false,true] {
    let name="tray_\(state)_\(dark ? "dark":"light")"
    try ico([16,20,24,32,40,48,64],state,dark).write(to:artwork.appendingPathComponent(name+".ico"))
    try png(48,state,dark).write(to:artwork.appendingPathComponent(name+".png"))
  }
}
// Editable vector master; the geometry is the same 48-unit artwork as above.
let svg="""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
<defs><linearGradient id="blue" x1="0" y1="0" x2="0.6" y2="1"><stop stop-color="#2eabff"/><stop offset="1" stop-color="#1440b8"/></linearGradient></defs>
<path d="M24 3C29 6 36 8 41 9V23C41 32 34 40 24 45C14 40 7 32 7 23V9C12 8 19 6 24 3Z" fill="url(#blue)" stroke="#143b7b" stroke-opacity=".24" stroke-width=".6" stroke-linejoin="round"/>
<path d="M18 34V14H25C34 14 34 24 25 24H18" fill="none" stroke="white" stroke-width="3.8" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""
try Data(svg.utf8).write(to:root.appendingPathComponent("windows/runner/resources/app_icon.svg"))
print("Windows app and eight theme/status tray icons generated; other platform assets untouched")
