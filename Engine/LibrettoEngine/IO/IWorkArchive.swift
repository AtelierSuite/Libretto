import Foundation
import UniformTypeIdentifiers

public enum IWorkError: LocalizedError, Sendable {
    case notAnIWorkDocument
    case legacyFormat
    case passwordProtected
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAnIWorkDocument:
            return "This file isn’t a Pages document Libretto can read."
        case .legacyFormat:
            return """
                This document was saved by an older version of Pages. \
                Open it in Pages and save it again, then try again.
                """
        case .passwordProtected:
            return """
                This Pages document is password-protected. \
                Remove the password in Pages, then try again.
                """
        case .corrupt(let detail):
            return "The Pages document is damaged (\(detail))."
        }
    }
}

/// The objects an iWork document is made of, read from the `.iwa` archives
/// in its `Index` folder, and the files in its `Data` folder they refer to.
///
/// Each archive is a run of Snappy-compressed chunks; decompressed, it is a
/// run of objects, each a protobuf header naming the object's identifier
/// and message type, followed by the message itself.
public struct IWorkArchive: Sendable {
    public struct Object: Sendable {
        public var type: UInt32
        public var message: ProtoMessage

        public init(type: UInt32, message: ProtoMessage) {
            self.type = type
            self.message = message
        }
    }

    public private(set) var objects: [UInt64: Object] = [:]
    /// The archive each object is in, by its path within the package.
    public private(set) var locations: [UInt64: String] = [:]
    /// The package's files, by their path within it.
    public let files: [String: Data]
    /// Data file names, by the identifier objects refer to them with.
    private var dataFileNames: [UInt64: String] = [:]

    public init(files: [String: Data]) throws {
        self.files = files
        let archives = files.keys.filter { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }
        guard !archives.isEmpty else {
            if files.keys.contains(where: { $0.hasSuffix(".iwph") || $0.hasSuffix(".iwpv2") }) {
                throw IWorkError.passwordProtected
            }
            if files.keys.contains(where: { $0 == "index.xml" || $0 == "index.xml.gz" }) {
                throw IWorkError.legacyFormat
            }
            throw IWorkError.notAnIWorkDocument
        }
        for path in archives {
            do {
                let found = try Self.objects(in: Self.decompress(files[path]!, name: path))
                objects.merge(found) { first, _ in first }
                for identifier in found.keys where locations[identifier] == nil { locations[identifier] = path }
            } catch where !Self.essentialArchives.contains(path) {
                // The rest only add to the document, so a damaged one is left out.
                continue
            }
        }
        if let metadata = objects.values.first(where: { $0.type == Self.packageMetadataType }) {
            for info in metadata.message.messages(4) {
                let name = info.string(4).flatMap { $0.isEmpty ? nil : $0 } ?? info.string(3)
                if let name { dataFileNames[info.uint(1)] = name }
            }
        }
    }

    /// Whether the readers use a package's file: not its previews and
    /// thumbnails, nor the films and sound in its `Data` folder, which can be
    /// large and are left out anyway.
    public static func isRead(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        // The package may be in a folder of its own.
        let inner = components.first?.hasSuffix(".pages") == true ? components.dropFirst() : components[...]
        guard let first = inner.first else { return true }
        if inner.count == 1 { return !first.hasPrefix("preview") }
        if first == "QuickLook" { return false }
        if first == "Data", let type = UTType(filenameExtension: (path as NSString).pathExtension) {
            return !type.conforms(to: .audiovisualContent)
        }
        return true
    }

    /// The archives the document's text and styles are in, without which there is nothing to read.
    private static let essentialArchives: Set = ["Index/Document.iwa", "Index/DocumentStylesheet.iwa"]

    /// `TSP.PackageMetadata`, which lists the data files.
    private static let packageMetadataType: UInt32 = 11006

    public subscript(identifier: UInt64?) -> Object? {
        identifier.flatMap { objects[$0] }
    }

    public func objects(ofType type: UInt32) -> [(identifier: UInt64, object: Object)] {
        objects.filter { $0.value.type == type }.map { ($0.key, $0.value) }.sorted { $0.identifier < $1.identifier }
    }

