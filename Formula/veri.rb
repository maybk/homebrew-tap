class Veri < Formula
  desc "Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill)"
  homepage "https://github.com/maybk/veri"
  version "0.2.6"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-arm64.tar.gz"
      sha256 "96fb56d5c4502002629e95403b55fe6d07df4eb237a2351b10a3a58bf93861fa"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-amd64.tar.gz"
      sha256 "df0628fdad3060920bee174abbdcfc32aa17d73bf56ab1741a86c838d104c951"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-arm64.tar.gz"
      sha256 "49c4c85c1d6af97e0c82cde4db794d78a6f6bd54ce1637aab833a0adbcb4d59a"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-amd64.tar.gz"
      sha256 "7539f938bcbb0fe58b810ed0634fac1eb9ec16d74216da37a3314b54564db47a"
    end
  end

  def install
    bin.install "veri"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/veri version")
  end
end
