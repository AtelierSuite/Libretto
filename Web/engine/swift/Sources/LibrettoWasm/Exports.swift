import Foundation

// The engine's whole interface to JavaScript: a C ABI with no dependencies.
//
// The host copies a UTF-8 JSON request (and optionally a byte payload, such as
// a file being opened) into memory it allocated with `libretto_alloc`, then calls
// `libretto_call`. The response is JSON, plus an optional byte payload (such as a
// file being saved), which the host reads through the `libretto_response_*` and
// `libretto_payload_*` accessors before making its next call.

private nonisolated(unsafe) var response = Buffer()
private nonisolated(unsafe) var payload = Buffer()

/// Memory owned by the engine that the host reads between calls.
private struct Buffer {
    var pointer: UnsafeMutableRawPointer?
    var count = 0

    mutating func replace(with bytes: some Collection<UInt8>) {
        pointer?.deallocate()
        count = bytes.count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 8)
        UnsafeMutableRawBufferPointer(start: pointer, count: count).copyBytes(from: bytes)
    }
}

@_expose(wasm, "libretto_alloc")
@_cdecl("libretto_alloc")
public func librettoAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(Int(size), 1), alignment: 8)
}

@_expose(wasm, "libretto_free")
@_cdecl("libretto_free")
public func librettoFree(_ pointer: UnsafeMutableRawPointer?) {
    pointer?.deallocate()
}

/// Handles one request. Returns 0; failures are reported inside the response.
@_expose(wasm, "libretto_call")
@_cdecl("libretto_call")
public func librettoCall(
    _ request: UnsafeRawPointer, _ requestLength: Int32, _ input: UnsafeRawPointer?, _ inputLength: Int32
) -> Int32 {
    let requestData = Data(bytes: request, count: Int(requestLength))
    let inputData = input.map { Data(bytes: $0, count: Int(inputLength)) }
    let (json, output) = Bridge.shared.handle(requestData, payload: inputData)
    response.replace(with: json)
    payload.replace(with: output ?? Data())
    return 0
}

@_expose(wasm, "libretto_response_pointer")
@_cdecl("libretto_response_pointer")
public func librettoResponsePointer() -> UnsafeMutableRawPointer? { response.pointer }

@_expose(wasm, "libretto_response_length")
@_cdecl("libretto_response_length")
public func librettoResponseLength() -> Int32 { Int32(response.count) }

@_expose(wasm, "libretto_payload_pointer")
@_cdecl("libretto_payload_pointer")
public func librettoPayloadPointer() -> UnsafeMutableRawPointer? { payload.pointer }

@_expose(wasm, "libretto_payload_length")
@_cdecl("libretto_payload_length")
public func librettoPayloadLength() -> Int32 { Int32(payload.count) }
