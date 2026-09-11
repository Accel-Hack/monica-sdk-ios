import Monica
import UIKit

enum SampleError: Error {
  case paymentDeclined(code: Int)
}

final class MainViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "MONICA Sample"
    view.backgroundColor = .systemBackground

    let stack = UIStackView(arrangedSubviews: [
      button("1. captureMessage", #selector(sendMessage)),
      button("2. captureError (handled)", #selector(sendHandledError)),
      button("3. setUser + breadcrumb", #selector(identifyUser)),
      button("4. Second screen", #selector(pushSecondScreen)),
      button("5. Crash (Swift fatalError → SIGTRAP)", #selector(crashSwift)),
      button("6. Crash (NSException)", #selector(crashObjC)),
    ])
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])

    // Launch arguments drive the same buttons from a shell:
    //   xcrun simctl launch booted net.accelhack.monica.sample -auto 1     (steps 1-3, then flush)
    //   xcrun simctl launch booted net.accelhack.monica.sample -crash swift | nsexception
    if UserDefaults.standard.bool(forKey: "auto") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.identifyUser()
        self?.sendMessage()
        self?.sendHandledError()
        let flushed = Monica.current?.flush(timeout: 15) ?? false
        NSLog("[\(AppDelegate.tag)] flush -> \(flushed)")
      }
    }
    if let kind = UserDefaults.standard.string(forKey: "crash") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        kind == "nsexception" ? self?.crashObjC() : self?.crashSwift()
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Monica.current?.setScreen("MainViewController")
  }

  private func button(_ title: String, _ action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .body)
    button.contentHorizontalAlignment = .leading
    button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    button.accessibilityIdentifier = title
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func sendMessage() {
    let id = Monica.current?.captureMessage("hello from ios-sample", context: CaptureContext().level(.info))
    NSLog("[\(AppDelegate.tag)] captureMessage -> \(id ?? "dropped")")
  }

  @objc private func sendHandledError() {
    do {
      try Checkout().pay(amount: 4200)
    } catch {
      let id = Monica.current?.captureError(error, context: CaptureContext().tag("feature", "checkout"))
      NSLog("[\(AppDelegate.tag)] captureError -> \(id ?? "dropped")")
    }
  }

  @objc private func identifyUser() {
    Monica.current?.setUser(id: "u_sample")
    Monica.current?.addBreadcrumb(category: "ui.click", message: "identifyUser")
    NSLog("[\(AppDelegate.tag)] user set; breadcrumb added")
  }

  @objc private func pushSecondScreen() {
    navigationController?.pushViewController(SecondViewController(), animated: true)
  }

  @objc private func crashSwift() {
    NSLog("[\(AppDelegate.tag)] crashing with fatalError")
    Checkout().explode()
  }

  @objc private func crashObjC() {
    NSLog("[\(AppDelegate.tag)] crashing with NSException")
    let array = NSArray(array: [1, 2, 3])
    _ = array.object(at: 5)
  }
}

/// A second in_app type so the grouping canonical string shows more than one file.
struct Checkout {
  func pay(amount: Int) throws {
    if amount > 1000 { throw SampleError.paymentDeclined(code: 402) }
  }

  func explode() -> Never {
    fatalError("ios-sample deliberate crash")
  }
}
