class Veri < Formula
  desc "Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill)"
  homepage "https://github.com/maybk/veri"
  version "0.2.2"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-arm64.tar.gz"
      sha256 "f952003a82dbe94dc6111067409bc5765cae9324f7d90246aab88e7aec790794"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-amd64.tar.gz"
      sha256 "9dc1277f7f1fda5eefb743dc3a55072d170c0df3d2ad551c88951384a38de281"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-arm64.tar.gz"
      sha256 "ff9f025e4107da83fbdf5789b68712253d6709f3244fb1ee49849f8caf3e4e7c"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-amd64.tar.gz"
      sha256 "2a9c6a87ccfab93733cf39f1a5ed2247eb653f25677cd580389e1df7d908de1b"
    end
  end

  def install
    bin.install "veri"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/veri version")
  end
end
