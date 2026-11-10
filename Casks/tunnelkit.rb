cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "1.0.0"
  sha256 arm:          "c801d4e97f22ec654597fab5c5935cbfcfae520d1eb60410aeca1589a65a5b29",
         intel:        "43828940a7b77af17cd0e834b007ccefd4fb76367232a06422fe6fd554b81b3d",
         arm64_linux:  "d81af33ef036cd2c1910a409e3c60442936ccd66486ae03249fa354cc2ba316a",
         x86_64_linux: "32f593a02929d12fe421301a43255d210c548c15b86091197589e8a980fff28d"

  on_macos do
    url "https://github.com/maybk/tunnelkit/releases/download/v#{version}/tunnelkit-#{version}-macos-#{arch}.dmg"

    app "tunnelkit.app"

    postflight_steps do
      run "/usr/bin/xattr",
          args:           ["-rd", "com.apple.quarantine", "{{appdir}}/tunnelkit.app"],
          writable_paths: ["tunnelkit.app"],
          writable_base:  :appdir
    end

    zap trash: [
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

    zap trash: "~/.tunnelkit"
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
