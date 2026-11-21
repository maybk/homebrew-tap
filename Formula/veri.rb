class Veri < Formula
  desc "Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill)"
  homepage "https://github.com/maybk/veri"
  version "0.2.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-arm64.tar.gz"
      sha256 "d9e72eaf7f7229db49695135f627075ea6a1d41873a3e33f4e999e3bfb4a6f2e"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-amd64.tar.gz"
      sha256 "1cfb29d47a0292bd241b94aed2177169ce0aea5562be3cf9ff64f49b599073f3"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-arm64.tar.gz"
      sha256 "1e3d66b607ecb86fcbf0cc3de7e5012db069d18b5631a352d0f99240a9addf43"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-amd64.tar.gz"
      sha256 "c51f029378a3d239e9c6be33f81970add2e93fcc1e2ecca4933b7be0c4cba392"
    end
  end

  def install
    bin.install "veri"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/veri version")
  end
end
