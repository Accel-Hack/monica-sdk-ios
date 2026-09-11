import Monica
import UIKit

final class SecondViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Second"
    view.backgroundColor = .systemBackground
    let label = UILabel()
    label.text = "Go back, then send something.\nThe event carries screen=SecondViewController→MainViewController breadcrumbs."
    label.numberOfLines = 0
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Monica.current?.setScreen("SecondViewController")
  }
}
