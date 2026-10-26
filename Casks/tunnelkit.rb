cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "0.2.1"
  sha256 arm:          "f43d2123242eef412101a3634f6c61daed57acef3a85e62e8590ec895156fd60",
         intel:        "eaf82c83e02efc7a31f5716bc399ad792b30a05cdaa4b93f338083df5c451e82",
         arm64_linux:  "7dd70e8869b003020f64f7959d280026ce2fbbfed9be772e4d164cbd08179d88",
         x86_64_linux: "bbf5eb546b01fb44a767b02c6b992343c2d3ea03aa77c199b407583febd92a4f"

  name "TunnelKit"
  desc "Fortinet SSL-VPN desktop and menu bar client"
  homepage "https://github.com/maybk/tunnelkit"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  on_macos do
    depends_on macos: ">= :big_sur"

    url "https://github.com/maybk/tunnelkit/releases/download/v#{version}/tunnelkit-#{version}-macos-#{arch}.dmg",
        verified: "github.com/maybk/tunnelkit/"

    app "tunnelkit.app"

    postflight_steps do
      system_command "/usr/bin/xattr",
                     args: ["-rd", "com.apple.quarantine", "{{appdir}}/tunnelkit.app"],
                     writable_paths: ["tunnelkit.app"],
                     writable_base: :appdir
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
    url "https://github.com/maybk/tunnelkit/releases/download/v#{version}/tunnelkit-#{version}-linux-#{arch}.tar.gz",
        verified: "github.com/maybk/tunnelkit/"

    binary "tunnelkit"
    binary "tunnelkit-helper"

    zap trash: [
      "~/.tunnelkit",
    ]
  end
end
