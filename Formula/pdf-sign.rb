class PdfSign < Formula
  desc "Secure PDF signing with OpenPGP and Sigstore"
  homepage "https://github.com/0x77dev/pdf-sign"
  url "https://github.com/0x77dev/pdf-sign/releases/download/v0.2.0/pdf-sign-macos-arm64"
  sha256 "sha256-hash-placeholder" # To be updated on release
  license "GPL-3.0-only"

  def install
    bin.install "pdf-sign"
  end

  test do
    test.shell_script { "pdf-sign --help" }
  end
end
