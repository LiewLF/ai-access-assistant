// SPDX-License-Identifier: AGPL-3.0-only

use crate::{sqlite, CoreError, Result};
use aes_gcm::aead::rand_core::RngCore;
use aes_gcm::aead::{Aead, OsRng, Payload};
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::Path;
use uuid::Uuid;
use zeroize::Zeroize;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

const JOURNAL_AAD: &[u8] = b"AIH SessionCore Journal v1";
const BACKUP_MAGIC: &[u8; 8] = b"AIHSCDB1";
const BACKUP_CHUNK_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EncryptedPayload {
    pub algorithm: String,
    pub nonce: String,
    pub ciphertext: String,
}

pub(crate) fn encrypt_json<T: Serialize>(key: &[u8; 32], value: &T) -> Result<EncryptedPayload> {
    let cipher = cipher(key)?;
    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let mut plaintext = serde_json::to_vec(value).map_err(|error| {
        CoreError::new(
            "journal_encryption_failed",
            format!("Cannot serialize sensitive recovery payload: {error}"),
        )
    })?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            Payload {
                msg: &plaintext,
                aad: JOURNAL_AAD,
            },
        )
        .map_err(|_| {
            CoreError::new(
                "journal_encryption_failed",
                "Cannot encrypt sensitive recovery payload",
            )
        });
    plaintext.zeroize();
    let ciphertext = encrypted?;
    Ok(EncryptedPayload {
        algorithm: "AES-256-GCM".to_string(),
        nonce: STANDARD.encode(nonce_bytes),
        ciphertext: STANDARD.encode(ciphertext),
    })
}

pub(crate) fn decrypt_json<T: DeserializeOwned>(
    key: &[u8; 32],
    encrypted: &EncryptedPayload,
) -> Result<T> {
    if encrypted.algorithm != "AES-256-GCM" {
        return Err(CoreError::new(
            "unsupported_journal_encryption",
            format!(
                "Unsupported recovery payload algorithm: {}",
                encrypted.algorithm
            ),
        ));
    }
    let nonce = STANDARD.decode(&encrypted.nonce).map_err(|_| {
        CoreError::new(
            "invalid_journal",
            "Recovery journal contains invalid nonce encoding",
        )
    })?;
    if nonce.len() != 12 {
        return Err(CoreError::new(
            "invalid_journal",
            "Recovery journal nonce must be 12 bytes",
        ));
    }
    let ciphertext = STANDARD.decode(&encrypted.ciphertext).map_err(|_| {
        CoreError::new(
            "invalid_journal",
            "Recovery journal contains invalid ciphertext encoding",
        )
    })?;
    let cipher = cipher(key)?;
    let mut plaintext = cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: JOURNAL_AAD,
            },
        )
        .map_err(|_| {
            CoreError::new(
                "journal_decryption_failed",
                "Recovery journal key is wrong or encrypted payload is damaged",
            )
        })?;
    let value = serde_json::from_slice(&plaintext).map_err(|_| {
        CoreError::new(
            "journal_decryption_failed",
            "Decrypted recovery payload is invalid",
        )
    });
    plaintext.zeroize();
    value
}

pub(crate) fn encrypt_backup_file(
    key: &[u8; 32],
    plaintext_path: &Path,
    encrypted_path: &Path,
) -> Result<()> {
    if encrypted_path.exists() {
        return Err(CoreError::new(
            "backup_conflict",
            format!(
                "Encrypted SQLite backup already exists: {}",
                encrypted_path.display()
            ),
        ));
    }
    let parent = encrypted_path.parent().ok_or_else(|| {
        CoreError::new(
            "backup_encryption_failed",
            "Encrypted SQLite backup has no parent directory",
        )
    })?;
    let temporary_path = parent.join(format!(".database-{}.aesgcm.tmp", Uuid::new_v4()));
    let source = File::open(plaintext_path).map_err(|error| {
        CoreError::new(
            "backup_encryption_failed",
            format!("Cannot open SQLite backup for encryption: {error}"),
        )
    })?;
    let destination = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary_path)
        .map_err(|error| {
            CoreError::new(
                "backup_encryption_failed",
                format!("Cannot create encrypted SQLite backup: {error}"),
            )
        })?;
    set_private_file_permissions(&temporary_path)?;
    let cipher = cipher(key)?;
    let mut reader = BufReader::new(source);
    let mut writer = BufWriter::new(destination);
    let mut buffer = vec![0u8; BACKUP_CHUNK_BYTES];
    let mut counter = 0u32;

    let encryption_result = (|| -> Result<()> {
        writer.write_all(BACKUP_MAGIC).map_err(backup_write_error)?;
        loop {
            let read = reader.read(&mut buffer).map_err(|error| {
                CoreError::new(
                    "backup_encryption_failed",
                    format!("Cannot read SQLite backup: {error}"),
                )
            })?;
            if read == 0 {
                break;
            }
            let mut nonce_bytes = [0u8; 12];
            OsRng.fill_bytes(&mut nonce_bytes);
            let aad = backup_chunk_aad(counter, read as u32);
            let ciphertext = cipher
                .encrypt(
                    Nonce::from_slice(&nonce_bytes),
                    Payload {
                        msg: &buffer[..read],
                        aad: &aad,
                    },
                )
                .map_err(|_| {
                    CoreError::new(
                        "backup_encryption_failed",
                        "Cannot encrypt SQLite backup chunk",
                    )
                })?;
            writer
                .write_all(&(read as u32).to_be_bytes())
                .and_then(|_| writer.write_all(&nonce_bytes))
                .and_then(|_| writer.write_all(&(ciphertext.len() as u32).to_be_bytes()))
                .and_then(|_| writer.write_all(&ciphertext))
                .map_err(backup_write_error)?;
            buffer[..read].zeroize();
            counter = counter.checked_add(1).ok_or_else(|| {
                CoreError::new(
                    "backup_encryption_failed",
                    "SQLite backup has too many chunks",
                )
            })?;
        }
        writer
            .write_all(&0u32.to_be_bytes())
            .and_then(|_| writer.flush())
            .and_then(|_| writer.get_ref().sync_all())
            .map_err(backup_write_error)?;
        Ok(())
    })();
    buffer.zeroize();
    if let Err(error) = encryption_result {
        drop(writer);
        let _ = fs::remove_file(&temporary_path);
        return Err(error);
    }
    drop(writer);
    fs::rename(&temporary_path, encrypted_path).map_err(|error| {
        let _ = fs::remove_file(&temporary_path);
        CoreError::new(
            "backup_encryption_failed",
            format!("Cannot commit encrypted SQLite backup: {error}"),
        )
    })?;
    set_private_file_permissions(encrypted_path)?;
    verify_backup_file(key, encrypted_path)?;
    drop(reader);
    sqlite::remove_temporary_backup_artifacts(plaintext_path)
}

