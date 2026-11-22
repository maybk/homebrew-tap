cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.1.2"
  sha256 arm:          "bc4ccc9be4f8851ab169b44f3004025fe9f72651cacf26151d7465770611c877",
         intel:        "146566464d2206cd21bf2df7a290c2e8ceec124b6f8b939beb338856a1a02e96",
         arm64_linux:  "1c073fa8ab3bc3857fc43d01d737db2863b297820c0a3ca44e53ac64ea02eae8",
         x86_64_linux: "ad48b1057943c67cde3cfa36b89b1ecf966e14e1fae2d9afb2883475855a45e4"

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
