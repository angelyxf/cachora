import Foundation

/// A location that was not measured. Its size is unknown, never implicitly zero.
struct ScanIssue: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case permissionDenied
        case readFailure
    }

    let path: String
    let kind: Kind
    let detail: String

    var id: String { kind.rawValue + ":" + path }

    init(path: String, kind: Kind, detail: String) {
        self.path = path
        self.kind = kind
        self.detail = detail
    }

    init(path: String, error: Error) {
        self.path = path
        self.kind = Self.isPermissionError(error as NSError) ? .permissionDenied : .readFailure
        self.detail = error.localizedDescription
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }
}
