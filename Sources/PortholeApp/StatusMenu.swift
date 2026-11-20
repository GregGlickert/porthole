// Turns the Menu model into an NSMenu, updating items in place so an open menu (and an open submenu) stays put.
import AppKit
import PortholeCore

final class ActionBox: NSObject {
  let action: MenuAction
  init(_ action: MenuAction) { self.action = action }
}

@MainActor
final class StatusMenu {
  let menu = NSMenu()
  private weak var target: AnyObject?
  private let selector: Selector

  init(target: AnyObject, selector: Selector) {
    self.target = target
    self.selector = selector
    menu.autoenablesItems = false
  }

  /// Digits in the widest port, so 4- and 5-digit ports line up.
  private var portDigits = 4

  func update(_ nodes: [MenuNode]) {
    portDigits = max(4, nodes.compactMap(\.port).map { String($0).count }.max() ?? 4)
    apply(nodes, to: menu)
  }

  /// Same shape (count, separators, submenus) → update each item in place; otherwise rebuild this level.
  private func apply(_ nodes: [MenuNode], to menu: NSMenu) {
    let sameShape =
      menu.items.count == nodes.count
      && zip(menu.items, nodes).allSatisfy { item, node in
        item.isSeparatorItem == node.isSeparator && (item.submenu != nil) == !node.children.isEmpty
      }
    if !sameShape {
      menu.removeAllItems()
      for node in nodes { menu.addItem(node.isSeparator ? .separator() : NSMenuItem()) }
    }
    for (item, node) in zip(menu.items, nodes) where !node.isSeparator {
      configure(item, node)
    }
  }

  private func configure(_ item: NSMenuItem, _ node: MenuNode) {
    let title = attributedTitle(node)
    if item.attributedTitle != title { item.attributedTitle = title }
    item.title = title.string
    item.image = node.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    item.state = node.checked ? .on : .off
    item.keyEquivalent = node.keyEquivalent
    item.keyEquivalentModifierMask = node.keyEquivalent.isEmpty ? [] : [.command]
    if let action = node.action {
      item.representedObject = ActionBox(action)
      item.target = target
      item.action = selector
      item.isEnabled = true
    } else {
      item.representedObject = nil
      item.target = nil
      item.action = nil
      // Info rows (folder, PID, …) are disabled so they draw gray, except parents of submenus.
      item.isEnabled = !node.children.isEmpty
    }
    if node.children.isEmpty {
      item.submenu = nil
    } else {
      let sub = item.submenu ?? {
        let m = NSMenu()
        m.autoenablesItems = false
        item.submenu = m
        return m
      }()
      apply(node.children, to: sub)
    }
  }

  private func attributedTitle(_ node: MenuNode) -> NSAttributedString {
    let base = NSFont.menuFont(ofSize: 0)
    let out = NSMutableAttributedString()
    if let port = node.port {
      // Fixed-width digit column: monospaced digits, padded with figure spaces (as wide as a digit).
      let digits = String(port)
      let pad = String(repeating: "\u{2007}", count: max(0, portDigits - digits.count))
      let mono = NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
      out.append(NSAttributedString(string: ":\(digits)\(pad)  ", attributes: [.font: mono]))
    }
    var attrs: [NSAttributedString.Key: Any] = [.font: base]
    switch node.style {
    case .normal: break
    case .secondary: attrs[.foregroundColor] = NSColor.secondaryLabelColor
    case .detail:
      attrs[.font] = NSFont.menuFont(ofSize: 11)
      attrs[.foregroundColor] = NSColor.secondaryLabelColor
    }
    out.append(NSAttributedString(string: node.title, attributes: attrs))
    return out
  }
}
