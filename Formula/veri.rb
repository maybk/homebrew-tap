class Veri < Formula
  desc "Multi-provider web search and Markdown extraction (CLI, MCP, Agent Skill)"
  homepage "https://github.com/maybk/veri"
  version "0.2.8"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-arm64.tar.gz"
      sha256 "9238d5e8aa051ad00185c689a19553d72a8d4deec3133c0a76eab19fe9bf72b3"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-darwin-amd64.tar.gz"
      sha256 "cbeb27591cb87010ffb2554fc09d16ac9068c02b4bff91d267e178e9cda57524"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-arm64.tar.gz"
      sha256 "ae5e60ad3884129f956cf129d4b91491dbeebb3b7c17956dea2316e3d9ba59cf"
    end

    on_intel do
      url "https://github.com/maybk/veri/releases/download/v#{version}/veri-#{version}-linux-amd64.tar.gz"
      sha256 "c7d4257502222ac0dde3f8a80d85f6707bb163539bc32d28032934ee221ba488"
    end
  end

  def install
    bin.install "veri"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/veri version")
  end
end
