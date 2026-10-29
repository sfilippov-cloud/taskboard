// Which cards on the board are unfolded. A card starts folded to its title; the chevron on it unfolds it in place, and the
// choice is remembered between launches. Task ids are never reused, so a deleted task leaves nothing to mix up.
import Foundation
import Observation

@MainActor
@Observable
final class CardFolding {
  static let shared = CardFolding()
  private static let key = "unfoldedTasks"

  private(set) var unfolded: Set<Int>

  private init() {
    unfolded = Set(UserDefaults.standard.array(forKey: Self.key) as? [Int] ?? [])
  }

  func isUnfolded(_ id: Int) -> Bool { unfolded.contains(id) }

  func toggle(_ id: Int) {
    if unfolded.contains(id) { unfolded.remove(id) } else { unfolded.insert(id) }
    UserDefaults.standard.set(unfolded.sorted(), forKey: Self.key)
  }

  // For the snapshot tool: it must not change what the user chose.
  func show(unfolded ids: Set<Int>) { unfolded = ids }
}
