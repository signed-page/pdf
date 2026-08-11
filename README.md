# pdf-sign

[![CI](https://github.com/signed-page/pdf/actions/workflows/ci.yml/badge.svg)](https://github.com/signed-page/pdf/actions/workflows/ci.yml)

PDF signing utility written in Rust that supports both **OpenPGP (GPG)** and **Sigstore (keyless OIDC)** signatures, appending cryptographic signatures directly to PDFs, making it easy to sign and verify documents without heavyweight PDF signing stacks, making your PDFs authentic, tamper-proof, while being fully compatible with regular readers.

[![Watch the demo on X](https://pbs.twimg.com/amplify_video_thumb/2000478980236013569/img/FpmQTXfyxCD5yxaW.jpg)](https://twitter.com/0x77dev/status/2000481268258205919)

[![asciicast](https://asciinema.org/a/JXR1crpqtcbMT1DIhD3dzXFB9.svg)](https://asciinema.org/a/JXR1crpqtcbMT1DIhD3dzXFB9)

## Why pdf-sign?

With `pdf-sign`, anyone can sign a PDF using their existing Google, Microsoft, or GitHub account – no cryptographic keys to generate, store, or manage. For power users and security-conscious workflows, it also supports GPG with full hardware key (YubiKey/smartcard) integration. Whether you're a huge company automating signatures, or just need to sign a contract, `pdf-sign` gets out of your way.

Many "enterprise PDF signing" solutions require a full **CMS/PKCS#7** / **X.509 PKI** toolchain (certificate chains, policy constraints, CRL/OCSP revocation, time-stamping/TSAs) plus PDF-form machinery to produce **PAdES** signatures. Those stacks are powerful, but complex to configure, audit, and automate.

`pdf-sign` intentionally stays minimal and scriptable:

* **Two signing backends**: Choose between traditional GPG (with hardware key support) or modern Sigstore (keyless OIDC).
* **Preserves PDF integrity**: Original PDF content unchanged; signatures appended after `%%EOF`.
* **Multi-signer workflow**: Supports multiple signatures (GPG + Sigstore) on the same document, and/or multi-party signing.
* **Privacy-preserving**: No extra PII embedded; library never logs sensitive data.

## Quickstart

### Install with Homebrew

```bash
brew install signed-page/tap/pdf
pdf-sign --help
```

### Install with Nix

```bash
nix profile install github:signed-page/pdf#pdf-sign
pdf-sign --help
```

### Install with Cargo

```bash
cargo install --git https://github.com/signed-page/pdf --locked

# GPG signing (default backend)
pdf-sign sign document.pdf --key 0xDEADBEEF

# Sigstore keyless signing
pdf-sign sign --backend sigstore document.pdf

# Verify (automatically handles both GPG and Sigstore)
pdf-sign verify document_signed.pdf
```

### Build from Source

```bash
# Clone and build
git clone https://github.com/signed-page/pdf
cd pdf
cargo build --release
./target/release/pdf-sign --help

# Or with Nix flake
nix build
./result/bin/pdf-sign --help
```

### Docker

Multi-platform images (`linux/amd64`, `linux/arm64`, `darwin/arm64`) are published to GHCR with [build provenance attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations).

```bash
docker pull ghcr.io/signed-page/pdf

# Verify attestation
gh attestation verify oci://ghcr.io/signed-page/pdf:latest --repo signed-page/pdf
```

**GPG signing** — mount your host GPG agent socket and keyring (Linux only — [macOS Docker Desktop cannot forward Unix sockets](https://github.com/docker/for-mac/issues/483)):

```bash
docker run --rm \
  -v "$(gpgconf --list-dirs agent-socket)":/gnupg/S.gpg-agent \
  -v ~/.gnupg/pubring.kbx:/gnupg/pubring.kbx:ro \
  -v "$PWD":/data \
  ghcr.io/signed-page/pdf sign --key 0xDEADBEEF document.pdf
```

**Sigstore signing (interactive)** — forward the OIDC callback port:

```bash
docker run --rm \
  -p 127.0.0.1:8080:8080 -e OIDC_REDIRECT_PORT=8080 \
  -v "$PWD":/data \
  ghcr.io/signed-page/pdf sign --backend sigstore document.pdf
```

**Sigstore signing (CI/non-interactive)** — pass a pre-obtained identity token:

```bash
docker run --rm \
  -e SIGSTORE_IDENTITY_TOKEN="$OIDC_TOKEN" \
  -v "$PWD":/data \
  ghcr.io/signed-page/pdf sign --backend sigstore document.pdf
```

**Verify signatures:**

```bash
docker run --rm -v "$PWD":/data \
  ghcr.io/signed-page/pdf verify document_signed.pdf \
  --certificate-identity user@example.com \
  --certificate-oidc-issuer https://accounts.google.com
```

## Commands

### `sign` - Sign a PDF

Unified signing command with backend selection.

**GPG backend (default):**

```bash
pdf-sign sign contract.pdf --key 0xF1171FAAAA237211
# or explicitly:
pdf-sign sign --backend gpg contract.pdf --key user@example.com
```

**Sigstore backend:**

```bash
pdf-sign sign --backend sigstore document.pdf
```

**Common options:**

* `--output, -o`: Output path (default: `<input>_signed.pdf`)
* `--backend, -b`: Backend to use (`gpg` or `sigstore`, default: `gpg`)
* `--json`: Machine-readable JSON output

**GPG-specific options:**

* `--key, -k`: Key spec (file, fingerprint, key ID, or email) - **required for GPG**
* `--embed-uid`: Embed signer UID as notation

**Sigstore-specific options:**

* `--oidc-issuer <URL>`: OIDC provider (default: `https://oauth2.sigstore.dev/auth`)
* `--fulcio-url <URL>`: Fulcio CA (default: `https://fulcio.sigstore.dev`)
* `--rekor-url <URL>`: Rekor log (default: `https://rekor.sigstore.dev`)
* `--oidc-client-id <ID>`: Client ID (default: `sigstore`)
* `--oidc-client-secret <SECRET>`: Client secret
* `--identity-token <JWT>`: Non-interactive (CI mode)
* `--digest-algorithm <ALG>`: Hash (default: `sha512`)

### `verify` - Verify signatures

Automatically detects and verifies **both GPG and Sigstore** signatures in a single pass.

```bash
# Verify GPG signatures (uses keybox by default)
pdf-sign verify contract_signed.pdf

# Verify GPG with specific cert
pdf-sign verify contract_signed.pdf --cert signer.asc

# Verify Sigstore signatures (requires identity policy)
pdf-sign verify document_signed.pdf \
  --certificate-identity user@example.com \
  --certificate-oidc-issuer https://accounts.google.com

# Verify both GPG and Sigstore in one PDF
pdf-sign verify multi_signed.pdf \
  --cert alice.asc \
  --certificate-identity bob@example.com \
  --certificate-oidc-issuer https://accounts.google.com
```

**GPG verification options:**

* `--cert, -c`: Optional cert spec (can repeat)

**Sigstore verification options:**

* `--certificate-identity <EMAIL|URI>`: Expected signer identity (required if Sigstore sigs present)
* `--certificate-identity-regexp <REGEX>`: Identity regex
* `--certificate-oidc-issuer <URL>`: Expected issuer (required if Sigstore sigs present)
* `--certificate-oidc-issuer-regexp <REGEX>`: Issuer regex
* `--offline`: Skip Rekor verification

**Common options:**

* `--json`: Machine-readable JSON output

### `challenge` - Prepare signing challenge for remote/air-gapped GPG signing

Create a challenge file for signing on a remote or air-gapped machine.

```bash
pdf-sign challenge document.pdf --key 0xDEADBEEF --output challenge.json
```

**Options:**

* `--key, -k`: Key specification (required)
* `--output, -o`: Output path for challenge JSON (default: stdout)
* `--embed-uid`: Embed signer UID into signature
* `--json`: Machine-readable JSON output

**Challenge format:**

```json
{
  "version": 1,
  "fingerprint": "ABCD1234...",
  "data_base64": "SGVsbG8...",
  "gpg_command": "echo 'SGVsbG8...' | base64 -d | gpg --detach-sign --armor -u 0xDEADBEEF > signature.asc",
  "created_at": "2025-12-13T10:00:00Z",
  "embed_uid": false
}
```

### `apply-response` - Apply signature response from challenge-response workflow

Apply a signature created on a remote machine to complete the signing process.

```bash
pdf-sign apply-response document.pdf \
  --challenge challenge.json \
  --signature signature.asc \
  --output signed.pdf
```

**Options:**

* `--challenge, -c`: Path to challenge JSON file (required)
* `--signature, -s`: Path to signature file (.asc) (required)
* `--output, -o`: Output path for signed PDF (default: `<input>_signed.pdf`)
* `--json`: Machine-readable JSON output

## Features

### OpenPGP Backend

* **GPG agent integration**: All private key operations delegated to `gpg-agent`.
* **Hardware key support**: Smartcards and YubiKeys work seamlessly.
* **Keybox lookups**: Reads your `~/.gnupg/pubring.kbx` for verification.
* **Privacy by default**: Signer UIDs only embedded if explicitly requested.

### Sigstore Backend

* **Keyless signing**: No long-lived keys—authenticate with your existing OIDC account.
* **Transparency logging**: All signatures publicly logged to Rekor.
* **Short-lived certificates**: Fulcio issues ephemeral certs tied to your verified identity.
* **Strict verification**: Requires explicit identity and issuer constraints (prevents identity confusion).
* **Customizable endpoints**: Use public Sigstore or private deployments.

### Challenge-Response Workflow

* **Air-gapped signing**: Keep private keys isolated on secure machines
* **Remote signing**: Sign on different servers without copying keys
* **HSM support**: Sign with hardware security modules
* **Audit trail**: Clear separation between digest preparation and signing
* **Standard format**: Uses standard OpenPGP detached signatures

### Architecture

* **Portable core**: PDF splitting, suffix parsing, digest abstraction (no CLI/UI deps).
* **Pluggable backends**: Clean separation between GPG and Sigstore signing logic.
* **Hash agility**: SHA-512 default with SRI-style encoding (`sha512-<base64>`).
* **Versioned format**: Sigstore blocks use bilrost (efficient binary) with version tagging.
* **Structured tracing**: Full `tracing` instrumentation (never logs sensitive data).
* **Multi-signer**: Multiple signatures (GPG + Sigstore) can coexist on one PDF.

## Security Model

### OpenPGP

* **No private keys in tool**: All signing via `gpg-agent`.
* **Reduced exposure**: Private keys stay in agent or on hardware.
* **Explicit verification**: Uses keybox by default or provided certs.

### Sigstore

* **Identity-based**: Signatures tied to verified OIDC identity (email/URI).
* **Transparency**: Rekor ensures signatures are publicly auditable.
* **Strict by default**: Verification fails unless expected identity/issuer provided.
* **Privacy-aware**: Library code never logs tokens or identity material.

## Embedded Signature Formats

### OpenPGP Format

Standard ASCII-armored blocks appended after `%%EOF`:

```text
%%EOF
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----
```

### Sigstore Format

Versioned bilrost-encoded blocks with digest binding:

```text
%%EOF
-----BEGIN PDF-SIGN SIGSTORE-----
<base64-encoded bilrost payload>
-----END PDF-SIGN SIGSTORE-----
```

**Bilrost payload** (v1):

* `version`: Format version (1)
* `signed_range_len`: Length of clean PDF bytes
* `digest_alg`: Hash algorithm (1 = SHA-512)
* `digest`: Raw digest bytes (for integrity binding)
* `bundle_json`: Sigstore bundle (signature + cert + Rekor proof)

## Requirements

### For OpenPGP Signing

* Rust toolchain (`cargo`)
* Running `gpg-agent`
* Public cert importable or in keyring
* Private key in `gpg-agent` (software or hardware)

### For Sigstore Signing

* Rust toolchain (`cargo`)
* Web browser (for OIDC auth) or `--identity-token` for CI
* Network access (Fulcio, Rekor, OIDC provider)
* No keys/certs required

## Environment Variables

### General

* `GNUPGHOME`: GPG keybox location (default: `~/.gnupg`)
* `RUST_LOG`: Tracing verbosity (e.g., `RUST_LOG=debug`)

### Sigstore-Specific

* `SIGSTORE_IDENTITY_TOKEN`: Pre-obtained OIDC identity token (JWT) for CI workflows (bypasses interactive browser flow)
* `OIDC_REDIRECT_PORT`: Local port for OIDC callback listener (default: OS-assigned dynamic port). Set to a fixed port (e.g., `8080`) if you need predictable port forwarding or firewall rules

### Output Channels

* `stderr`: Progress, status, errors
* `stdout`: Result paths (sign) or "OK" (verify) for pipelines

## Examples

### GPG signing with YubiKey

```bash
# Sign with hardware key (default backend)
pdf-sign sign contract.pdf --key user@example.com

# Verify
pdf-sign verify contract_signed.pdf
```

### Sigstore keyless signing

```bash
# Interactive signing (opens browser for OIDC)
pdf-sign sign --backend sigstore document.pdf

# Verify with strict identity policy
pdf-sign verify document_signed.pdf \
  --certificate-identity user@example.com \
  --certificate-oidc-issuer https://accounts.google.com
```

### CI/CD with Sigstore

```bash
# Non-interactive signing with pre-obtained token
pdf-sign sign --backend sigstore release.pdf --identity-token "$OIDC_TOKEN"

# Verify in CI
pdf-sign verify release_signed.pdf \
  --certificate-identity https://github.com/org/repo/.github/workflows/release.yml@refs/tags/v1.0.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --json
```

### Multi-signer workflow

```bash
# Alice signs with GPG
pdf-sign sign contract.pdf --key alice@example.com

# Bob adds Sigstore signature to the same PDF
pdf-sign sign --backend sigstore contract_signed.pdf --output contract_multi.pdf

# Verify both signatures in one command
pdf-sign verify contract_multi.pdf \
  --cert alice.asc \
  --certificate-identity bob@example.com \
  --certificate-oidc-issuer https://accounts.google.com
```

### Challenge-response for air-gapped signing

```bash
# 1. On connected machine: Prepare challenge
pdf-sign challenge sensitive.pdf --key 0xABCD1234 --output challenge.json

# 2. Transfer challenge.json to air-gapped machine
# 3. On air-gapped machine: Sign the challenge
cat challenge.json | jq -r '.data_base64' | base64 -d | \
  gpg --detach-sign --armor -u 0xABCD1234 > signature.asc

# 4. Transfer signature.asc back to connected machine
# 5. On connected machine: Apply signature
pdf-sign apply-response sensitive.pdf \
  --challenge challenge.json \
  --signature signature.asc \
  --output sensitive_signed.pdf

# 6. Verify the result
pdf-sign verify sensitive_signed.pdf
```

## License

GPL-3.0-only – See [`LICENSE`](./LICENSE).
