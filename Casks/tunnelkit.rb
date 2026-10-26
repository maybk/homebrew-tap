cask "tunnelkit" do
  arch arm: "arm64", intel: "amd64"

  version "0.2.2"
  sha256 arm:          "ed0b4e54ce1f37d73df9cb15127e56d93d6f48d922594669160a288155e16c39",
         intel:        "3400165604bd4de158c109da253823936cb9141c5f43e20f32acf87377916abc",
         arm64_linux:  "e80de751d67d6ff35fa5434d315990abcdf7bda511ff9bd2c519df82c0756d1d",
         x86_64_linux: "fdb71e130786deaf6e4f7b311f89aeb59dfe41b0ddc1a96e18fdc82028207a41"

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
