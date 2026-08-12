//! GnuPG keybox loading and certificate lookup.

use anyhow::{Context, Result, bail};
use sequoia_openpgp::cert::prelude::*;
use sequoia_openpgp::parse::Parse;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;

fn gnupg_home() -> Result<PathBuf> {
  if let Ok(dir) = std::env::var("GNUPGHOME") {
    return Ok(PathBuf::from(dir));
  }
  let home = std::env::var("HOME").context("HOME is not set (cannot locate ~/.gnupg)")?;
  Ok(PathBuf::from(home).join(".gnupg"))
}

fn keybox_path() -> Result<PathBuf> {
  Ok(gnupg_home()?.join("pubring.kbx"))
}

/// Load all OpenPGP certificates from the GnuPG keybox.
#[tracing::instrument]
pub fn load_keybox_certs() -> Result<Vec<Cert>> {
  use sequoia_gpg_agent::sequoia_ipc::keybox::{Keybox, KeyboxRecord};

  let primary = keybox_path()?;
  let fallback = primary.with_file_name({
    let mut name = primary
      .file_name()
      .unwrap_or_else(|| OsStr::new("pubring.kbx"))
      .to_os_string();
    name.push("~");
    name
  });

  let candidates = [primary, fallback];
  let mut last_error: Option<anyhow::Error> = None;
  for path in candidates {
    if !path.exists() {
      continue;
    }

    let kbx = match Keybox::from_file(&path) {
      Ok(kbx) => kbx,
      Err(e) => {
        last_error = Some(anyhow::anyhow!(
          "Failed to read GnuPG keybox at {}: {}",
          path.display(),
          e
        ));
        continue;
      }
    };

    let certs = match kbx
      .filter_map(|r| match r {
        Ok(record) => Some(record),
        Err(e) => {
          tracing::warn!("Skipping malformed keybox record: {}", e);
          None
        }
      })
      .filter_map(|r| match r {
        KeyboxRecord::OpenPGP(o) => Some(o.cert()),
        _ => None,
      })
      .collect::<sequoia_openpgp::Result<Vec<Cert>>>()
    {
      Ok(certs) => certs,
      Err(e) => {
        last_error = Some(anyhow::anyhow!(
          "Failed to read certificates from keybox at {}: {}",
          path.display(),
          e
        ));
        continue;
      }
    };

    if !certs.is_empty() {
      tracing::debug!(count = certs.len(), "Loaded certificates from keybox");
      return Ok(certs);
    }
  }

  if let Some(e) = last_error {
    return Err(e);
  }
  bail!("No OpenPGP certificates found in your keybox. Provide a certificate file path instead.")
}

fn normalize_hexish(s: &str) -> String {
  s.trim()
    .trim_start_matches("0x")
    .trim_start_matches("0X")
    .chars()
    .filter(|c| c.is_ascii_hexdigit())
    .flat_map(|c| c.to_uppercase())
    .collect()
}

/// Find certificates in the given cert list matching the key spec.
#[tracing::instrument(skip(certs), fields(certs_count = certs.len()))]
pub fn find_certs_in_keybox(certs: &[Cert], key_spec: &str) -> Vec<Cert> {
  let needle_hex = normalize_hexish(key_spec);
  let needle_lc = key_spec.trim().to_lowercase();

  certs
    .iter()
    .filter_map(|cert| {
      let matches_fpr =
        !needle_hex.is_empty() && normalize_hexish(&cert.fingerprint().to_string()) == needle_hex;

      let matches_kid = !needle_hex.is_empty()
        && cert
          .keys()
          .any(|k| normalize_hexish(&k.key().keyid().to_string()) == needle_hex);

      let matches_uid = !needle_lc.is_empty()
        && cert.userids().any(|uid| {
          String::from_utf8_lossy(uid.userid().value())
            .to_lowercase()
            .contains(&needle_lc)
        });

      if matches_fpr || matches_kid || matches_uid {
        Some(cert.clone())
      } else {
        None
      }
    })
    .collect()
}

/// Load an OpenPGP certificate from a file path, or look it up in the GnuPG keybox.
///
/// Returns the cert and a boolean indicating if it came from a file (true) or keybox (false).
#[tracing::instrument]
pub fn load_cert(spec: &str) -> Result<Cert> {
  let path = Path::new(spec);
  if path.exists() {
    tracing::debug!("Loading certificate from file");
    let bytes = std::fs::read(path)
      .with_context(|| format!("Failed to read certificate file: {}", path.display()))?;
    return Cert::from_bytes(&bytes)
      .with_context(|| format!("Failed to parse certificate from file: {}", path.display()));
  }

  tracing::debug!("Searching GnuPG keybox");
  let certs = load_keybox_certs()?;
  let matches = find_certs_in_keybox(&certs, spec);

  if matches.is_empty() {
    tracing::debug!(
      spec = spec,
      "No matching cert in keybox, trying `gpg --export` fallback"
    );

    match Command::new("gpg").args(&["--export", "-a", spec]).output() {
      Ok(out) if out.status.success() && !out.stdout.is_empty() => {
        tracing::debug!(size = out.stdout.len(), "gpg export returned data");
        return Cert::from_bytes(&out.stdout)
          .with_context(|| format!("Failed to parse certificate exported by gpg for '{}'", spec));
      }
      Ok(out) if !out.status.success() => {
        tracing::debug!(
          status = ?out.status.code(),
          stderr = %String::from_utf8_lossy(&out.stderr),
          "`gpg --export` failed"
        );
      }
      Ok(_) => {
        tracing::debug!(
          spec = spec,
          "`gpg --export` had no output we fall through to the original error."
        );
      }
      Err(e) => {
        tracing::debug!(error = %e, "Failed to run `gpg --export` fallback");
      }
    }

    bail!(
      "No matching certificate found for '{}'. Provide a .asc file path or import the key into your keybox.",
      spec
    );
  }

  if matches.len() > 1 {
    tracing::warn!(
      count = matches.len(),
      "Multiple keys found for spec, using first"
    );
  }

  Ok(matches.into_iter().next().unwrap())
}
