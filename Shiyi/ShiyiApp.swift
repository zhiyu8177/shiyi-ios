import SwiftUI
import WebKit
import AVFoundation
import UIKit

// 电脑端服务地址候选（蒲公英组网 IP 变了不用重编壳：启动后自动探测，谁通用谁）
private let SERVER_CANDIDATES = [
    "http://172.16.2.89:8899",   // 联想机旧地址（保留兼容）
    "http://172.16.2.248:8899",  // 本机（至强）蒲公英地址
    "http://192.168.1.3:8899",   // 手机与电脑同一 WiFi 时直连
]
private var SERVER = SERVER_CANDIDATES[0]

/// 探测某个地址的 /health，回调保证在主线程
private func probeHealth(_ base: String, timeout: TimeInterval = 3,
                         completion: @escaping (Bool) -> Void) {
    guard let url = URL(string: base + "/health") else {
        DispatchQueue.main.async { completion(false) }
        return
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.cachePolicy = .reloadIgnoringLocalCacheData
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DispatchQueue.main.async { completion(code == 200 && data != nil) }
    }.resume()
}

/// 按顺序探测候选地址，命中即更新全局 SERVER
private func resolveServer(index: Int = 0, completion: (() -> Void)? = nil) {
    if index >= SERVER_CANDIDATES.count { completion?(); return }
    let base = SERVER_CANDIDATES[index]
    probeHealth(base) { ok in
        if ok {
            SERVER = base
            completion?()
        } else {
            resolveServer(index: index + 1, completion: completion)
        }
    }
}

// ---------------- JSON / JS 字符串工具 ----------------
private func jsonString(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

/// 生成合法的 JS 字符串字面量（自动处理引号、换行、中文）
private func jsLiteral(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
    let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())
}