    /// The contents and name of the data file an object refers to by identifier.
    public func dataFile(_ identifier: UInt64) -> (name: String, data: Data)? {
        if let name = dataFileNames[identifier], let data = files["Data/" + name] {
            return (name, data)
        }
        // Files are named after their identifier, should the metadata not say.
        let suffix = "-\(identifier)"
        return files.first { path, _ in
            guard path.hasPrefix("Data/") else { return false }
            let stem = (path as NSString).deletingPathExtension
            return stem.hasSuffix(suffix)
        }.map { (String($0.key.dropFirst(5)), $0.value) }
    }

    private static func objects(in bytes: [UInt8]) throws -> [UInt64: Object] {
        var objects: [UInt64: Object] = [:]
        var reader = ProtoReader(bytes[...])
        while !reader.isAtEnd {
            let header = try ProtoMessage(reader.take(reader.length()))
            let identifier = header.uint(1)
            for (index, info) in header.messages(2).enumerated() {
                let body = try reader.take(ProtoReader.length(info.uint(3)))
                // An object's first message is the object; any after it are for its own use.
                guard index == 0 else { continue }
                objects[identifier] = Object(type: UInt32(truncatingIfNeeded: info.uint(1)), message: try ProtoMessage(body))
            }
        }
        return objects
    }

    /// Joins an archive's chunks, each a zero byte, a three-byte little-endian
    /// length, and that many bytes of Snappy data without the framing format's checksums.
    public static func decompress(_ data: Data, name: String) throws -> [UInt8] {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + 4 <= bytes.count, bytes[offset] == 0 else { throw IWorkError.corrupt(name) }
            let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) << 16
            offset += 4
            guard offset + length <= bytes.count else { throw IWorkError.corrupt(name) }
            try Snappy.decompress(bytes[offset..<offset + length], into: &output, name: name)
            offset += length
        }
        return output
    }
}

/// Snappy's raw block format.
public enum Snappy: Sendable {
    private static let maximumExpansion = 32

    public static func decompress(_ input: ArraySlice<UInt8>, into output: inout [UInt8], name: String) throws {
        var reader = ProtoReader(input)
        let expected = try reader.length()
        // A copy writes at most 64 bytes for its three, so no block grows more
        // than about 22 times; a preamble promising more is damage, not data.
        guard expected <= input.count * maximumExpansion else { throw IWorkError.corrupt(name) }
        let start = output.count
        var position = reader.position
        let end = input.endIndex
        func byte() throws -> Int {
            guard position < end else { throw IWorkError.corrupt(name) }
            defer { position += 1 }
            return Int(input[position])
        }
        func littleEndian(_ count: Int) throws -> Int {
            var value = 0
            for shift in 0..<count { value |= try byte() << (8 * shift) }
            return value
        }
        while position < end {
            let tag = try byte()
            let length: Int
            let distance: Int
            switch tag & 3 {
            case 0:
                var literal = tag >> 2
                if literal >= 60 { literal = try littleEndian(literal - 59) }
                literal += 1
                guard position + literal <= end, output.count - start + literal <= expected else {
                    throw IWorkError.corrupt(name)
                }
                output.append(contentsOf: input[position..<position + literal])
                position += literal
                continue
            case 1:
                length = ((tag >> 2) & 7) + 4
                distance = (tag >> 5) << 8 | (try byte())
            case 2:
                length = (tag >> 2) + 1
                distance = try littleEndian(2)
            default:
                length = (tag >> 2) + 1
                distance = try littleEndian(4)
            }
            guard distance > 0, distance <= output.count - start, output.count - start + length <= expected else {
                throw IWorkError.corrupt(name)
            }
            // Copies may overlap what they write, so go a byte at a time.
            let from = output.count - distance
            for index in 0..<length { output.append(output[from + index]) }
        }
        guard output.count - start == expected else { throw IWorkError.corrupt(name) }
    }
}

// MARK: - Protobuf

/// Reads the protobuf wire format, without a schema.
public struct ProtoReader: Sendable {
    private let bytes: ArraySlice<UInt8>
    public private(set) var position: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    public var isAtEnd: Bool { position >= bytes.endIndex }