fn verify_backup_file(key: &[u8; 32], path: &Path) -> Result<()> {
    let cipher = cipher(key)?;
    let mut reader = BufReader::new(File::open(path).map_err(|error| {
        CoreError::new(
            "backup_verification_failed",
            format!("Cannot open encrypted SQLite backup: {error}"),
        )
    })?);
    let mut magic = [0u8; 8];
    reader.read_exact(&mut magic).map_err(backup_read_error)?;
    if &magic != BACKUP_MAGIC {
        return Err(CoreError::new(
            "backup_verification_failed",
            "Encrypted SQLite backup has invalid header",
        ));
    }
    let mut counter = 0u32;
    loop {
        let plaintext_len = read_u32(&mut reader)?;
        if plaintext_len == 0 {
            break;
        }
        if plaintext_len as usize > BACKUP_CHUNK_BYTES {
            return Err(CoreError::new(
                "backup_verification_failed",
                "Encrypted SQLite backup chunk is too large",
            ));
        }
        let mut nonce = [0u8; 12];
        reader.read_exact(&mut nonce).map_err(backup_read_error)?;
        let ciphertext_len = read_u32(&mut reader)?;
        if ciphertext_len != plaintext_len + 16 {
            return Err(CoreError::new(
                "backup_verification_failed",
                "Encrypted SQLite backup chunk length is invalid",
            ));
        }
        let mut ciphertext = vec![0u8; ciphertext_len as usize];
        reader
            .read_exact(&mut ciphertext)
            .map_err(backup_read_error)?;
        let aad = backup_chunk_aad(counter, plaintext_len);
        let mut plaintext = cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| {
                CoreError::new(
                    "backup_verification_failed",
                    "Encrypted SQLite backup authentication failed",
                )
            })?;
        if plaintext.len() != plaintext_len as usize {
            plaintext.zeroize();
            return Err(CoreError::new(
                "backup_verification_failed",
                "Encrypted SQLite backup plaintext length is invalid",
            ));
        }
        plaintext.zeroize();
        ciphertext.zeroize();
        counter = counter.checked_add(1).ok_or_else(|| {
            CoreError::new(
                "backup_verification_failed",
                "Encrypted SQLite backup has too many chunks",
            )
        })?;
    }
    let mut trailing = [0u8; 1];
    if reader.read(&mut trailing).map_err(backup_read_error)? != 0 {
        return Err(CoreError::new(
            "backup_verification_failed",
            "Encrypted SQLite backup has trailing data",
        ));
    }
    Ok(())
}

fn cipher(key: &[u8; 32]) -> Result<Aes256Gcm> {
    Aes256Gcm::new_from_slice(key).map_err(|_| {
        CoreError::new(
            "invalid_journal_key",
            "Journal encryption key must be exactly 32 bytes",
        )
    })
}

fn backup_chunk_aad(counter: u32, plaintext_len: u32) -> Vec<u8> {
    let mut aad = b"AIH SessionCore DB Backup v1".to_vec();
    aad.extend_from_slice(&counter.to_be_bytes());
    aad.extend_from_slice(&plaintext_len.to_be_bytes());
    aad
}

fn read_u32(reader: &mut impl Read) -> Result<u32> {
    let mut bytes = [0u8; 4];
    reader.read_exact(&mut bytes).map_err(backup_read_error)?;
    Ok(u32::from_be_bytes(bytes))
}

fn backup_read_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        "backup_verification_failed",
        format!("Cannot read encrypted SQLite backup: {error}"),
    )
}

fn backup_write_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        "backup_encryption_failed",
        format!("Cannot write encrypted SQLite backup: {error}"),
    )
}

fn set_private_file_permissions(path: &Path) -> Result<()> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| {
        CoreError::new(
            "permission_failed",
            format!("Cannot secure {}: {error}", path.display()),
        )
    })?;
    Ok(())
}
