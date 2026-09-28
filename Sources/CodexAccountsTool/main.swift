import Foundation
import AccountCore
@main struct Diagnose {
    static func main() async {
        do {
            let service = AccountService()
            let snapshot: AccountSnapshot
            if CommandLine.arguments.contains("--open") { snapshot = try await service.openCodex() }
            else if CommandLine.arguments.contains("--refresh") { snapshot = try await service.refresh() }
            else { snapshot = try await service.snapshot() }
            print("Codex Konten: \(snapshot.cliPath == nil ? "CLI fehlt" : "CLI gefunden")")
            print("Aktuell: \(snapshot.currentAccountLabel ?? "unbekannt")")
            for a in snapshot.accounts { print("\(a.displayName): \(a.isActive ? "aktiv" : "gespeichert"), 5h \(a.usage?.fiveHourRemaining.map { String(format:"%.0f%%",$0) } ?? "unbekannt"), Woche \(a.usage?.weeklyRemaining.map { String(format:"%.0f%%",$0) } ?? "unbekannt"), Stand \(a.usage?.fetchedAt.description ?? "kein Cache")\(a.error.map { ", Fehler: " + $0 } ?? "")") }
            if let notice = snapshot.notice { print(notice) }
        } catch { print("Fehler: \(error.localizedDescription)"); exit(1) }
    }
}
