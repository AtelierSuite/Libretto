import Foundation
import Testing
@testable import Libretto

/// Writes iWork archives back: protobuf messages, Snappy blocks and `.iwa` files.
@Suite("iWork writing")
struct IWorkWritingTests {
    private static let files = try! ZipArchive.entries(in: Data(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Resources/Sample.pages")
    ))

    @Test("Snappy blocks decompress to what was compressed")
    func snappy() throws {
        var generator = SystemRandomNumberGenerator()
        let repetitive = Array(String(repeating: "Quarterly Report, quarterly figures. ", count: 2000).utf8)
        let random = (0..<70_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let runs = [UInt8](repeating: 7, count: 300) + Array("abc".utf8) + [UInt8](repeating: 7, count: 67)
        for input in [repetitive, random, runs, [], [1, 2, 3]] {
            var output: [UInt8] = []
            try Snappy.decompress(Snappy.compress(input[...])[...], into: &output, name: "test")
            #expect(output == input)
        }
        #expect(Snappy.compress(repetitive[...]).count < repetitive.count / 10)
    }

    @Test("A message read and written back comes out as it went in")
    func messages() throws {
        let archive = try IWorkArchive(files: Self.files)
        for (_, object) in archive.objects(ofType: PagesReader.Types.storage) {
            #expect(try ProtoMessage(object.message.encoded[...]).encoded == object.message.encoded)
        }
        var message = ProtoMessage()
        message.append(1, .varint(300))
        message.append(2, .fixed32(Float(1.5).bitPattern))
        message.append(3, message: .reference(1_732_641))
        message.append(4, .fixed64(Double(2.5).bitPattern))
        let read = try ProtoMessage(message.encoded[...])
        #expect(read.uint(1) == 300)
        #expect(read.float(2) == 1.5)
        #expect(read.reference(3) == 1_732_641)
        #expect(read.float(4) == 2.5)
    }

    @Test("Setting a field keeps its place, and replacing a repeated one keeps the fields around it")
    func editing() throws {
        var message = ProtoMessage()
        message.append(1, .varint(1))
        message.append(2, .varint(2))
        message.append(2, .varint(3))
        message.append(3, .varint(4))
        message.set(2, .varint(9))
        #expect(message.fields.map(\.number) == [1, 2, 3])
        #expect(message.uint(2) == 9)
        message.replace(2, with: [.varint(5), .varint(6)])
        #expect(message.uints(2) == [5, 6])
        #expect(message.fields.map(\.number) == [1, 2, 2, 3])
        message.remove(2)
        message.set(2, .varint(7))
        #expect(message.fields.map(\.number) == [1, 3, 2])
    }

    @Test("Every archive in a document reads the same once written back")
    func archives() throws {
        for (path, data) in Self.files where path.hasSuffix(".iwa") {
            let file = try IWorkArchiveFile(data, name: path)
            #expect(try IWorkArchive.decompress(file.data, name: path) == IWorkArchive.decompress(data, name: path), "\(path)")
        }
    }

    @Test("A replaced object and an added one are read back with their references")
    func objects() throws {
        let path = "Index/Document.iwa"
        var file = try IWorkArchiveFile(Self.files[path]!, name: path)
        let storage: UInt64 = 1_732_641
        var message = try #require(file.message(storage))
        message.replace(3, with: [.bytes(Array("Edited".utf8)[...])])
        file.replace(storage, with: message, references: [1, 2])
        file.append(99_999_999, type: 2021, version: [1, 0, 5], message: .reference(5), references: [5])
        var files = Self.files
        files[path] = file.data
        let archive = try IWorkArchive(files: files)
        #expect(archive[storage]?.message.string(3) == "Edited")
        #expect(archive[99_999_999]?.type == 2021)
        #expect(archive.locations[99_999_999] == path)
        let written = try IWorkArchiveFile(files[path]!, name: path)
        #expect(written.references(storage) == [1, 2])
        #expect(written.references(99_999_999) == [5])
    }
}
