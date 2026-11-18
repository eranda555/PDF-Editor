import Flutter
import UIKit
import Vision
import VisionKit
import Security

final class DocumentScannerBridge: NSObject, VNDocumentCameraViewControllerDelegate {
    private var presenter: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    private var pending: FlutterResult?
    private var privacyView: UIView?
    private var sensitive = false
    private var channels: [FlutterMethodChannel] = []

    init(messenger: FlutterBinaryMessenger) {
        super.init()
        let scanner = FlutterMethodChannel(name: "pdf_suite/scanner", binaryMessenger: messenger)
        scanner.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(FlutterError(code: "closed", message: "Scanner closed", details: nil)); return }
            if call.method == "scan" {
                guard self.pending == nil, VNDocumentCameraViewController.isSupported else {
                    result(FlutterError(code: "unavailable", message: "Scanner unavailable", details: nil)); return
                }
                self.pending = result
                let camera = VNDocumentCameraViewController()
                camera.delegate = self
                guard let presenter = self.presenter else {
                    self.pending = nil
                    result(FlutterError(code: "unavailable", message: "No active view controller", details: nil)); return
                }
                presenter.present(camera, animated: true)
            } else if call.method == "recognize", let args = call.arguments as? [String: Any], let path = args["path"] as? String {
                self.recognize(path: path, result: result)
            } else { result(FlutterMethodNotImplemented) }
        }
        let privacy = FlutterMethodChannel(name: "pdf_suite/privacy", binaryMessenger: messenger)
        privacy.setMethodCallHandler { [weak self] call, result in
            if call.method == "protectScreen", let args = call.arguments as? [String: Any] {
                self?.sensitive = args["enabled"] as? Bool ?? false
                result(nil)
            } else { result(FlutterMethodNotImplemented) }
        }
        channels = [scanner, privacy]
        let identity = FlutterMethodChannel(name:"pdf_suite/identity",binaryMessenger:messenger)
        identity.setMethodCallHandler { call,result in
            do {
                if call.method == "publicKey" {result(try HardwareIdentity.publicKey())}
                else if call.method == "sign", let args=call.arguments as? [String:Any],let message=args["message"] as? String {
                    result(try HardwareIdentity.sign(message))
                } else {result(FlutterMethodNotImplemented)}
            } catch {result(FlutterError(code:"identity_unavailable",message:"Secure Enclave signing unavailable",details:nil))}
        }
        channels.append(identity)
        NotificationCenter.default.addObserver(self, selector: #selector(cover), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(uncover), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    @objc private func cover() {
        guard sensitive, let view = presenter?.view, privacyView == nil else { return }
        let overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        privacyView = overlay
    }
    @objc private func uncover() { privacyView?.removeFromSuperview(); privacyView = nil }
    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
        pending?([]); pending = nil
    }
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        controller.dismiss(animated: true)
        pending?(FlutterError(code: "scan_failed", message: "Document scan failed", details: nil)); pending = nil
    }
    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        controller.dismiss(animated: true)
        do {
            guard scan.pageCount <= 20 else { throw NSError(domain: "pdf", code: 1) }
            var paths: [String] = []
            for page in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: page)
                guard let data = image.jpegData(compressionQuality: 0.92) else { throw NSError(domain: "pdf", code: 2) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                paths.append(url.path)
            }
            pending?(paths)
        } catch { pending?(FlutterError(code: "save_failed", message: "Could not save scanned pages", details: nil)) }
        pending = nil
    }
    private func recognize(path: String, result: @escaping FlutterResult) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path + "/"
        guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) else {
            result(FlutterError(code: "invalid_path", message: "Image must be in the app sandbox", details: nil)); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]).perform([request])
                let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
                DispatchQueue.main.async { result(text) }
            } catch { DispatchQueue.main.async { result(FlutterError(code: "ocr_failed", message: "Text recognition failed", details: nil)) } }
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

private enum HardwareIdentity {
    static let tag=Data("pdf_suite_device_v1".utf8)
    static func key() throws -> SecKey {
        let query:[String:Any]=[kSecClass as String:kSecClassKey,kSecAttrApplicationTag as String:tag,
            kSecAttrKeyType as String:kSecAttrKeyTypeECSECPrimeRandom,kSecReturnRef as String:true]
        var item:CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let item=item {
            let key=item as! SecKey
            let attributes=SecKeyCopyAttributes(key) as? [String:Any]
            guard attributes?[kSecAttrTokenID as String] as? String == kSecAttrTokenIDSecureEnclave as String else {throw NSError(domain:"pdf.identity",code:1)}
            return key
        }
        var error:Unmanaged<CFError>?
        guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,.privateKeyUsage,&error) else {
            throw NSError(domain:"pdf.identity",code:2)
        }
        let attributes:[String:Any]=[kSecAttrKeyType as String:kSecAttrKeyTypeECSECPrimeRandom,kSecAttrKeySizeInBits as String:256,
            kSecAttrTokenID as String:kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String:[kSecAttrIsPermanent as String:true,kSecAttrApplicationTag as String:tag,kSecAttrAccessControl as String:access]]
        guard let key=SecKeyCreateRandomKey(attributes as CFDictionary,&error) else {throw NSError(domain:"pdf.identity",code:3)}
        return key
    }
    static func publicKey() throws -> String {
        let privateKey=try key();var error:Unmanaged<CFError>?
        guard let publicKey=SecKeyCopyPublicKey(privateKey),let bytes=SecKeyCopyExternalRepresentation(publicKey,&error) as Data? else {
            throw NSError(domain:"pdf.identity",code:4)
        }
        return bytes.base64EncodedString()
    }
    static func sign(_ message:String) throws -> String {
        let privateKey=try key();var error:Unmanaged<CFError>?
        guard let bytes=SecKeyCreateSignature(privateKey,.ecdsaSignatureMessageX962SHA256,Data(message.utf8) as CFData,&error) as Data? else {
            throw NSError(domain:"pdf.identity",code:5)
        }
        return bytes.base64EncodedString()
    }
}
