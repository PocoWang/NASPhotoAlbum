import UIKit

/**
 * 应用入口。
 *
 * - 创建窗口与根导航控制器（首页）。
 * - 启动时按需触发自动扫描（增量同步，不清空缓存）。
 */
@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = UIColor(white: 0.08, alpha: 1.0)

        let main = MainViewController()
        let nav = UINavigationController(rootViewController: main)
        nav.navigationBar.isTranslucent = false
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        // App 启动同步：已配置 NAS 且到扫描周期时，增量扫描并补缓存（不清空已有缓存）
        DispatchQueue.global(qos: .utility).async {
            AppServices.shared.scanCoordinator.maybeAutoScan()
        }
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 回到前台时同样检查扫描周期（电子相册长时间挂起后重新同步）
        DispatchQueue.global(qos: .utility).async {
            AppServices.shared.scanCoordinator.maybeAutoScan()
        }
    }
}
