import Citadel
import SwiftTerm

@MainActor
enum SwiftPMImportCheck {
    static func ensureLinked() {
        _ = SSHClient.self
        _ = Terminal.self
    }
}
