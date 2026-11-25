cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.1.4"
  sha256 arm:          "e83337138cfc22e76850d0a168590173b069e52e6af431655cf0490c4e9eb3c5",
         intel:        "c716fabf5081bedb785cada456b776f989487107e872b3dfd7c18c0ffc1e2c6c",
         arm64_linux:  "6ee9a206593092df9ae171b27ebadce78f8199320ff4c83493f77d3b6113cae4",
         x86_64_linux: "faf46d15b748f36cc1f3d46a248f65407dacb13e4fe54003f8fdad3f975ed32a"

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
