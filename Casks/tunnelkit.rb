cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.1.0"
  sha256 arm:          "7907d3ad59ed988aec24e30b100fc10e33ad861ec473f567953388a3e1ff4624",
         intel:        "0ed4cb4276fe5525cb5ab9b4361698add1e63c6e38d3d5f7a84f1c8f3b6991ea",
         arm64_linux:  "15d358dbbeef5284912cd2e3637fff314cc5adf4b07e6f4fb27676d22ae16730",
         x86_64_linux: "6d9018beec1336cc49166d5c30ed5609015e3867b89efbb95b79dd7a292ac409"

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