// ---------------- 原生桥：接口请求 + 录音 + 朗读 ----------------
final class NativeBridge: NSObject, WKScriptMessageHandler,
                          AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    weak var webView: WKWebView?

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var recordStartedAt: Date?
    private var cancelRequested = false

    private var player: AVAudioPlayer?
    private var ttsLoading = false

    // ========== 消息入口：api（接口） / voice（录音） ==========
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "voice" {
            guard let cmd = message.body as? String else { return }
            switch cmd {
            case "down":   startRecording()
            case "up":     stopRecording(cancel: false)
            case "cancel": stopRecording(cancel: true)
            default: break
            }
            return
        }

        guard message.name == "api",
              let body = message.body as? [String: Any] else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let method = body["method"] as? String ?? ""
        let params = body["params"] as? [String: Any] ?? [:]

        switch method {
        case "health":
            health(id)
        case "reset":
            reset(id)
        case "history":
            // 共享历史：桌面端和手机端同一份，?since=<id> 只取新增
            history(id,
                    since: (params["since"] as? NSNumber)?.intValue ?? 0,
                    limit: (params["limit"] as? NSNumber)?.intValue ?? 60)
        case "chat":
            chat(id, params)
        case "tts":
            speak(id, text: params["text"] as? String ?? "")
        case "ttsStop":
            stopPlayback()
            resolve(id, ["playing": false])
        case "alerts":
            // 取盯盘提醒：界面上每 10 秒拉一次，有新的就弹窗 + 震一下
            alerts(id, since: (params["since"] as? NSNumber)?.intValue ?? 0)
        case "buzz":
            // iOS 的 WKWebView 不支持 navigator.vibrate，震动只能走原生
            buzz(id, style: params["style"] as? String ?? "medium")
        default:
            reject(id, "未知方法：\(method)")
        }
    }

    // ========== 回调网页 ==========
    private func eval(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func resolve(_ id: Int, _ data: [String: Any]) {
        eval("window.__shiyiCb && window.__shiyiCb(\(id), \(jsLiteral(jsonString(["ok": true, "data": data]))));")
    }

    private func reject(_ id: Int, _ message: String) {
        eval("window.__shiyiCb && window.__shiyiCb(\(id), \(jsLiteral(jsonString(["ok": false, "error": message]))));")
    }

    private func status(_ text: String, _ level: String = "") {
        eval("window.__shiyiStatus && window.__shiyiStatus(\(jsLiteral(text)), \(jsLiteral(level)));")
    }

    // ========== HTTP ==========
    private func post(_ path: String, json: [String: Any]?,
                      completion: @escaping (Data?, Int, String?) -> Void) {
        guard let url = URL(string: SERVER + path) else {
            completion(nil, 0, "地址错误"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let json = json,
           let body = try? JSONSerialization.data(withJSONObject: json, options: []) {
            req.httpBody = body
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if err != nil { resolveServer() }   // 连不上就顺手换下一个可用地址
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { completion(data, code, err?.localizedDescription) }
        }.resume()
    }

    // ========== 健康检查 ==========
    private func health(_ id: Int) {
        // 当前地址不通就自动换候选，不用每次手点「检」
        probeHealth(SERVER) { [weak self] ok in
            guard let self = self else { return }
            if ok { self.healthRequest(id); return }
            resolveServer { self.healthRequest(id) }
        }
    }

    private func healthRequest(_ id: Int) {
        guard let url = URL(string: SERVER + "/health") else { reject(id, "地址错误"); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err { self.reject(id, "连不上电脑：\(err)"); return }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.reject(id, "返回值异常"); return
                }
                self.resolve(id, ["status": obj["status"] as? String ?? "ok"])
            }
        }.resume()
    }

    // ========== 盯盘提醒 ==========
    /// GET 一个 JSON，回调 (对象, 状态码)。连不上给 (nil, 0)。
    private func fetchJSON(_ path: String, _ cb: @escaping ([String: Any]?, Int) -> Void) {
        guard let url = URL(string: SERVER + path) else { cb(nil, 0); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var obj: [String: Any]?
            if err == nil, let d = data {
                obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            }
            DispatchQueue.main.async { cb(obj, code) }
        }.resume()
    }

    /// 拉取盯盘提醒。
    /// 正路是 /alerts；如果电脑端还是旧代码（404），就退回去读静态清单
    /// /manifest.json —— 那个文件每次请求都重新读盘，所以不重启服务也能送达。
    private func alerts(_ id: Int, since: Int) {
        func viaManifest() {
            fetchJSON("/manifest.json") {
                [weak self] obj, code in
                guard let self = self else { return }
                guard code == 200, let m = obj else { self.reject(id, "连不上电脑"); return }
                let al = (m["alerts"] as? [[String: Any]]) ?? []
                let items = al.filter { (($0["id"] as? NSNumber)?.intValue ?? 0) > since }
                let last = ((al.last?["id"]) as? NSNumber)?.intValue ?? 0
                self.resolve(id, ["payload": ["items": items, "last": last]])
            }
        }

        func live() {
            fetchJSON("/alerts?since=\(since)") { [weak self] obj, code in
                guard let self = self else { return }
                if code == 200, let o = obj { self.resolve(id, ["payload": o]); return }
                viaManifest()
            }
        }

        probeHealth(SERVER, timeout: 1.5) { ok in
            if ok { live(); return }
            resolveServer { live() }
        }
    }

    /// 震动。style: light / medium / heavy
    private func buzz(_ id: Int, style: String) {
        let g = UIImpactFeedbackGenerator(
            style: style == "heavy" ? .heavy : (style == "light" ? .light : .medium))
        g.prepare()
        g.impactOccurred()
        if style == "heavy" {
            // 紧急提醒多震两下，口袋里有感觉
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        resolve(id, ["ok": true])
    }

    // ========== 清空会话 ==========
    private func reset(_ id: Int) {
        post("/api/reset", json: [:]) { [weak self] data, code, err in
            guard let self = self else { return }
            if let err = err { self.reject(id, "清空失败：\(err)"); return }
            if code >= 400 { self.reject(id, "清空失败（HTTP \(code)）"); return }
            self.resolve(id, ["ok": true])
        }
    }

    // ========== 共享历史 ==========
    /// 读服务端落盘的共享历史。走原生 GET（CFNetwork），
    /// 这样即使界面是从包里 file:// 加载的，也不会被 WKWebView 的跨源策略挡掉。
    private func history(_ id: Int, since: Int, limit: Int) {
        let qs = since > 0 ? "?since=\(since)&limit=\(limit)" : "?limit=\(limit)"
        fetchJSON("/history" + qs) { [weak self] obj, code in
            guard let self = self else { return }
            guard let obj = obj else {
                self.reject(id, "历史读取失败（HTTP \(code)）")
                return
            }
            self.resolve(id, obj)
        }
    }

    // ========== 对话 ==========
    private func chat(_ id: Int, _ params: [String: Any]) {
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { reject(id, "内容为空"); return }
        let payload: [String: Any] = [
            "text": text,
            "session_id": params["session"] as? String ?? "",
            "to": params["to"] as? String ?? "shiyi"
        ]
        post("/chat", json: payload) { [weak self] data, code, err in
            guard let self = self else { return }
            if let err = err {
                self.reject(id, "请求失败：\(err)")
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.reject(id, "电脑返回异常（HTTP \(code)）")
                return
            }
            if let e = obj["error"] as? String, !e.isEmpty {
                self.reject(id, e)
                return
            }
            let reply = obj["reply"] as? String ?? ""
            self.resolve(id, ["reply": reply, "done": true])
        }
    }

    // ========== 朗读（原生播放，不经过网页音频） ==========
    private func speak(_ id: Int, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { reject(id, "内容为空"); return }
        if ttsLoading { reject(id, "正在合成中"); return }
        ttsLoading = true
        post("/tts", json: ["text": String(t.prefix(500))]) { [weak self] data, code, err in
            guard let self = self else { return }
            self.ttsLoading = false
            if let err = err { self.reject(id, "朗读失败：\(err)"); return }
            guard let data = data, !data.isEmpty, code < 400 else {
                self.reject(id, "朗读失败（HTTP \(code)）"); return
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                               options: [.duckOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                self.player?.stop()
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                self.player = p
                self.resolve(id, ["playing": true])
            } catch {
                self.reject(id, "播放失败：\(error.localizedDescription)")
            }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.player = nil
            self.eval("window.__shiyiTtsDone && window.__shiyiTtsDone();")
        }
    }

    // ========== 录音（16k 单声道 WAV，FunASR 直接吃） ==========
    private func startRecording() {
        if recorder != nil { return }
        stopPlayback()

        let session = AVAudioSession.sharedInstance()
        let begin: () -> Void = { [weak self] in
            guard let self = self else { return }
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true, options: [])
            } catch {
                self.status("录音设备被占用", "err")
                self.rejectRecording("音频初始化失败")
                return
            }

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("shiyi_voice.wav")
            try? FileManager.default.removeItem(at: url)
            do {
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.delegate = self
                rec.isMeteringEnabled = true
                rec.record()
                self.recorder = rec
                self.audioURL = url
                self.recordStartedAt = Date()
                self.cancelRequested = false
                self.status("正在听…", "warn")
            } catch {
                self.status("录音启动失败", "err")
                self.rejectRecording("录音启动失败")
            }
        }

        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { begin() } else { self.denied() }
                }
            }
        } else {
            session.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted { begin() } else { self.denied() }
                }
            }
        }
    }

    private func denied() {
        status("麦克风权限被拒绝", "err")
        eval("window.__shiyiAsr && window.__shiyiAsr('', false, '请到 设置→拾壹 里打开麦克风');")
    }

    private func rejectRecording(_ message: String) {
        eval("window.__shiyiAsr && window.__shiyiAsr('', false, \(jsLiteral(message)));")
    }

    private func stopRecording(cancel: Bool) {
        guard let rec = recorder else { return }
        cancelRequested = cancel
        rec.stop()
        recorder = nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        defer { recordStartedAt = nil }
        let url = audioURL
        let elapsed = recordStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        if cancelRequested {
            cancelRequested = false
            status("已取消", "")
            return
        }
        guard flag, let url = url else {
            status("录音失败", "err")
            rejectRecording("录音失败，请重试")
            return
        }
        if elapsed < 0.5 {
            status("说话时间太短", "warn")
            rejectRecording("说话时间太短")
            return
        }
        upload(url)
    }

    private func upload(_ url: URL) {
        status("识别中…", "warn")
        guard let endpoint = URL(string: SERVER + "/asr") else {
            rejectRecording("地址错误"); return
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180

        URLSession.shared.uploadTask(with: req, fromFile: url) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.status("识别失败", "err")
                    self.rejectRecording("连不上电脑：\(err.localizedDescription)")
                    return
                }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.status("识别失败", "err")
                    self.rejectRecording("电脑返回异常")
                    return
                }
                if let e = obj["error"] as? String, !e.isEmpty {
                    self.status("识别失败", "err")
                    self.rejectRecording(e)
                    return
                }
                let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    self.status("没听清", "warn")
                    self.rejectRecording("没听清，再说一次")
                    return
                }
                self.status("已识别", "ok")
                self.eval("window.__shiyiAsr && window.__shiyiAsr(\(jsLiteral(text)), true, '');")
            }
        }.resume()
    }
}

