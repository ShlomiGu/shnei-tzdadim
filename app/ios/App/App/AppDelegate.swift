import UIKit
import Capacitor
import StoreKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

}

// MARK: - Bridge view controller (registers app-local plugins)

// Set as the custom class of the root view controller in Main.storyboard.
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(StorePlugin())
    }
}

// MARK: - Store plugin (Apple In-App Purchase, StoreKit 2)
// JS: window.Capacitor.Plugins.Store.{products, purchase, finish, unfinished}
// Transactions are never finished here on purchase: the web app sends the JWS to the
// pay-apple edge function and calls finish() only after the server has delivered it.

@objc(StorePlugin)
public class StorePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StorePlugin"
    public let jsName = "Store"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "products", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "purchase", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finish", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unfinished", returnType: CAPPluginReturnPromise)
    ]

    @objc func products(_ call: CAPPluginCall) {
        let ids: [String] = (call.getArray("ids") ?? []).compactMap { $0 as? String }
        if ids.isEmpty {
            call.reject("ids must be a non-empty array of product ids")
            return
        }
        Task {
            do {
                let list = try await Product.products(for: ids)
                var out: [[String: Any]] = []
                for p in list {
                    out.append([
                        "id": p.id,
                        "title": p.displayName,
                        "description": p.description,
                        "price": p.displayPrice,
                        "priceValue": NSDecimalNumber(decimal: p.price).doubleValue
                    ])
                }
                call.resolve(["products": out])
            } catch {
                call.reject("could not load products: \(error.localizedDescription)")
            }
        }
    }

    @objc func purchase(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), !id.isEmpty else {
            call.reject("id is required")
            return
        }
        guard let tokenStr = call.getString("accountToken"), let token = UUID(uuidString: tokenStr) else {
            call.reject("accountToken must be a UUID string")
            return
        }
        Task {
            do {
                let found = try await Product.products(for: [id])
                guard let product = found.first else {
                    call.reject("product not found: \(id)")
                    return
                }
                let result = try await product.purchase(options: [.appAccountToken(token)])
                switch result {
                case .success(let verification):
                    var txnId: UInt64 = 0
                    switch verification {
                    case .verified(let t):
                        txnId = t.id
                    case .unverified(let t, _):
                        txnId = t.id
                    }
                    call.resolve([
                        "status": "purchased",
                        "jws": verification.jwsRepresentation,
                        "transactionId": String(txnId)
                    ])
                case .userCancelled:
                    call.resolve(["status": "cancelled"])
                case .pending:
                    call.resolve(["status": "pending"])
                @unknown default:
                    call.reject("unknown purchase result")
                }
            } catch {
                call.reject("purchase failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func finish(_ call: CAPPluginCall) {
        guard let idStr = call.getString("transactionId"), let wanted = UInt64(idStr) else {
            call.reject("transactionId must be a numeric string")
            return
        }
        Task {
            for await verification in Transaction.unfinished {
                let t: Transaction
                switch verification {
                case .verified(let v):
                    t = v
                case .unverified(let v, _):
                    t = v
                }
                if t.id == wanted {
                    await t.finish()
                    call.resolve(["finished": true])
                    return
                }
            }
            call.resolve(["finished": false])
        }
    }

    @objc func unfinished(_ call: CAPPluginCall) {
        Task {
            var items: [[String: Any]] = []
            for await verification in Transaction.unfinished {
                let t: Transaction
                switch verification {
                case .verified(let v):
                    t = v
                case .unverified(let v, _):
                    t = v
                }
                items.append([
                    "jws": verification.jwsRepresentation,
                    "transactionId": String(t.id),
                    "productId": t.productID
                ])
            }
            call.resolve(["items": items])
        }
    }
}
