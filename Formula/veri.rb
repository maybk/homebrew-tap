class Veri < Formula
  desc "Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill)"
  homepage "https://github.com/maybk/veri"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-arm64.tar.gz"
      sha256 "bff8247575c0de6c1c54cd466134182056a3027b60ca381311ef1ccd0ada1102"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-amd64.tar.gz"
      sha256 "f1db6fbc8eb7e28e84e1e7b05e3dba7b9ce8a657d74bcaa0ba0be4d1ed8dbc0c"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-arm64.tar.gz"
      sha256 "37f56493941ed48bb644fadadb377778e6438772f2bb39d1a5ad0862cfac9eec"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-amd64.tar.gz"
      sha256 "e9cbbb4391206a0fba6d1d0257b2413a9f03fd19994183bfda920453315cb7d0"
    end
  end

  def install
    bin.install "veri"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/veri version")
  end
end
