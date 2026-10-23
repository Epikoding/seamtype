import ArasoService
import Foundation

// The C interface ArasoHost.exe (windows/host) calls, declared in windows/include/araso_bridge.h.
// Requests and answers are JSON (`ServiceRequest`, `ServiceResponse`), UTF-8 and NUL-terminated;
// every string returned is freed with `araso_free`. Called on the host's main thread only.

@MainActor private var runtime: ServiceRuntime?

/// Starts the runtime with `ServiceRuntime.Configuration` as JSON. Returns 0, or -1 when the JSON
/// can't be read.
@_cdecl("araso_start")
public func araso_start(_ configuration: UnsafePointer<CChar>?) -> Int32 {
    let text = configuration.map { String(cString: $0) }
    return MainActor.assumeIsolated {
        guard let text, let config = try? JSONDecoder().decode(ServiceRuntime.Configuration.self, from: Data(text.utf8))
        else { return -1 }
        runtime = ServiceRuntime(config)
        return 0
    }
}

/// Builds the language models and loads the kanji dictionary, so the first key isn't slow.
@_cdecl("araso_warm_up")
public func araso_warm_up() {
    MainActor.assumeIsolated { runtime?.warmUp() }
}

/// One request; the answer, or an answer with `error` set.
@_cdecl("araso_request")
public func araso_request(_ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let text = request.map { String(cString: $0) }
    nonisolated(unsafe) var answer = ""
    MainActor.assumeIsolated {
        var response = ServiceResponse()
        if let runtime, let text,
           let decoded = try? JSONDecoder().decode(ServiceRequest.self, from: Data(text.utf8)) {
            response = runtime.handle(decoded)
        } else {
            response.error = runtime == nil ? "not started" : "bad request"
        }
        let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"reply":{"handled":false,"ops":[]},"error":"encoding"}"#.utf8)
        answer = String(decoding: data, as: UTF8.self)
    }
    return copy(answer)
}

/// UI text in the user's language (loaded by `araso_start`), with `%@`/`%ld` left in.
@_cdecl("araso_localize")
public func araso_localize(_ key: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let key else { return copy("") }
    return copy(Strings.localized(String(cString: key)))
}

@_cdecl("araso_free")
public func araso_free(_ string: UnsafeMutablePointer<CChar>?) {
    string?.deallocate()
}

private func copy(_ string: String) -> UnsafeMutablePointer<CChar> {
    let utf8 = Array(string.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
    buffer.initialize(from: utf8, count: utf8.count)
    return buffer
}
