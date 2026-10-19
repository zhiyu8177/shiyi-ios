import SwiftUI
import WebKit
import AVFoundation

@main
struct ShiyiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// ---------------- 语音控制器：原生录音 → 本地识别 → 回填页面 ----------------
final class VoiceController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var status = ""
    weak var webView: WKWebView?

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var cancelRequested = false
    private let server = "http://172.16.2.89:8899"

    func start() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if !granted {
                    self.jsStatus("麦克风权限被拒绝，请在设置中开启")
                    return
                }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            jsStatus("音频会话启动失败")
            return
        }

        // 16kHz 单声道 Int16，直接产出标准 WAV，后端 FunASR 可直接识别
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shiyi_voice.wav")
        do {
            let rec = try AVAudioRecorder(url: url, format: fmt)
            rec.delegate = self
            rec.record()
            recorder = rec
            audioURL = url
            isRecording = true
            jsStatus("按住说话中，松开结束…")
        } catch {
            jsStatus("录音启动失败")
        }
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
    }

    // 按住说话：按下开始，松手结束（网页按钮桥接调用）
    func pressStart() {
        if isRecording { return }
        start()
    }

    func releaseStop() {
        if isRecording { stop() }
    }

    // 上滑取消：停止录音且不识别
    func cancelRecording() {
        if isRecording {
            cancelRequested = true
            stop()
        }
    }

    // 把状态写进网页顶部的 #status（绿色小字）
    private func jsStatus(_ s: String) {
        guard let webView else { return }
        let arr = String(data: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
        let jsStr = String(arr.dropFirst().dropLast())
        webView.evaluateJavaScript("var el=document.getElementById('status'); if(el){el.textContent=\(jsStr);}", completionHandler: nil)
    }

    // AVAudioRecorderDelegate：停止后回调
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecording = false
            if self.cancelRequested {
                self.cancelRequested = false
                self.jsStatus("已取消")
                return
            }
            guard flag, let url = self.audioURL else {
                self.jsStatus("录音失败，请重试")
                return
            }
            self.upload(url)
        }
    }

    private func upload(_ url: URL) {
        jsStatus("识别中…（首次约需1分钟加载模型）")
        var req = URLRequest(url: URL(string: server + "/api/transcribe")!)
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180  // 首次模型加载可能较慢，防止 60s 默认超时
        URLSession.shared.uploadTask(with: req, fromFile: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, error == nil,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = obj["text"] as? String, !text.isEmpty else {
                    self.jsStatus("识别失败，请重试")
                    return
                }
                self.jsStatus("")
                self.fillInput(text)
            }
        }.resume()
    }

    private func fillInput(_ text: String) {
        guard let webView else { return }
        // JSON 序列化生成合法 JS 字符串字面量，避免引号/换行破坏语法
        let arr = String(data: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
        let jsStr = String(arr.dropFirst().dropLast())
        let js = "var el=document.getElementById('input'); if(el){el.value=\(jsStr); el.focus();}"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

// ---------------- WebView 壳 ----------------
struct WebView: UIViewRepresentable {
    weak var controller: VoiceController?

    // 接收网页按钮桥接：down=按下开始录音，up=松开结束并识别
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var controller: VoiceController?
        init(_ controller: VoiceController?) { self.controller = controller }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "voice", let cmd = message.body as? String else { return }
            if cmd == "down" { controller?.pressStart() }
            else if cmd == "up" { controller?.releaseStop() }
            else if cmd == "cancel" { controller?.cancelRecording() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 网页输入框旁的麦克风按钮 → 原生录音（按住说话）
        config.userContentController.add(context.coordinator, name: "voice")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.load(URLRequest(url: URL(string: "http://172.16.2.89:8899")!))
        controller?.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// ---------------- 主界面：全屏 WebView（按钮和状态都在网页里） ----------------
struct ContentView: View {
    @StateObject private var voice = VoiceController()

    var body: some View {
        WebView(controller: voice)
            .ignoresSafeArea()
    }
}
