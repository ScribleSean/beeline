import AppKit

enum SettingsPanes {
    private static let panes: [(title: String, id: String, keywords: String)] = [
        ("Wi-Fi", "com.apple.wifi-settings-extension", "wifi wireless internet network hotspot"),
        ("Bluetooth", "com.apple.BluetoothSettings", "airpods headphones pair devices"),
        ("Network", "com.apple.Network-Settings.extension", "ethernet dns proxy firewall ip internet"),
        ("VPN", "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "private network tunnel"),
        ("Notifications", "com.apple.Notifications-Settings.extension", "alerts banners badges"),
        ("Sound", "com.apple.Sound-Settings.extension", "volume audio output input microphone speakers"),
        ("Focus", "com.apple.Focus-Settings.extension", "do not disturb dnd sleep work"),
        ("Screen Time", "com.apple.Screen-Time-Settings.extension", "limits downtime usage"),
        ("General", "com.apple.systempreferences.GeneralSettings", "about airdrop handoff"),
        ("Software Update", "com.apple.Software-Update-Settings.extension", "macos update upgrade version"),
        ("Storage", "com.apple.settings.Storage", "disk space free full"),
        ("Login Items", "com.apple.LoginItems-Settings.extension", "startup launch background extensions"),
        ("Language & Region", "com.apple.Localization-Settings.extension", "locale format temperature units"),
        ("Date & Time", "com.apple.Date-Time-Settings.extension", "clock timezone"),
        ("Sharing", "com.apple.Sharing-Settings.extension", "screen sharing file sharing remote login hostname"),
        ("Time Machine", "com.apple.Time-Machine-Settings.extension", "backup restore"),
        ("Appearance", "com.apple.Appearance-Settings.extension", "dark mode light mode theme accent tint"),
        ("Accessibility", "com.apple.Accessibility-Settings.extension", "zoom voiceover contrast motion captions"),
        ("Control Center", "com.apple.ControlCenter-Settings.extension", "menu bar icons battery percentage clock"),
        ("Siri", "com.apple.Siri-Settings.extension", "apple intelligence assistant"),
        ("Spotlight", "com.apple.Spotlight-Settings.extension", "search indexing"),
        ("Privacy & Security", "com.apple.settings.PrivacySecurity.extension",
         "permissions accessibility screen recording camera microphone location filevault gatekeeper automation"),
        ("Desktop & Dock", "com.apple.Desktop-Settings.extension", "stage manager mission control hot corners widgets"),
        ("Displays", "com.apple.Displays-Settings.extension", "screen resolution brightness night shift monitor external scaling refresh"),
        ("Wallpaper", "com.apple.Wallpaper-Settings.extension", "background desktop picture"),
        ("Screen Saver", "com.apple.ScreenSaver-Settings.extension", ""),
        ("Battery", "com.apple.Battery-Settings.extension", "low power mode energy charging health"),
        ("Lock Screen", "com.apple.Lock-Screen-Settings.extension", "sleep display off password timeout"),
        ("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", "fingerprint login"),
        ("Users & Groups", "com.apple.Users-Groups-Settings.extension", "accounts admin guest"),
        ("Passwords", "com.apple.Passwords-Settings.extension", "passkeys keychain"),
        ("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", "icloud google mail calendar contacts"),
        ("Game Center", "com.apple.Game-Center-Settings.extension", ""),
        ("Wallet & Apple Pay", "com.apple.WalletSettingsExtension", "cards payment"),
        ("Keyboard", "com.apple.Keyboard-Settings.extension",
         "shortcuts key repeat dictation input sources text replacement modifier"),
        ("Mouse", "com.apple.Mouse-Settings.extension", "scroll speed tracking natural"),
        ("Trackpad", "com.apple.Trackpad-Settings.extension", "gestures tap to click scroll tracking speed"),
        ("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", "print scan"),
    ]

    static func items() -> [Item] {
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
        return panes.compactMap { pane in
            guard let url = URL(string: "x-apple.systempreferences:" + pane.id) else { return nil }
            return Item(id: "setting:" + pane.id, kind: .setting, verb: "Open", title: pane.title,
                        subtitle: "Settings", keywords: pane.keywords, icon: icon) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
