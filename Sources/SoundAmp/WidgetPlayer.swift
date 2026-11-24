import AppKit
import WebKit

/// Drives the SoundCloud widget living inside a (mostly hidden) WKWebView.
@MainActor
final class WidgetPlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// (eventType, payload) for every message the page posts.
    var onEvent: ((String, [String: Any]) -> Void)?

    let name: String
    private(set) var pageReady = false
    private var pending: [String] = []

    init(name: String = "player") {
        self.name = name
        let config = WKWebViewConfiguration()
        // Risk #3: let the widget start audio without a click inside the web view.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Never throttle/suspend the widget when its page is hidden (minimized or
        // covered windows, headless tests): it fetches HLS segments from JS timers,
        // and throttling starves the audio buffer.
        config.preferences.inactiveSchedulingPolicy = .none
        // Look like Safari so SoundCloud doesn't serve an "unsupported browser" page.
        config.applicationNameForUserAgent = "Version/18.6 Safari/605.1.15"
        let contentController = WKUserContentController()
        config.userContentController = contentController
        // Runs inside the SoundCloud player iframe too: reports the stream format
        // it actually fetches (HLS paths look like …/aac_160k/…/playlist.m3u8).
        contentController.addUserScript(WKUserScript(source: Self.streamWatcherJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // Also inside the iframe: keeps our playback speed applied to its <audio>.
        contentController.addUserScript(WKUserScript(source: Self.rateControlJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 166), configuration: config)
        super.init()

        contentController.add(WeakScriptHandler(self), name: "sa")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.loadHTMLString(WidgetPage.html, baseURL: WidgetPage.baseURL)
    }

    static let streamWatcherJS = #"""
    (function () {
      if (location.host !== 'w.soundcloud.com') return;
      var last = '';
      setInterval(function () {
        var entries = performance.getEntriesByType('resource');
        performance.clearResourceTimings(); // the buffer stops recording after 250 entries
        for (var i = entries.length - 1; i >= 0; i--) {
          var m = /\/((aac|mp3|opus|abr)[a-z0-9_]*)\/[^\/]+\/(playlist\.m3u8|init\.mp4|data\d+\.m4s|[^\/]+\.(mp3|opus|aac))/i.exec(entries[i].name);
          if (!m) continue;
          if (m[1] !== last) {
            last = m[1];
            try { window.webkit.messageHandlers.sa.postMessage({ type: 'stream', preset: m[1], codec: m[2].toLowerCase() }); } catch (e) {}
          }
          break;
        }
      }, 1000);
    })();
    """#

    /// Speed control for the widget's own <audio> element (not in the DOM; it's an
    /// MSE blob). We wrap HTMLMediaElement.play to catch it, and keep re-applying
    /// the rate because the widget creates a new element / resets it per track.
    static let rateControlJS = #"""
    (function () {
      if (location.host !== 'w.soundcloud.com') return;
      var media = [];
      window.__saRate = 1; window.__saKeepPitch = false;
      function post(m) { try { window.webkit.messageHandlers.sa.postMessage(m); } catch (e) {} }
      function apply(el) {
        if (el.preservesPitch !== window.__saKeepPitch) el.preservesPitch = window.__saKeepPitch;
        if (Math.abs(el.playbackRate - window.__saRate) > 0.001) el.playbackRate = window.__saRate;
      }
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        if (media.indexOf(this) < 0) {
          media.push(this);
          var el = this;
          ['loadedmetadata', 'playing', 'ratechange'].forEach(function (ev) { el.addEventListener(ev, function () { apply(el); }); });
          apply(this);
          post({ type: 'mediaRate', rate: this.playbackRate, keepPitch: this.preservesPitch, elements: media.length });
        }
        apply(this);
        return play.apply(this, arguments);
      };
      window.__saSetRate = function (rate, keepPitch) {
        window.__saRate = rate; window.__saKeepPitch = !!keepPitch;
        media.forEach(apply);
        var el = media[media.length - 1];
        post({ type: 'mediaRate', rate: el ? el.playbackRate : rate, keepPitch: el ? el.preservesPitch : !!keepPitch, elements: media.length });
      };
      post({ type: 'mediaFrame' });
    })();
    """#

    private var mediaFrame: WKFrameInfo?
    private var rate: (Double, Bool) = (1, false)

    /// Playback speed of SoundCloud's player. keepPitch: WebKit time-stretch;
    /// otherwise varispeed (pitch follows speed).
    func setPlaybackRate(_ rate: Double, keepPitch: Bool) {
        self.rate = (rate, keepPitch)
        pushRate()
    }

    private func pushRate() {
        guard let frame = mediaFrame else { return } // applied when the iframe registers
        let js = "window.__saSetRate && window.__saSetRate(\(rate.0), \(rate.1))"
        webView.evaluateJavaScript(js, in: frame, in: .page) { [name] result in
            if case let .failure(e) = result { Log("[\(name)] rate: \(e.localizedDescription)") }
        }
    }

    // MARK: Commands

    func load(_ url: String, autoPlay: Bool = true, token: Int = 0) {
        call("load(\(Self.jsString(url)), \(autoPlay), \(token))")
    }
    func requestSounds() { call("sounds()") }
    func toggle() { call("toggle()") }
    func play() { call("play()") }
    func pause() { call("pause()") }
    func next() { call("next()") }
    func prev() { call("prev()") }
    func skip(to index: Int) { call("skip(\(index))") }
    func seek(toMilliseconds ms: Double) { call("seek(\(Int(ms)))") }
    func setVolume(_ volume: Int) { call("volume(\(max(0, min(100, volume))))") }

    private func call(_ expression: String) {
        let js = "window.sa && window.sa.\(expression)"
        guard pageReady else { pending.append(js); return }
        webView.evaluateJavaScript(js) { _, error in
            if let error { Log("[\(self.name)] JS call failed (\(expression)): \(error.localizedDescription)") }
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "mediaFrame" {
            mediaFrame = message.frameInfo
            if rate != (1, false) { pushRate() }
            return
        }
        if type == "pageReady" {
            pageReady = true
            let queued = pending
            pending.removeAll()
            for js in queued { webView.evaluateJavaScript(js, completionHandler: nil) }
        }
        onEvent?(type, body)
    }

    // MARK: Navigation — keep the widget inside, send real links to the browser

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log("Web view navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log("Web view provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log("⚠️ [\(name)] WebContent process terminated — reloading widget page")
        pageReady = false
        webView.loadHTMLString(WidgetPage.html, baseURL: WidgetPage.baseURL)
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