    public mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < bytes.endIndex, shift < 64 else { throw IWorkError.corrupt("varint") }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return value }
            shift += 7
        }
    }

    /// A varint that gives a length, which must fit in an `Int`.
    public mutating func length() throws -> Int {
        try Self.length(varint())
    }

    public static func length(_ value: UInt64) throws -> Int {
        guard let length = Int(exactly: value) else { throw IWorkError.corrupt("length") }
        return length
    }

    public mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.endIndex - position else { throw IWorkError.corrupt("length") }
        defer { position += count }
        return bytes[position..<position + count]
    }
}

/// A protobuf message's fields, in the order they appear, for reading by number.
public struct ProtoMessage: Sendable {
    public enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    public private(set) var fields: [(number: Int, value: Value)] = []

    public init(_ bytes: ArraySlice<UInt8>) throws {
        var reader = ProtoReader(bytes)
        while !reader.isAtEnd {
            let key = try reader.varint()
            let number = Int(key >> 3)
            switch key & 7 {
            case 0: fields.append((number, .varint(try reader.varint())))
            case 1: fields.append((number, .fixed64(Self.littleEndian(try reader.take(8)))))
            case 2: fields.append((number, .bytes(try reader.take(reader.length()))))
            case 5: fields.append((number, .fixed32(UInt32(Self.littleEndian(try reader.take(4))))))
            default: throw IWorkError.corrupt("wire type \(key & 7)")
            }
        }
    }

    public init() {}

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func values(_ number: Int) -> [Value] {
        fields.lazy.filter { $0.number == number }.map(\.value)
    }

    private func last(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    public func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    public func uint(_ number: Int) -> UInt64 {
        optionalUInt(number) ?? 0
    }

    public func optionalUInt(_ number: Int) -> UInt64? {
        switch last(number) {
        case .varint(let value), .fixed64(let value): return value
        case .fixed32(let value): return UInt64(value)
        default: return nil
        }
    }

    public func bool(_ number: Int) -> Bool? {
        optionalUInt(number).map { $0 != 0 }
    }

    public func float(_ number: Int) -> Double? {
        switch last(number) {
        case .fixed32(let bits): return Double(Float(bitPattern: bits))
        case .fixed64(let bits): return Double(bitPattern: bits)
        default: return nil
        }
    }

    /// Every value of a repeated float, whether packed or not.
    public func floats(_ number: Int) -> [Double] {
        values(number).flatMap { value -> [Double] in
            switch value {
            case .fixed32(let bits): return [Double(Float(bitPattern: bits))]
            case .bytes(let bytes):
                return stride(from: bytes.startIndex, to: bytes.endIndex - 3, by: 4).map { index in
                    Double(Float(bitPattern: UInt32(Self.littleEndian(bytes[index..<index + 4]))))
                }
            default: return []
            }
        }
    }

    /// Every value of a repeated integer, whether packed or not.
    public func uints(_ number: Int) -> [UInt64] {
        values(number).flatMap { value -> [UInt64] in
            switch value {
            case .varint(let value): return [value]
            case .bytes(let bytes):
                var reader = ProtoReader(bytes)
                var result: [UInt64] = []
                while !reader.isAtEnd, let value = try? reader.varint() { result.append(value) }
                return result
            default: return []
            }
        }
    }

    public func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        if case .bytes(let bytes) = last(number) { return bytes }
        return nil
    }

    public func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    public func strings(_ number: Int) -> [String] {
        values(number).compactMap { if case .bytes(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { nil } }
    }

    public func message(_ number: Int) -> ProtoMessage? {
        bytes(number).flatMap { try? ProtoMessage($0) }
    }

    public func messages(_ number: Int) -> [ProtoMessage] {
        values(number).compactMap { if case .bytes(let bytes) = $0 { try? ProtoMessage(bytes) } else { nil } }
    }

    /// The identifier a `TSP.Reference` field points at.
    public func reference(_ number: Int) -> UInt64? {
        message(number)?.optionalUInt(1)
    }
}

// MARK: - Writing

/// Writes the protobuf wire format.
public struct ProtoWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    public mutating func littleEndian(_ value: UInt64, count: Int) {
        for shift in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
    }

    public mutating func append<Bytes: Collection>(_ more: Bytes) where Bytes.Element == UInt8 {
        bytes.append(contentsOf: more)
    }

