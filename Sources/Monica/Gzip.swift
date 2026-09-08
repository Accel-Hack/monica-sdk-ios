import Foundation
import zlib

enum GzipError: Error {
  case deflateFailed(Int32)
}

/// gzip framing over zlib, which every Apple platform ships. Ingest rejects
/// anything but `Content-Encoding: gzip`.
enum Gzip {
  static func compress(_ input: Data) throws -> Data {
    var stream = z_stream()
    var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                               Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw GzipError.deflateFailed(status) }
    defer { deflateEnd(&stream) }

    var output = Data(count: Int(deflateBound(&stream, uLong(input.count))) + 32)
    let produced: Int = try input.withUnsafeBytes { (inputBytes: UnsafeRawBufferPointer) in
      try output.withUnsafeMutableBytes { (outputBytes: UnsafeMutableRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
        stream.avail_out = uInt(outputBytes.count)
        status = deflate(&stream, Z_FINISH)
        guard status == Z_STREAM_END else { throw GzipError.deflateFailed(status) }
        return Int(stream.total_out)
      }
    }
    output.count = produced
    return output
  }
}
