import Foundation

enum IWorkError: LocalizedError {
    case notAnIWorkDocument
    case legacyFormat
    case passwordProtected
    case corrupt(String)

    var errorDescription: String? {
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
struct IWorkArchive {
    struct Object {
        var type: UInt32
        var message: ProtoMessage
    }

    private(set) var objects: [UInt64: Object] = [:]
    /// The package's files, by their path within it.
    let files: [String: Data]
    /// Data file names, by the identifier objects refer to them with.
    private var dataFileNames: [UInt64: String] = [:]

    init(files: [String: Data]) throws {
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
            try read(Self.decompress(files[path]!, name: path))
        }
        if let metadata = objects.values.first(where: { $0.type == Self.packageMetadataType }) {
            for info in metadata.message.messages(4) {
                let name = info.string(4).flatMap { $0.isEmpty ? nil : $0 } ?? info.string(3)
                if let name { dataFileNames[info.uint(1)] = name }
            }
        }
    }

    /// `TSP.PackageMetadata`, which lists the data files.
    private static let packageMetadataType: UInt32 = 11006

    subscript(identifier: UInt64?) -> Object? {
        identifier.flatMap { objects[$0] }
    }

    func objects(ofType type: UInt32) -> [(identifier: UInt64, object: Object)] {
        objects.filter { $0.value.type == type }.map { ($0.key, $0.value) }.sorted { $0.identifier < $1.identifier }
    }

    /// The contents and name of the data file an object refers to by identifier.
    func dataFile(_ identifier: UInt64) -> (name: String, data: Data)? {
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

    private mutating func read(_ bytes: [UInt8]) throws {
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
    }

    /// Joins an archive's chunks, each a zero byte, a three-byte little-endian
    /// length, and that many bytes of Snappy data without the framing format's checksums.
    static func decompress(_ data: Data, name: String) throws -> [UInt8] {
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
enum Snappy {
    static func decompress(_ input: ArraySlice<UInt8>, into output: inout [UInt8], name: String) throws {
        var reader = ProtoReader(input)
        let expected = try reader.length()
        let start = output.count
        output.reserveCapacity(start + expected)
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
                guard position + literal <= end else { throw IWorkError.corrupt(name) }
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
            guard distance > 0, distance <= output.count - start else { throw IWorkError.corrupt(name) }
            // Copies may overlap what they write, so go a byte at a time.
            let from = output.count - distance
            for index in 0..<length { output.append(output[from + index]) }
        }
        guard output.count - start == expected else { throw IWorkError.corrupt(name) }
    }
}

// MARK: - Protobuf

/// Reads the protobuf wire format, without a schema.
struct ProtoReader {
    private let bytes: ArraySlice<UInt8>
    private(set) var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    var isAtEnd: Bool { position >= bytes.endIndex }

    mutating func varint() throws -> UInt64 {
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
    mutating func length() throws -> Int {
        try Self.length(varint())
    }

    static func length(_ value: UInt64) throws -> Int {
        guard let length = Int(exactly: value) else { throw IWorkError.corrupt("length") }
        return length
    }

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= bytes.endIndex - position else { throw IWorkError.corrupt("length") }
        defer { position += count }
        return bytes[position..<position + count]
    }
}

/// A protobuf message's fields, in the order they appear, for reading by number.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(ArraySlice<UInt8>)
        case fixed32(UInt32)
    }

    private(set) var fields: [(number: Int, value: Value)] = []

    init(_ bytes: ArraySlice<UInt8>) throws {
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

    init() {}

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func values(_ number: Int) -> [Value] {
        fields.lazy.filter { $0.number == number }.map(\.value)
    }

    private func last(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    func uint(_ number: Int) -> UInt64 {
        optionalUInt(number) ?? 0
    }

    func optionalUInt(_ number: Int) -> UInt64? {
        switch last(number) {
        case .varint(let value), .fixed64(let value): return value
        case .fixed32(let value): return UInt64(value)
        default: return nil
        }
    }

    func bool(_ number: Int) -> Bool? {
        optionalUInt(number).map { $0 != 0 }
    }

    func float(_ number: Int) -> Double? {
        switch last(number) {
        case .fixed32(let bits): return Double(Float(bitPattern: bits))
        case .fixed64(let bits): return Double(bitPattern: bits)
        default: return nil
        }
    }

    /// Every value of a repeated float, whether packed or not.
    func floats(_ number: Int) -> [Double] {
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
    func uints(_ number: Int) -> [UInt64] {
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

    func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        if case .bytes(let bytes) = last(number) { return bytes }
        return nil
    }

    func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func strings(_ number: Int) -> [String] {
        values(number).compactMap { if case .bytes(let bytes) = $0 { String(decoding: bytes, as: UTF8.self) } else { nil } }
    }

    func message(_ number: Int) -> ProtoMessage? {
        bytes(number).flatMap { try? ProtoMessage($0) }
    }

    func messages(_ number: Int) -> [ProtoMessage] {
        values(number).compactMap { if case .bytes(let bytes) = $0 { try? ProtoMessage(bytes) } else { nil } }
    }

    /// The identifier a `TSP.Reference` field points at.
    func reference(_ number: Int) -> UInt64? {
        message(number)?.optionalUInt(1)
    }
}