    /// Integers as a packed repeated field holds them.
    public static func packed(_ values: [UInt64]) -> [UInt8] {
        var writer = ProtoWriter()
        for value in values { writer.varint(value) }
        return writer.bytes
    }

    public init(bytes: [UInt8] = []) {
        self.bytes = bytes
    }
}

extension ProtoMessage {
    /// The message in the wire format, its fields in the order they are held,
    /// so a message read and written back unchanged comes out as it went in.
    public var encoded: [UInt8] {
        var writer = ProtoWriter()
        for (number, value) in fields {
            let key = UInt64(number) << 3
            switch value {
            case .varint(let value):
                writer.varint(key)
                writer.varint(value)
            case .fixed64(let value):
                writer.varint(key | 1)
                writer.littleEndian(value, count: 8)
            case .bytes(let bytes):
                writer.varint(key | 2)
                writer.varint(UInt64(bytes.count))
                writer.append(bytes)
            case .fixed32(let value):
                writer.varint(key | 5)
                writer.littleEndian(UInt64(value), count: 4)
            }
        }
        return writer.bytes
    }

    /// A `TSP.Reference` to an object.
    public static func reference(_ identifier: UInt64) -> ProtoMessage {
        var reference = ProtoMessage()
        reference.append(1, .varint(identifier))
        return reference
    }

    public mutating func append(_ number: Int, _ value: Value) {
        fields.append((number, value))
    }

    public mutating func append(_ number: Int, message: ProtoMessage) {
        append(number, .bytes(message.encoded[...]))
    }

    /// Gives a field this one value, where it was if it was set, and last if not.
    public mutating func set(_ number: Int, _ value: Value) {
        replace(number, with: [value])
    }

    public mutating func set(_ number: Int, message: ProtoMessage) {
        set(number, .bytes(message.encoded[...]))
    }

    /// Gives a repeated field these values, where its first was if it was
    /// set, and last if not; no values clears it.
    public mutating func replace(_ number: Int, with values: [Value]) {
        let at = fields.firstIndex { $0.number == number } ?? fields.count
        let before = fields[..<at].filter { $0.number != number }
        let after = fields[at...].filter { $0.number != number }
        fields = before + values.map { (number, $0) } + after
    }

    public mutating func replace(_ number: Int, withMessages messages: [ProtoMessage]) {
        replace(number, with: messages.map { .bytes($0.encoded[...]) })
    }

    public mutating func remove(_ number: Int) {
        fields.removeAll { $0.number == number }
    }
}

extension Snappy {
    /// Compresses a block in Snappy's raw format, finding repeats of four
    /// bytes or more up to 64 KiB back.
    public static func compress(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var writer = ProtoWriter()
        writer.varint(UInt64(input.count))
        var output = writer.bytes
        output.reserveCapacity(input.count + input.count / 6 + 32)
        let start = input.startIndex
        let end = input.endIndex

        func emitLiteral(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let length = range.count - 1
            switch length {
            case ..<60: output.append(UInt8(length << 2))
            case ..<0x100: output += [60 << 2, UInt8(length)]
            case ..<0x10000: output += [61 << 2, UInt8(length & 0xFF), UInt8(length >> 8)]
            case ..<0x100_0000: output += [62 << 2, UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16)]
            default:
                output += [63 << 2] + (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) }
            }
            output.append(contentsOf: input[range])
        }
        func emitCopy(distance: Int, length: Int) {
            var remaining = length
            while remaining > 0 {
                // At most 64 a copy, leaving no fewer than four for the next.
                var count = min(remaining, 64)
                if remaining > 64, remaining - 64 < 4 { count = 60 }
                output += [UInt8((count - 1) << 2 | 2), UInt8(distance & 0xFF), UInt8(distance >> 8)]
                remaining -= count
            }
        }
        func word(_ index: Int) -> UInt32 {
            UInt32(input[index]) | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2]) << 16 | UInt32(input[index + 3]) << 24
        }

        var table = [Int](repeating: -1, count: 1 << 14)
        var position = start
        var literalStart = start
        while position + 4 <= end {
            let current = word(position)
            let slot = Int((current &* 0x1E35_A7BD) >> 18)
            let candidate = table[slot]
            table[slot] = position
            guard candidate >= start, position - candidate <= 0xFFFF, word(candidate) == current else {
                position += 1
                continue
            }
            emitLiteral(literalStart..<position)
            var length = 4
            while position + length < end, input[candidate + length] == input[position + length] { length += 1 }
            emitCopy(distance: position - candidate, length: length)
            position += length
            literalStart = position
        }
        emitLiteral(literalStart..<end)
        return output
    }
}

