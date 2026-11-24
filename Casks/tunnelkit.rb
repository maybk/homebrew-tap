cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.1.3"
  sha256 arm:          "e6ca3c2fb65d171cdfc6356bbc690d673ce888f60ea5b8b4aaff93907fdb76b8",
         intel:        "49e17d81925e518d6618e1ce22f1def8d66c124a1b93baf54c3ca80361f58eb3",
         arm64_linux:  "587d09504523c3e6684bced05b280b0886d0e159937c9078ecb4c2902dad9574",
         x86_64_linux: "d58c25a30747c9f0f60d820c1e7b35bd59514a5bb09be0cd3168c62c4dd8feed"

  on_macos do
    url "https://github.com/maybk/tunnelkit/releases/download/v#{version}/tunnelkit-#{version}-macos-#{arch}.dmg"

    depends_on macos: :monterey

    app "TunnelKit.app"

    postflight_steps do
      run "/usr/bin/xattr",
          args:           ["-rd", "com.apple.quarantine", "{{appdir}}/TunnelKit.app"],
          writable_paths: ["TunnelKit.app"],
          writable_base:  :appdir
    end

    uninstall quit: "com.tunnelkit.app"

    zap delete: [
          "/Library/Application Support/TunnelKit",
          "/Library/PrivilegedHelperTools/com.tunnelkit.helper",
        ],
        trash:  [
          "~/.tunnelkit",
          "~/Library/Application Support/com.tunnelkit.app",
          "~/Library/Caches/com.tunnelkit.app",
          "~/Library/Preferences/com.tunnelkit.app.plist",
          "~/Library/Saved Application State/com.tunnelkit.app.savedState",
        ]
  end
  on_linux do
    url "https://github.com/maybk/tunnelkit/releases/download/v#{version}/tunnelkit-#{version}-linux-#{arch}.tar.gz"

    binary "tunnelkit"
    binary "tunnelkit-helper"

    zap delete: [
          "/usr/libexec/tunnelkit",
          "/var/lib/tunnelkit",
        ],
        trash:  "~/.tunnelkit"
  end

  name "TunnelKit"
  desc "Fortinet SSL-VPN desktop and menu bar client"
  homepage "https://github.com/maybk/tunnelkit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
end
