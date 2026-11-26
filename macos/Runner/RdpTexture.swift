import Accelerate
import CoreVideo
import FlutterMacOS
import Foundation

final class MacRdpTextureRegistry {
  private let registry: FlutterTextureRegistry
  private let channel: FlutterMethodChannel
  private var textures: [UInt32: MacRdpTexture] = [:]

  init(controller: FlutterViewController) {
    registry = controller.registrar(forPlugin: "PagaRdpTexture").textures
    channel = FlutterMethodChannel(
      name: "pagashell/rdpTexture", binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let rawID = call.arguments as? Int,
            let session = UInt32(exactly: rawID) else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "attach": result(self.attach(session))
      case "detach": self.detach(session); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func attach(_ session: UInt32) -> Bool {
    guard textures[session] == nil else { return false }
    let texture = MacRdpTexture(registry)
    texture.id = registry.register(texture)
    guard texture.id != -1 else { return false }
    let context = Unmanaged.passRetained(texture)
    guard pagashell_rdp_texture_attach(
      session, texture.id, context.toOpaque(),
      { context, frame in
        guard let context = context, let frame = frame else { return false }
        return Unmanaged<MacRdpTexture>.fromOpaque(context).takeUnretainedValue().submit(frame)
      },
      { context in
        if let context = context { Unmanaged<MacRdpTexture>.fromOpaque(context).release() }
      }
    ) else {
      context.release()
      registry.unregisterTexture(texture.id)
      return false
    }
    _ = pagashell_rdp_texture_attach_gpu(
      session,
      { context, surface in
        guard let context = context, let surface = surface else { return false }
        return Unmanaged<MacRdpTexture>.fromOpaque(context).takeUnretainedValue().submitGpu(surface)
      },
      0
    )
    textures[session] = texture
    return true
  }

  private func detach(_ session: UInt32) {
    guard let texture = textures.removeValue(forKey: session) else { return }
    texture.stop()
    pagashell_rdp_texture_detach(session)
    registry.unregisterTexture(texture.id)
  }

  func close() {
    channel.setMethodCallHandler(nil)
    for session in Array(textures.keys) { detach(session) }
  }
}

private final class MacRdpTexture: NSObject, FlutterTexture {
  var id: Int64 = -1
  private weak var registry: FlutterTextureRegistry?
  private let lock = NSLock()
  private let uploadLock = NSLock()
  private var latest: CVPixelBuffer?
  private var pendingNotification = false
  private var closed = false
  // The upload thread is the sole writer. The pool only recycles storage
  // after all Flutter raster and Metal references to a snapshot are gone.
  private var pool: CVPixelBufferPool?

  init(_ registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return latest.map { Unmanaged.passRetained($0) }
  }

  func stop() {
    lock.lock()
    closed = true
    latest = nil
    lock.unlock()
  }

  func submitGpu(_ pointer: UnsafePointer<PagaRdpGpuSurfaceView>) -> Bool {
    let surface = pointer.pointee
    guard surface.kind == PAGA_RDP_GPU_SURFACE_CV_PIXEL_BUFFER.rawValue,
          surface.handle != 0,
          surface.width > 0,
          surface.height > 0,
          let raw = UnsafeRawPointer(bitPattern: UInt(surface.handle)) else {
      return false
    }
    let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
    guard CVPixelBufferGetWidth(buffer) == Int(surface.width),
          CVPixelBufferGetHeight(buffer) == Int(surface.height) else {
      return false
    }
    lock.lock()
    guard !closed else { lock.unlock(); return false }
    latest = buffer
    let notify = !pendingNotification
    pendingNotification = true
    lock.unlock()
    if notify {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.lock.lock()
        self.pendingNotification = false
        let active = !self.closed
        self.lock.unlock()
        if active { self.registry?.textureFrameAvailable(self.id) }
      }
    }
    return true
  }

  func submit(_ pointer: UnsafePointer<PagaRdpFrameView>) -> Bool {
    uploadLock.lock()
    defer { uploadLock.unlock() }
    lock.lock()
    let previous = latest
    let active = !closed
    lock.unlock()
    guard active else { return false }
    let frame = pointer.pointee
    if frame.rgba_len == 0 { return previous != nil }
    guard PagaRdpFrameHasValidPixels(pointer), let rgba = frame.rgba else { return false }
    let width = Int(frame.width), height = Int(frame.height)
    let full = PagaRdpFrameIsFull(pointer)
    let resized = previous.map {
      CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height
    } ?? true
    if resized {
      guard full else { return false }
      let spec: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      guard CVPixelBufferPoolCreate(nil, nil, spec as CFDictionary, &pool) == kCVReturnSuccess else {
        return false
      }
    }
    guard let pool = pool else { return false }
    let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
    var pixelBuffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixelBuffer)
            == kCVReturnSuccess, let buffer = pixelBuffer,
          CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
    var bufferLocked = true
    defer {
      if bufferLocked { CVPixelBufferUnlockBaseAddress(buffer, []) }
    }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let sourceStride = Int(frame.bitmap_width) * 4
    let channels: [UInt8] = [2, 1, 0, 3] // RGBA to BGRA.

    func blit(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ sx: Int, _ sy: Int) -> Bool {
      var input = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: rgba.advanced(by: sy * sourceStride + sx * 4)),
        height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: sourceStride
      )
      var output = vImage_Buffer(
        data: base.advanced(by: y * stride + x * 4),
        height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride
      )
      return vImagePermuteChannels_ARGB8888(&input, &output, channels, 0) == kvImageNoError
    }
    if full {
      guard blit(0, 0, width, height, 0, 0) else { return false }
    } else {
      guard let previous = previous, let tiles = frame.tiles,
            CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess else { return false }
      defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
      guard let from = CVPixelBufferGetBaseAddress(previous) else { return false }
      let fromStride = CVPixelBufferGetBytesPerRow(previous)
      for y in 0..<height {
        memcpy(base.advanced(by: y * stride), from.advanced(by: y * fromStride), width * 4)
      }
      for index in 0..<frame.tile_count {
        let tile = tiles[index]
        guard blit(Int(tile.x), Int(tile.y), Int(tile.width), Int(tile.height),
                   Int(tile.source_x), Int(tile.source_y)) else { return false }
      }
    }
    let unlocked = CVPixelBufferUnlockBaseAddress(buffer, [])
    bufferLocked = false
    guard unlocked == kCVReturnSuccess else { return false }
    lock.lock()
    guard !closed else { lock.unlock(); return false }
    latest = buffer
    let notify = !pendingNotification
    pendingNotification = true
    lock.unlock()
    if notify {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.lock.lock()
        self.pendingNotification = false
        let active = !self.closed
        self.lock.unlock()
        if active { self.registry?.textureFrameAvailable(self.id) }
      }
    }
    return true
  }
}
