import Darwin
import Foundation

public let captureFileHeaderBytes = 64

public struct CaptureFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let sizeBytes: Int
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        sizeBytes: Int,
        modificationSeconds: Int64 = 0,
        modificationNanoseconds: Int64 = 0,
        changeSeconds: Int64 = 0,
        changeNanoseconds: Int64 = 0
    ) {
        self.device = device
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
}

public struct CaptureFileSnapshot: Equatable, Sendable {
    public let identity: CaptureFileIdentity
    public let mediaMimeType: String?

    public init(identity: CaptureFileIdentity, mediaMimeType: String?) {
        self.identity = identity
        self.mediaMimeType = mediaMimeType
    }
}

public enum SecureCaptureFileError: Error, Equatable {
    case notRegularFile
    case fileChanged
    case fileTooLarge
    case unreadable
}

/// Inspects the exact directory entry the user selected. `lstat` deliberately
/// refuses symlinks so the later upload never follows a path the preview did not
/// describe.
public func inspectCaptureFile(at url: URL, maxBytes: Int) throws -> CaptureFileSnapshot {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw SecureCaptureFileError.unreadable }
    guard info.st_mode & S_IFMT == S_IFREG else { throw SecureCaptureFileError.notRegularFile }
    guard info.st_size >= 0, info.st_size <= maxBytes else {
        throw SecureCaptureFileError.fileTooLarge
    }
    let size = Int(info.st_size)
    let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw SecureCaptureFileError.unreadable }
    defer { close(fd) }
    var opened = stat()
    guard fstat(fd, &opened) == 0,
          opened.st_mode & S_IFMT == S_IFREG,
          opened.st_dev == info.st_dev,
          opened.st_ino == info.st_ino,
          opened.st_size == info.st_size
    else {
        throw SecureCaptureFileError.fileChanged
    }
    var header = [UInt8](repeating: 0, count: min(captureFileHeaderBytes, size))
    if !header.isEmpty {
        let count = pread(fd, &header, header.count, 0)
        guard count >= 0 else { throw SecureCaptureFileError.unreadable }
        header.removeSubrange(Int(count)..<header.count)
    }
    return CaptureFileSnapshot(
        identity: captureFileIdentity(opened),
        mediaMimeType: detectedCaptureMediaMIME(header)
    )
}

/// Copies through a verified file descriptor into an app-owned 0600 temporary
/// file. Upload clients consume this stable snapshot, never the mutable original
/// path. The copy is bounded even if the source changes while it is being read.
public func stageCaptureFile(
    at url: URL,
    expected: CaptureFileIdentity,
    maxBytes: Int
) throws -> URL {
    let input = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard input >= 0 else { throw SecureCaptureFileError.unreadable }
    defer { close(input) }

    var info = stat()
    guard fstat(input, &info) == 0,
          captureFileMatches(info, expected)
    else {
        throw SecureCaptureFileError.fileChanged
    }
    guard info.st_size >= 0, info.st_size <= maxBytes else {
        throw SecureCaptureFileError.fileTooLarge
    }

    var template = Array(
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chronicle-upload-XXXXXX")
            .path.utf8CString
    )
    let output = mkstemp(&template)
    guard output >= 0 else { throw SecureCaptureFileError.unreadable }
    let pathBytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let stagedURL = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
    var keep = false
    defer {
        close(output)
        if !keep { try? FileManager.default.removeItem(at: stagedURL) }
    }
    guard fchmod(output, S_IRUSR | S_IWUSR) == 0 else {
        throw SecureCaptureFileError.unreadable
    }

    var total = 0
    var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    while true {
        let count = read(input, &buffer, buffer.count)
        guard count >= 0 else { throw SecureCaptureFileError.unreadable }
        if count == 0 { break }
        total += count
        guard total <= maxBytes, total <= expected.sizeBytes else {
            throw SecureCaptureFileError.fileChanged
        }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw in
                write(output, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            guard written > 0 else { throw SecureCaptureFileError.unreadable }
            offset += written
        }
    }
    var finalInfo = stat()
    guard total == expected.sizeBytes,
          fstat(input, &finalInfo) == 0,
          captureFileMatches(finalInfo, expected)
    else {
        throw SecureCaptureFileError.fileChanged
    }
    keep = true
    return stagedURL
}

private func captureFileIdentity(_ info: stat) -> CaptureFileIdentity {
    CaptureFileIdentity(
        device: UInt64(info.st_dev),
        inode: UInt64(info.st_ino),
        sizeBytes: Int(info.st_size),
        modificationSeconds: Int64(info.st_mtimespec.tv_sec),
        modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
        changeSeconds: Int64(info.st_ctimespec.tv_sec),
        changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
    )
}

private func captureFileMatches(_ info: stat, _ expected: CaptureFileIdentity) -> Bool {
    info.st_mode & S_IFMT == S_IFREG &&
        captureFileIdentity(info) == expected
}

public func removeStagedCaptureFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

public func cleanupStaleCaptureTemporaryFiles(
    now: Date = Date(),
    maximumAge: TimeInterval = 24 * 60 * 60
) {
    let directory = FileManager.default.temporaryDirectory
    let prefixes = ["chronicle-upload-", "chronicle-recording-", "chronicle-paste-"]
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }
    for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
        guard let values = try? file.resourceValues(
            forKeys: [.contentModificationDateKey, .isRegularFileKey]
        ),
        values.isRegularFile == true,
        let modified = values.contentModificationDate,
        now.timeIntervalSince(modified) >= maximumAge
        else {
            continue
        }
        try? FileManager.default.removeItem(at: file)
    }
}

private func detectedCaptureMediaMIME(_ bytes: [UInt8]) -> String? {
    func starts(_ signature: [UInt8]) -> Bool {
        bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
    }
    func ascii(_ range: Range<Int>) -> String? {
        guard bytes.count >= range.upperBound else { return nil }
        return String(bytes: bytes[range], encoding: .ascii)
    }

    if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if ascii(0..<6) == "GIF87a" || ascii(0..<6) == "GIF89a" { return "image/gif" }
    if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
    if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return "image/webp" }

    if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "audio/wav" }
    if ascii(0..<4) == "FORM", let form = ascii(8..<12), form == "AIFF" || form == "AIFC" {
        return "audio/aiff"
    }
    if starts([0x49, 0x44, 0x33]) || (bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0) {
        return "audio/mpeg"
    }
    if ascii(0..<4) == "fLaC" { return "audio/flac" }
    if ascii(0..<4) == "OggS" { return "audio/ogg" }
    if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }

    if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
        let imageBrands = ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif"]
        if imageBrands.contains(brand) { return brand == "avif" ? "image/avif" : "image/heic" }
        let audioBrands = ["M4A ", "M4B ", "mp41", "mp42", "isom"]
        if audioBrands.contains(brand) { return "audio/mp4" }
    }
    return nil
}
