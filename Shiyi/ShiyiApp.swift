import SwiftUI
import WebKit
import AVFoundation

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
        case "chat":
            chat(id, params)
        case "tts":
            speak(id, text: params["text"] as? String ?? "")
        case "ttsStop":
            stopPlayback()
            resolve(id, ["playing": false])
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

    // ========== 清空会话 ==========
    private func reset(_ id: Int) {
        post("/api/reset", json: [:]) { [weak self] data, code, err in
            guard let self = self else { return }
            if let err = err { self.reject(id, "清空失败：\(err)"); return }
            if code >= 400 { self.reject(id, "清空失败（HTTP \(code)）"); return }
            self.resolve(id, ["ok": true])
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

        // 界面打包在 App 内（真 APP 版），启动即用，不联网拉页面
        if let local = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(local, allowingReadAccessTo: local.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: URL(string: SERVER)!))
        }

        // 长按不弹菜单，操作更像原生 App
        let css = "addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');" +
                  "s.textContent='*{-webkit-touch-callout:none;}';document.head.appendChild(s);});"
        webView.evaluateJavaScript(css, completionHandler: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
