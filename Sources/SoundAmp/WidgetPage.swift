import Foundation

/// The tiny HTML page that hosts the SoundCloud widget iframe inside WKWebView.
///
/// It is loaded with `loadHTMLString(_:baseURL:)` and an https base URL so the
/// page gets a real, secure origin (a `file://` page has a "null" origin, which
/// can break the widget's postMessage handshake).
///
/// JS -> native: `window.webkit.messageHandlers.sa.postMessage({type, ...})`
/// native -> JS: `window.sa.<command>(...)` via `evaluateJavaScript`.
enum WidgetPage {
    static let baseURL = URL(string: "https://soundamp.local/")!

    static let html = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
      html, body { margin: 0; height: 100%; background: #111; overflow: hidden; }
      #host { position: absolute; inset: 0; }
      #host iframe { border: 0; width: 100%; height: 100%; }
    </style>
    </head>
    <body>
    <div id="host"></div>
    <script>
      window.onerror = function (msg, src, line) {
        try { window.webkit.messageHandlers.sa.postMessage({ type: 'jsError', message: String(msg), src: String(src), line: line }); } catch (e) {}
      };
    </script>
    <script src="https://w.soundcloud.com/player/api.js"></script>
    <script>
    (function () {
      function post(type, data) {
        var msg = Object.assign({ type: type }, data || {});
        try { window.webkit.messageHandlers.sa.postMessage(msg); } catch (e) {}
      }

      if (typeof SC === 'undefined' || !SC.Widget) {
        post('error', { detail: 'SoundCloud api.js did not load (network blocked?)' });
      }

      var widget = null;
      // Job token: replies carry the token of the load() they belong to, so a
      // late reply for an earlier URL can be told apart.
      var token = 0;
      var WIDGET_PARAMS = {
        auto_play: true, visual: false, show_artwork: false, show_comments: false,
        show_user: false, show_reposts: false, show_teaser: false, hide_related: true,
        buying: false, sharing: false, download: false, single_active: false
      };

      function soundInfo(s) {
        if (!s) return null;
        return {
          id: s.id || 0,
          title: s.title || '',
          artist: (s.user && s.user.username) || '',
          duration: s.duration || 0,
          artwork: s.artwork_url || '',
          permalink: s.permalink_url || '',
          policy: s.policy || '',          // e.g. ALLOW, SNIP (preview), BLOCK
          streamable: s.streamable !== false
        };
      }

      function refresh() {
        if (!widget) return;
        var t = token;
        widget.getCurrentSound(function (s) { post('sound', { sound: soundInfo(s), token: t }); });
        widget.getCurrentSoundIndex(function (i) { post('index', { index: i, token: t }); });
      }

      function refreshList() {
        if (!widget) return;
        var t = token;
        widget.getSounds(function (list) { post('sounds', { sounds: (list || []).map(soundInfo), token: t }); });
      }

      function bind() {
        var E = SC.Widget.Events;
        widget.bind(E.READY, function () { post('ready', { token: token }); refresh(); refreshList(); });
        widget.bind(E.PLAY, function () { post('play'); refresh(); });
        widget.bind(E.PAUSE, function () { post('pause'); });
        widget.bind(E.FINISH, function () { post('finish'); });
        widget.bind(E.SEEK, function (e) { post('seek', { position: e.currentPosition }); });
        widget.bind(E.ERROR, function (e) { post('error', { detail: JSON.stringify(e || null) }); });
        widget.bind(E.PLAY_PROGRESS, function (e) {
          post('progress', { position: e.currentPosition, relative: e.relativePosition, loaded: e.loadedProgress });
        });
      }

      function query(params) {
        return Object.keys(params).map(function (k) { return k + '=' + encodeURIComponent(params[k]); }).join('&');
      }

      window.sa = {
        load: function (url, autoPlay, t) {
          token = t || 0;
          var params = Object.assign({}, WIDGET_PARAMS, { auto_play: autoPlay !== false });
          if (!widget) {
            var iframe = document.createElement('iframe');
            iframe.allow = 'autoplay; encrypted-media';
            iframe.src = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent(url) + '&' + query(params);
            document.getElementById('host').appendChild(iframe);
            widget = SC.Widget(iframe);
            bind();
          } else {
            widget.load(url, Object.assign(params, {
              callback: function () { if (token === (t || 0)) { post('loaded', { token: token }); refresh(); refreshList(); } }
            }));
          }
        },
        sounds: function () { refreshList(); },
        play: function () { widget && widget.play(); },
        pause: function () { widget && widget.pause(); },
        toggle: function () { widget && widget.toggle(); },
        next: function () { widget && widget.next(); },
        prev: function () { widget && widget.prev(); },
        skip: function (i) { widget && widget.skip(i); },
        seek: function (ms) { widget && widget.seekTo(ms); },
        volume: function (v) { widget && widget.setVolume(v); }
      };

      post('pageReady', { origin: location.origin, ua: navigator.userAgent, secure: window.isSecureContext });
    })();
    </script>
    </body>
    </html>
    """#
}
