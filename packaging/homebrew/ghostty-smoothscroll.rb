# The published copy lives in https://github.com/tmphnt/homebrew-tap (Formula/).
# To release a new version: tag it here (vX.Y.Z), then update url and sha256
# there (sha256: `curl -L <tarball url> | shasum -a 256`).
class GhosttySmoothscroll < Formula
  desc "Smooth, Vimium-style keyboard scrolling for Ghostty on macOS"
  homepage "https://github.com/tmphnt/ghostty-smoothscroll"
  url "https://github.com/tmphnt/ghostty-smoothscroll/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "FILL_IN"
  license "MIT"

  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/ghostty-smoothscroll"
  end

  def caveats
    <<~EOS
      To finish setting up, run:
        ghostty-smoothscroll setup
      then reload Ghostty's config (⌘⇧,) and allow Accessibility when macOS asks.

      After `brew upgrade`, macOS may ask for Accessibility permission again.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ghostty-smoothscroll version")
  end
end
