import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var privacyCover: UIView?
    private var privacyCheckGeneration = 0

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = CAPBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        privacyCheckGeneration += 1
        guard privacyCover == nil, let window else { return }
        let cover = UIView(frame: window.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = UIColor(red: 0.76, green: 0.65, blue: 0.55, alpha: 1)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "柔療營運\nROU SPA OPERATIONS"
        title.numberOfLines = 2
        title.textAlignment = .center
        title.textColor = .white
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        cover.addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
        ])

        window.addSubview(cover)
        privacyCover = cover
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Keep the native cover above the WebView until JavaScript finishes the
        // server-backed session refresh and removes its own privacy state. This
        // prevents protected content flashing during the resume transition.
        privacyCheckGeneration += 1
        waitForWebPrivacyRelease(generation: privacyCheckGeneration)
    }

    private func waitForWebPrivacyRelease(generation: Int) {
        guard generation == privacyCheckGeneration, privacyCover != nil else { return }
        guard let controller = window?.rootViewController as? CAPBridgeViewController,
              let webView = controller.bridge?.webView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForWebPrivacyRelease(generation: generation)
            }
            return
        }

        webView.evaluateJavaScript("document.documentElement.classList.contains('rou-ios-private')") { [weak self] result, _ in
            guard let self, generation == self.privacyCheckGeneration else { return }
            if let isPrivate = result as? Bool, !isPrivate {
                self.privacyCover?.removeFromSuperview()
                self.privacyCover = nil
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForWebPrivacyRelease(generation: generation)
            }
        }
    }
}
