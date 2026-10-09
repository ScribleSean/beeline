import AppKit
import AVFoundation
import FoundationModels
import Speech

enum Preflight {
    static func report() async -> String {
        var lines = [
            "accessibility=\(AXIsProcessTrusted())",
            "inputMonitoring=\(CGPreflightListenEventAccess())",
            "screenCapture=\(CGPreflightScreenCaptureAccess())",
            "microphoneAuthorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)",
            "speechAuthorization=\(SFSpeechRecognizer.authorizationStatus().rawValue)",
            "speechTranscriberAvailable=\(SpeechTranscriber.isAvailable)",
            "locale=\(Locale.current.identifier)"
        ]
        switch SystemLanguageModel.default.availability {
        case .available: lines.append("localModel=available")
        case .unavailable(let reason): lines.append("localModel=unavailable(\(reason))")
        }
        let transcriberLocales = await SpeechTranscriber.installedLocales
        lines.append("speechInstalledLocales=\(transcriberLocales.map(\.identifier).sorted().joined(separator: ","))")
        let dictationLocales = await DictationTranscriber.installedLocales
        lines.append("dictationInstalledLocales=\(dictationLocales.map(\.identifier).sorted().joined(separator: ","))")
        return lines.joined(separator: "\n")
    }
}