// ---------------- WebView 壳 ----------------
struct WebView: UIViewRepresentable {
    let bridge: NativeBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(bridge, name: "api")
        config.userContentController.add(bridge, name: "voice")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.96, green: 0.955, blue: 0.945, alpha: 1)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false

        bridge.webView = webView

        // 界面优先从电脑上的服务端拉（2026-10-23）：
        // 以前 index.html 打进包里，改一行界面就得重新打包安装，手机端永远落后一个包。
        // 但旧写法是直接拿 SERVER（候选第 0 个 = 已停用的联想机地址）去 load，
        // 地址一死必然超时、退回包内 file:// 页面，而 file:// 页面 fetch 服务端会被
        // WKWebView 跨源拦掉 —— 表现就是"界面能开、历史一条不显示、发消息也没回显"。
        // 现在：先并发探测候选地址，先通先加载；全都不通才退回包内页面（走原生桥，功能仍是全的）。
        webView.navigationDelegate = context.coordinator
        context.coordinator.begin(webView)

        // 长按不弹菜单，操作更像原生 App
        let css = "addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');" +
                  "s.textContent='*{-webkit-touch-callout:none;}';document.head.appendChild(s);});"
        webView.evaluateJavaScript(css, completionHandler: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 先探测地址再决定加载哪份界面。
    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var view: WKWebView?
        private var decided = false
        private var isRemote = false

        func begin(_ webView: WKWebView) {
            view = webView
            let group = DispatchGroup()
            for base in SERVER_CANDIDATES {
                group.enter()
                probeHealth(base, timeout: 4) { ok in
                    if ok { self.pick(base) }
                    group.leave()
                }
            }
            // 全部候选都不通（电脑关机 / 不在同一网络）→ 退回包内页面
            group.notify(queue: .main) {
                if !self.decided {
                    self.decided = true
                    self.loadLocal()
                }
            }
        }

        private func pick(_ base: String) {
            guard !decided else { return }
            decided = true
            isRemote = true
            SERVER = base                      // 原生桥的接口也统一用这个地址
            guard let url = URL(string: base + "/") else { loadLocal(); return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            view?.load(req)
        }

        private func loadLocal() {
            isRemote = false
            if let local = Bundle.main.url(forResource: "index", withExtension: "html") {
                view?.loadFileURL(local, allowingReadAccessTo: local.deletingLastPathComponent())
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if isRemote { loadLocal() }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            if isRemote { loadLocal() }
        }
    }
}

// ---------------- 入口 ----------------
@main
struct ShiyiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var holder = BridgeHolder()

    var body: some View {
        WebView(bridge: holder.bridge)
            .ignoresSafeArea()
            .preferredColorScheme(.light)
    }
}

final class BridgeHolder: ObservableObject {
    let bridge = NativeBridge()
}
