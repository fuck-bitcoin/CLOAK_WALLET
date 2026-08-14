import Cocoa
import FlutterMacOS
import Sparkle

@main
class AppDelegate: FlutterAppDelegate, SPUUpdaterDelegate {
  private var updateChannel: FlutterMethodChannel?
  private var verifiedFeedURL: String?
  private var verifiedVersion: String?
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: nil
  )

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "app.cloak.wallet/updater",
        binaryMessenger: controller.engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "checkForUpdates" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let arguments = call.arguments as? [String: Any],
              let tag = arguments["tag"] as? String,
              let version = arguments["version"] as? String,
              tag == "v\(version)",
              tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#,
                        options: .regularExpression) != nil else {
          result(FlutterError(
            code: "invalid_release",
            message: "The signed update did not contain a stable release tag",
            details: nil
          ))
          return
        }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              !key.hasPrefix("__") else {
          result(FlutterError(
            code: "not_configured",
            message: "Sparkle public key was not provisioned in this build",
            details: nil
          ))
          return
        }
        // The Dart layer has already verified update-v1 for this exact tag.
        // Never let Sparkle follow the mutable releases/latest feed here.
        self?.verifiedVersion = version
        self?.verifiedFeedURL =
          "https://github.com/fuck-bitcoin/CLOAK_WALLET/releases/download/\(tag)/appcast.xml"
        self?.updaterController.updater.automaticallyChecksForUpdates = false
        self?.updaterController.checkForUpdates(nil)
        result(true)
      }
      updateChannel = channel
    }
    super.applicationDidFinishLaunching(notification)
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    return verifiedFeedURL
  }

  func updater(
    _ updater: SPUUpdater,
    shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvoking installHandler: @escaping () -> Void
  ) -> Bool {
    guard let expectedVersion = verifiedVersion,
          item.displayVersionString == expectedVersion else {
      let alert = NSAlert()
      alert.messageText = "CLOAK Wallet update rejected"
      alert.informativeText = "The Sparkle update did not match the release manifest that CLOAK Wallet verified."
      alert.runModal()
      return true
    }
    guard let channel = updateChannel else {
      // Never let Sparkle relaunch without the Dart wallet shutdown handshake.
      return true
    }
    channel.invokeMethod("prepareForSparkleInstall", arguments: nil) { response in
      if let ready = response as? Bool, ready {
        installHandler()
      } else {
        let alert = NSAlert()
        alert.messageText = "CLOAK Wallet update deferred"
        alert.informativeText = "The wallet could not be saved safely. Try the update again after active transactions and signing requests finish."
        alert.runModal()
      }
    }
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
