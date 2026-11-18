import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      _ = (UIApplication.shared.delegate as? AppDelegate)?.application(UIApplication.shared,open:context.url,options:[:])
    }
  }
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene,willConnectTo:session,options:connectionOptions)
    self.scene(scene,openURLContexts:connectionOptions.urlContexts)
  }
}