/// One `.iwa` archive's objects, in the order it holds them, to change some
/// and write it back with the rest as they were.
public struct IWorkArchiveFile: Sendable {
    public struct Object: Sendable {
        /// The `TSP.ArchiveInfo` that leads the object.
        public var header: ProtoMessage
        /// The object's messages: the object itself, then any for its own use.
        public var messages: [ArraySlice<UInt8>]

        public var identifier: UInt64 { header.uint(1) }

        public init(header: ProtoMessage, messages: [ArraySlice<UInt8>]) {
            self.header = header
            self.messages = messages
        }
    }

    public private(set) var objects: [Object] = []

    public init(_ data: Data, name: String) throws {
        let bytes = try IWorkArchive.decompress(data, name: name)
        var reader = ProtoReader(bytes[...])
        while !reader.isAtEnd {
            let header = try ProtoMessage(reader.take(reader.length()))
            let messages = try header.messages(2).map { try reader.take(ProtoReader.length($0.uint(3))) }
            objects.append(Object(header: header, messages: messages))
        }
    }

    public func message(_ identifier: UInt64) -> ProtoMessage? {
        objects.first { $0.identifier == identifier }.flatMap { $0.messages.first.flatMap { try? ProtoMessage($0) } }
    }

    /// The objects an object says it refers to.
    public func references(_ identifier: UInt64) -> [UInt64] {
        objects.first { $0.identifier == identifier }?.header.messages(2).first?.uints(5) ?? []
    }

    /// The `TSP.MessageInfo` versions an object of a type was written with, to write another like it.
    public func version(ofType type: UInt64) -> [UInt64]? {
        objects.lazy.compactMap { $0.header.messages(2).first }.first { $0.uint(1) == type }?.uints(2)
    }

    /// Replaces an object's message, and the list of objects it refers to.
    public mutating func replace(_ identifier: UInt64, with message: ProtoMessage, references: [UInt64]) {
        guard let index = objects.firstIndex(where: { $0.identifier == identifier }) else { return }
        var infos = objects[index].header.messages(2)
        guard !infos.isEmpty else { return }
        infos[0].set(5, .bytes(ProtoWriter.packed(references)[...]))
        if references.isEmpty { infos[0].remove(5) }
        objects[index].header.replace(2, withMessages: infos)
        objects[index].messages[0] = message.encoded[...]
    }

    /// Adds an object at the end.
    public mutating func append(_ identifier: UInt64, type: UInt64, version: [UInt64], message: ProtoMessage, references: [UInt64]) {
        var info = ProtoMessage()
        info.append(1, .varint(type))
        info.append(2, .bytes(ProtoWriter.packed(version)[...]))
        info.append(3, .varint(0))
        if !references.isEmpty { info.append(5, .bytes(ProtoWriter.packed(references)[...])) }
        var header = ProtoMessage()
        header.append(1, .varint(identifier))
        header.append(2, message: info)
        objects.append(Object(header: header, messages: [message.encoded[...]]))
    }

    /// The archive, each object's message lengths as they now are, in chunks
    /// of 64 KiB before compression, as iWork writes them.
    public var data: Data {
        var raw: [UInt8] = []
        for object in objects {
            var header = object.header
            var infos = header.messages(2)
            for index in infos.indices where index < object.messages.count {
                infos[index].set(3, .varint(UInt64(object.messages[index].count)))
            }
            header.replace(2, withMessages: infos)
            let encoded = header.encoded
            raw += ProtoWriter.packed([UInt64(encoded.count)])
            raw += encoded
            for message in object.messages { raw += message }
        }
        var output = Data()
        for chunkStart in stride(from: 0, to: raw.count, by: 0x10000) {
            let block = Snappy.compress(raw[chunkStart..<min(chunkStart + 0x10000, raw.count)])
            output.append(0)
            output.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: block.count >> (8 * $0)) })
            output.append(contentsOf: block)
        }
        return output
    }
}
