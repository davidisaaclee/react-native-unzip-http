/*
 * This file is based on unzip-http by Saul Pwanson
 * Original source: https://github.com/saulpw/unzip-http
 * Licensed under MIT License
 *
 * Copyright (c) 2022 Saul Pwanson
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

import Foundation
import Compression

struct ZipFileInfo {
    let filename: String
    let fileSize: Int
    let compressedSize: Int
    let headerOffset: Int
    let compressionMethod: Int
    let dateTime: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)

    var isDirectory: Bool {
        return filename.hasSuffix("/")
    }
}

enum ZipError: Error {
    case invalidURL
    case networkError(Error)
    case rangeRequestsNotSupported
    case centralDirectoryNotFound
    case fileNotFound(String)
    case unsupportedCompressionMethod(Int)
    case decompressionFailed
    case invalidZipStructure
}

struct RemoteZipExtractor {
    var session: URLSession = .shared

    // MARK: - Public API

    func listFiles(atZipURL url: URL) async throws -> [ZipFileInfo] {
        try await getFileInfoList(from: url)
    }

    func download(_ filename: String, inZipURL url: URL) async throws -> Data {
        let fileInfos = try await getFileInfoList(from: url)

        guard let fileInfo = fileInfos.first(where: { $0.filename == filename }) else {
            throw ZipError.fileNotFound(filename)
        }

        return try await download(fileInfo, inZipURL: url)
    }

    func download(_ fileInfo: ZipFileInfo, inZipURL url: URL) async throws -> Data {
        return try await extractFile(fileInfo, from: url)
    }

    // MARK: - Private Implementation

    private func getFileInfoList(from url: URL) async throws -> [ZipFileInfo] {
        // First, get the ZIP file size and check range support
        let (zipSize, supportsRanges) = try await getZipMetadata(from: url)

        if !supportsRanges {
            print("Warning: Server may not support range requests - trying anyway")
        }

        // Download the end of the file to find the central directory
        let endChunkSize = min(65536, zipSize)
        let startOffset = max(zipSize - endChunkSize, 0)
        let endData = try await downloadRange(from: url, start: startOffset, length: endChunkSize)

        // Find the End of Central Directory record
        let (centralDirStart, centralDirSize) = try findCentralDirectory(in: endData, zipSize: zipSize, endChunkStart: startOffset)

        // Download the central directory if we don't have it all
        let centralDirData: Data
        if zipSize <= 65536 {
            // We have the whole file in endData
            let cdirStartInChunk = centralDirStart - startOffset
            centralDirData = endData.subdata(in: cdirStartInChunk..<endData.count)
        } else if centralDirStart >= startOffset {
            // Central directory is in our end chunk
            let cdirStartInChunk = centralDirStart - startOffset
            centralDirData = endData.subdata(in: cdirStartInChunk..<endData.count)
        } else {
            // Need to download the central directory separately
            centralDirData = try await downloadRange(from: url, start: centralDirStart, length: centralDirSize)
        }

        // Parse the central directory entries
        return try parseCentralDirectory(centralDirData)
    }

    private func getZipMetadata(from url: URL) async throws -> (size: Int, supportsRanges: Bool) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZipError.networkError(URLError(.badServerResponse))
            }

            guard let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                  let size = Int(contentLength) else {
                throw ZipError.networkError(URLError(.badServerResponse))
            }

            let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
            let supportsRanges = acceptRanges.lowercased() == "bytes"

            return (size: size, supportsRanges: supportsRanges)
        } catch {
            throw ZipError.networkError(error)
        }
    }

    private func downloadRange(from url: URL, start: Int, length: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            throw ZipError.networkError(error)
        }
    }

    private func findCentralDirectory(in data: Data, zipSize: Int, endChunkStart: Int) throws -> (start: Int, size: Int) {
        // Look for End of Central Directory signature (0x504b0506)
        let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]

        guard let eocdOffset = data.lastRange(of: Data(eocdSignature))?.lowerBound else {
            throw ZipError.centralDirectoryNotFound
        }

        let eocdData = data.subdata(in: eocdOffset..<data.endIndex)
        guard eocdData.count >= 22 else {
            throw ZipError.invalidZipStructure
        }

        // Parse EOCD record
        let centralDirSize = eocdData.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        }

        let centralDirStart = eocdData.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
        }

        return (start: Int(centralDirStart), size: Int(centralDirSize))
    }

    private func parseCentralDirectory(_ data: Data) throws -> [ZipFileInfo] {
        var fileInfos: [ZipFileInfo] = []
        var offset = 0

        while offset < data.count - 46 { // Minimum size of central directory entry
            // Check for central directory file header signature (0x504b0102)
            let signature = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }

            guard signature == 0x02014b50 else {
                break
            }

            // Parse central directory entry
            let compressionMethod = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 10, as: UInt16.self)
            }

            let dateTime = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 12, as: UInt16.self)
            }

            let compressedSize = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 20, as: UInt32.self)
            }

            let uncompressedSize = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
            }

            let filenameLength = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 28, as: UInt16.self)
            }

            let extraFieldLength = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 30, as: UInt16.self)
            }

            let commentLength = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 32, as: UInt16.self)
            }

            let localHeaderOffset = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: offset + 42, as: UInt32.self)
            }

            offset += 46

            // Extract filename
            guard offset + Int(filenameLength) <= data.count else {
                break
            }

            let filenameData = data.subdata(in: offset..<offset + Int(filenameLength))
            guard let filename = String(data: filenameData, encoding: .utf8) else {
                offset += Int(filenameLength) + Int(extraFieldLength) + Int(commentLength)
                continue
            }

            offset += Int(filenameLength) + Int(extraFieldLength) + Int(commentLength)

            // Parse DOS date/time
            let dosDateTime = parseDOSDateTime(UInt32(dateTime))

            let fileInfo = ZipFileInfo(
                filename: filename,
                fileSize: Int(uncompressedSize),
                compressedSize: Int(compressedSize),
                headerOffset: Int(localHeaderOffset),
                compressionMethod: Int(compressionMethod),
                dateTime: dosDateTime
            )

            fileInfos.append(fileInfo)
        }

        return fileInfos
    }

    private func parseDOSDateTime(_ dosDateTime: UInt32) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        let second = Int((dosDateTime & 0x1f) * 2)
        let minute = Int((dosDateTime >> 5) & 0x3f)
        let hour = Int((dosDateTime >> 11) & 0x1f)
        let day = Int((dosDateTime >> 16) & 0x1f)
        let month = Int((dosDateTime >> 21) & 0x0f)
        let year = Int(((dosDateTime >> 25) & 0x7f) + 1980)

        return (year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private func extractFile(_ fileInfo: ZipFileInfo, from url: URL) async throws -> Data {
        // First, read the local file header to get the actual data offset
        let localHeaderData = try await downloadRange(from: url, start: fileInfo.headerOffset, length: 30)

        guard localHeaderData.count >= 30 else {
            throw ZipError.invalidZipStructure
        }

        // Parse local file header
        let filenameLength = localHeaderData.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 26, as: UInt16.self)
        }

        let extraFieldLength = localHeaderData.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: 28, as: UInt16.self)
        }

        let dataOffset = fileInfo.headerOffset + 30 + Int(filenameLength) + Int(extraFieldLength)

        // Download the compressed file data
        let compressedData = try await downloadRange(from: url, start: dataOffset, length: fileInfo.compressedSize)

        // Decompress based on compression method
        switch fileInfo.compressionMethod {
        case 0: // No compression
            return compressedData
        case 8: // Deflate
            return try decompressDeflate(compressedData, expectedSize: fileInfo.fileSize)
        default:
            throw ZipError.unsupportedCompressionMethod(fileInfo.compressionMethod)
        }
    }

    private func decompressDeflate(_ compressedData: Data, expectedSize: Int) throws -> Data {
      try compressedData.deflateDecompress()
    }
}

extension Data {
    func lastRange(of data: Data) -> Range<Index>? {
        let searchData = data
        let searchLength = searchData.count

        guard searchLength > 0 && searchLength <= self.count else {
            return nil
        }

        for i in stride(from: self.count - searchLength, through: 0, by: -1) {
            let range = i..<i + searchLength
            if self.subdata(in: range) == searchData {
                return range
            }
        }

        return nil
    }
}

// MARK: Obj-C wrappers

@objc public class HttpUnzipExtractor: NSObject {
  private var impl: RemoteZipExtractor

  @objc
  public init(urlSession: URLSession) {
    self.impl = RemoteZipExtractor(session: urlSession)
  }

  @objc
  public func listFiles(atZipURL url: URL) async throws -> [FileInfo] {
    try await impl.listFiles(atZipURL: url).map { FileInfo.from($0) }
  }

  @objc
  public func download(_ fileInfo: FileInfo, inZipURL url: URL) async throws -> Data {
    try await impl.download(ZipFileInfo(fileInfo), inZipURL: url)
  }

  @objc
  public class FileInfo: NSObject {
    @objc public init(
      filename: String,
      fileSize: Int,
      compressedSize: Int,
      headerOffset: Int,
      compressionMethod: Int,
      dateTime: HttpUnzipExtractor.FileInfo.Datetime
    ) {
      self.filename = filename
      self.fileSize = fileSize
      self.compressedSize = compressedSize
      self.headerOffset = headerOffset
      self.compressionMethod = compressionMethod
      self.dateTime = dateTime
    }

    static func from(_ fileInfo: ZipFileInfo) -> FileInfo {
      FileInfo(
          filename: fileInfo.filename,
          fileSize: fileInfo.fileSize,
          compressedSize: fileInfo.compressedSize,
          headerOffset: fileInfo.headerOffset,
          compressionMethod: fileInfo.compressionMethod,
          dateTime: .from(fileInfo.dateTime)
      )
    }

    @objc public let filename: String
    @objc public let fileSize: Int
    @objc public let compressedSize: Int
    @objc public let headerOffset: Int
    @objc public let compressionMethod: Int
    @objc public let dateTime: Datetime

    @objc public class Datetime: NSObject {
      @objc public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
      }

      static func from(_ tuple: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)) -> Datetime {
          Datetime(
              year: tuple.year,
              month: tuple.month,
              day: tuple.day,
              hour: tuple.hour,
              minute: tuple.minute,
              second: tuple.second
          )
      }

      @objc public let year: Int
      @objc public let month: Int
      @objc public let day: Int
      @objc public let hour: Int
      @objc public let minute: Int
      @objc public let second: Int
      
      func toTuple() -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        return (
          year: self.year,
          month: self.month,
          day: self.day,
          hour: self.hour,
          minute: self.minute,
          second: self.second
        )
      }
    }
  }
}

extension ZipFileInfo {
  init(_ other: HttpUnzipExtractor.FileInfo) {
    self.init(
      filename: other.filename,
      fileSize: other.fileSize,
      compressedSize: other.compressedSize,
      headerOffset: other.headerOffset,
      compressionMethod: other.compressionMethod,
      dateTime: other.dateTime.toTuple()
    )
  }
}
