import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var scannerBridge: DocumentScannerBridge?
  private var pendingImports: [[String:String]] = []
  private var importsChannel: FlutterMethodChannel?
  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    guard url.isFileURL else { return false }
    let allowed = ["pdf","jpg","jpeg","png","webp","tif","tiff"]
    let ext = url.pathExtension.lowercased()
    guard allowed.contains(ext) else { return false }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
      guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 150*1024*1024 else { return false }
      let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
      try FileManager.default.copyItem(at: url, to: destination)
      try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:destination.path)
      pendingImports.append(["path":destination.path,"name":url.lastPathComponent])
      importsChannel?.invokeMethod("available",arguments:nil)
      return true
    } catch { return false }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PdfSuiteScanner") {
      scannerBridge = DocumentScannerBridge(messenger: registrar.messenger())
      importsChannel=FlutterMethodChannel(name:"pdf_suite/imports",binaryMessenger:registrar.messenger())
      importsChannel?.setMethodCallHandler { [weak self] call,result in
        if call.method == "takePending" {
          let files=self?.pendingImports ?? [];self?.pendingImports=[];result(files)
        } else {result(FlutterMethodNotImplemented)}
      }
    }
  }
}
