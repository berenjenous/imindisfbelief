import UIKit
import WebKit

/// Diagnostic wrapper: loads the official Webrune site (nothing bundled),
/// captures console output / errors / WASM memory growth from every frame,
/// and records WebContent process crashes (typical of out-of-memory kills).
final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    static let startURL = URL(string: "https://webrune.mrpowergamerbr.com/")!

    private var webView: WKWebView!
    private let logView = UITextView()
    private let toggleButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private var lines: [String] = []
    private let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("webrune-log.txt")

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        try? "".write(to: logURL, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()   // persistent storage (OPFS / IndexedDB)

        let ucc = config.userContentController
        ucc.add(self, name: "diag")
        let src = (try? String(contentsOf: Bundle.main.url(forResource: "inject", withExtension: "js")!, encoding: .utf8)) ?? ""
        // forMainFrameOnly: false -> also runs inside the /boxed-runner iframe
        ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view.addSubview(webView)

        logView.isEditable = false
        logView.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        logView.textColor = .green
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.isHidden = true
        view.addSubview(logView)

        for (b, t) in [(toggleButton, "LOG"), (shareButton, "SHARE"), (reloadButton, "RELOAD")] {
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 11)
            b.backgroundColor = UIColor.darkGray.withAlphaComponent(0.6)
            b.setTitleColor(.white, for: .normal)
            b.layer.cornerRadius = 6
            view.addSubview(b)
        }
        toggleButton.addTarget(self, action: #selector(toggleLog), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareLog), for: .touchUpInside)
        reloadButton.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)
        shareButton.isHidden = true
        reloadButton.isHidden = true
        toggleButton.isHidden = true   // debug UI hidden; 3-finger long press shows it

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(debugGesture(_:)))
        lp.numberOfTouchesRequired = 3
        lp.minimumPressDuration = 1.5
        lp.cancelsTouchesInView = false
        view.addGestureRecognizer(lp)

        UIApplication.shared.isIdleTimerDisabled = true   // keep screen on while playing

        log("APP", "start \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), physical RAM \(ProcessInfo.processInfo.physicalMemory / 1_048_576) MB")
        webView.load(URLRequest(url: Self.startURL))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let x = view.bounds.width - safe.right - 64
        toggleButton.frame = CGRect(x: x, y: safe.top + 4, width: 56, height: 24)
        shareButton.frame = CGRect(x: x, y: safe.top + 32, width: 56, height: 24)
        reloadButton.frame = CGRect(x: x, y: safe.top + 60, width: 56, height: 24)
        logView.frame = view.bounds.inset(by: UIEdgeInsets(top: safe.top + 4, left: safe.left + 4, bottom: safe.bottom + 4, right: safe.right + 70))
    }

    // MARK: logging

    private func log(_ tag: String, _ msg: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) [\(tag)] \(msg)"
        lines.append(line)
        if lines.count > 3000 { lines.removeFirst(lines.count - 3000) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close()
        }
        if !logView.isHidden { refreshLogView() }
    }

    private func refreshLogView() {
        logView.text = lines.joined(separator: "\n")
        let end = NSRange(location: (logView.text as NSString).length, length: 0)
        logView.scrollRangeToVisible(end)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any] else { return }
        let level = d["level"] as? String ?? "?"
        let frame = message.frameInfo.isMainFrame ? "main" : "frame"
        var msg = d["msg"] as? String ?? ""
        if msg.count > 2000 { msg = String(msg.prefix(2000)) + "…" }
        log("\(frame)/\(level)", msg)
    }

    // MARK: buttons

    @objc private func debugGesture(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        toggleButton.isHidden.toggle()
        if toggleButton.isHidden {
            logView.isHidden = true; shareButton.isHidden = true; reloadButton.isHidden = true
        }
    }

    @objc private func toggleLog() {
        logView.isHidden.toggle()
        shareButton.isHidden = logView.isHidden
        reloadButton.isHidden = logView.isHidden
        if !logView.isHidden { refreshLogView() }
    }

    @objc private func shareLog() {
        let vc = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = shareButton
        present(vc, animated: true)
    }

    @objc private func reloadPage() {
        log("APP", "manual reload")
        webView.load(URLRequest(url: Self.startURL))
    }

    // MARK: navigation / process events

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("NAV", "start \(webView.url?.absoluteString ?? "")")
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("NAV", "finish \(webView.url?.absoluteString ?? "")")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("NAV", "fail \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("NAV", "provisional fail \(error.localizedDescription)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("CRASH", "WebContent process TERMINATED (often = iOS killed it for memory). Tap RELOAD to restart.")
        toggleButton.isHidden = false
        if logView.isHidden { toggleLog() }
    }

    // open target=_blank links in the same view
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    // JS alert() support (the runner uses alert for some errors)
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        log("ALERT", message)
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }
}
