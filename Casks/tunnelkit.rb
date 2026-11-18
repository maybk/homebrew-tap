cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.1.1"
  sha256 arm:          "f30b7b1d8ba022afcc38f77abdf2c66199cd04c382dfc67ba4242f27119b883c",
         intel:        "e762c5422d22ae5f9cf5714ffbe7935bada6671909d1ba5a69ddc78bf1499c2a",
         arm64_linux:  "3c9925c1ba483992d75643d51e345067b8867a4ea7bef3b2518c34dd0df548b7",
         x86_64_linux: "6f623b6b69536d0be736c623bbcc49e4e83345b7b17d205236459976de6b79d8"

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
