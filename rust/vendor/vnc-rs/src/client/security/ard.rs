use aes::cipher::{Array, BlockCipherEncrypt, KeyInit};
use aes::Aes128;
use num_bigint::BigUint;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use zeroize::Zeroize;

use crate::client::auth::AuthResult;
use crate::VncError;

const MIN_DH_KEY_LEN: usize = 16;
const MAX_DH_KEY_LEN: usize = 1024;
const MAX_ARD_FIELD_LEN: usize = 63;
const ARD_CREDENTIAL_BLOCK_LEN: usize = 128;

fn to_fixed_be(value: &BigUint, len: usize) -> Result<Vec<u8>, VncError> {
    let bytes = value.to_bytes_be();
    if bytes.len() > len {
        return Err(VncError::ConnectError);
    }
    let mut out = vec![0u8; len];
    out[len - bytes.len()..].copy_from_slice(&bytes);
    Ok(out)
}

fn fill_random(buf: &mut [u8]) -> Result<(), VncError> {
    getrandom::fill(buf).map_err(|_| VncError::ConnectError)
}

fn encrypt_credentials_with_dh(
    generator: u16,
    prime_bytes: &[u8],
    server_pub_bytes: &[u8],
    priv_key: &BigUint,
    username: &str,
    password: &str,
    mut block: [u8; ARD_CREDENTIAL_BLOCK_LEN],
) -> Result<(Vec<u8>, [u8; ARD_CREDENTIAL_BLOCK_LEN]), VncError> {
    let key_len = prime_bytes.len();
    let g = BigUint::from(generator);
    let prime = BigUint::from_bytes_be(prime_bytes);
    let server_pub = BigUint::from_bytes_be(server_pub_bytes);

    let client_pub = g.modpow(priv_key, &prime);
    let shared_secret = server_pub.modpow(priv_key, &prime);
    let client_pub_bytes = to_fixed_be(&client_pub, key_len)?;
    let mut shared_bytes = to_fixed_be(&shared_secret, key_len)?;

    let mut aes_key = md5::compute(&shared_bytes).0;
    shared_bytes.zeroize();

    let u_bytes = username.as_bytes();
    let p_bytes = password.as_bytes();
    block[..u_bytes.len()].copy_from_slice(u_bytes);
    block[u_bytes.len()] = 0;
    block[64..64 + p_bytes.len()].copy_from_slice(p_bytes);
    block[64 + p_bytes.len()] = 0;

    let cipher = Aes128::new(&Array::from(aes_key));
    aes_key.zeroize();
    for chunk in block.chunks_exact_mut(16) {
        let mut aes_block = Array::from(<[u8; 16]>::try_from(&chunk[..]).unwrap());
        cipher.encrypt_block(&mut aes_block);
        chunk.copy_from_slice(&aes_block);
    }

    Ok((client_pub_bytes, block))
}

fn compute_dh_and_encrypt(
    generator: u16,
    prime_bytes: &[u8],
    server_pub_bytes: &[u8],
    username: &str,
    password: &str,
) -> Result<(Vec<u8>, [u8; ARD_CREDENTIAL_BLOCK_LEN]), VncError> {
    let key_len = prime_bytes.len();
    if generator < 2
        || !(MIN_DH_KEY_LEN..=MAX_DH_KEY_LEN).contains(&key_len)
        || server_pub_bytes.len() != key_len
    {
        return Err(VncError::ConnectError);
    }

    let prime = BigUint::from_bytes_be(prime_bytes);
    let server_pub = BigUint::from_bytes_be(server_pub_bytes);
    let two = BigUint::from(2u8);
    if prime <= two || server_pub <= BigUint::from(1u8) || server_pub >= prime {
        return Err(VncError::ConnectError);
    }

    let range = &prime - &two;
    let exp_len = key_len.min(64);
    let mut priv_seed = vec![0u8; exp_len];
    fill_random(&mut priv_seed)?;
    let priv_key = (BigUint::from_bytes_be(&priv_seed) % range) + &two;
    priv_seed.zeroize();

    let mut block = [0u8; ARD_CREDENTIAL_BLOCK_LEN];
    fill_random(&mut block)?;
    encrypt_credentials_with_dh(
        generator,
        prime_bytes,
        server_pub_bytes,
        &priv_key,
        username,
        password,
        block,
    )
}

/// Performs Apple Remote Desktop (Security Type 30) Diffie-Hellman + AES-128-ECB authentication.
pub(crate) async fn authenticate<S>(
    stream: &mut S,
    username: &str,
    password: &str,
) -> Result<AuthResult, VncError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if username.len() > MAX_ARD_FIELD_LEN || password.len() > MAX_ARD_FIELD_LEN {
        return Err(VncError::CredentialTooLong);
    }

    let generator = stream.read_u16().await?;
    let key_len = usize::from(stream.read_u16().await?);
    if generator < 2 || !(MIN_DH_KEY_LEN..=MAX_DH_KEY_LEN).contains(&key_len) {
        return Err(VncError::ConnectError);
    }

    let mut prime_bytes = vec![0u8; key_len];
    stream.read_exact(&mut prime_bytes).await?;
    let mut server_pub_bytes = vec![0u8; key_len];
    stream.read_exact(&mut server_pub_bytes).await?;

    #[cfg(not(target_arch = "wasm32"))]
    let (client_pub_bytes, ciphertext) = {
        let mut u = username.to_owned();
        let mut p = password.to_owned();
        let result = tokio::task::spawn_blocking(move || {
            let res = compute_dh_and_encrypt(generator, &prime_bytes, &server_pub_bytes, &u, &p);
            u.zeroize();
            p.zeroize();
            res
        })
        .await
        .map_err(|_| VncError::ConnectError)?;
        result?
    };

    #[cfg(target_arch = "wasm32")]
    let (client_pub_bytes, ciphertext) = compute_dh_and_encrypt(
        generator,
        &prime_bytes,
        &server_pub_bytes,
        username,
        password,
    )?;

    // ARD Security Type 30 wire order: 128-byte AES-128-ECB ciphertext followed by key_len client public key.
    let mut payload = Vec::with_capacity(ARD_CREDENTIAL_BLOCK_LEN + key_len);
    payload.extend_from_slice(&ciphertext);
    payload.extend_from_slice(&client_pub_bytes);
    stream.write_all(&payload).await?;
    stream.flush().await?;

    let result = stream.read_u32().await?;
    result.try_into()
}

#[cfg(test)]
mod tests {
    use aes::cipher::BlockCipherDecrypt;

    use super::*;

    #[tokio::test]
    async fn ard_dh_roundtrip_encrypts_credentials_with_leading_zero_padding() {
        // Test with a prime whose high byte is 0x00 to exercise leading-zero big-endian padding.
        let key_len = 64usize;
        let generator: u16 = 5;
        let mut prime_bytes = vec![0u8; key_len];
        prime_bytes[1] = 0xFF;
        prime_bytes[key_len - 1] = 0xFB; // Odd modulus with leading zero byte.
        let prime = BigUint::from_bytes_be(&prime_bytes);
        let g = BigUint::from(generator);
        let server_priv = BigUint::from(0x1234_5678_9abc_def1_u64);
        let server_pub = g.modpow(&server_priv, &prime);
        let server_pub_bytes = to_fixed_be(&server_pub, key_len).unwrap();

        let (mut server, mut client) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            server.write_u16(generator).await.unwrap();
            server.write_u16(key_len as u16).await.unwrap();
            server.write_all(&prime_bytes).await.unwrap();
            server.write_all(&server_pub_bytes).await.unwrap();

            let mut ciphertext = [0u8; 128];
            server.read_exact(&mut ciphertext).await.unwrap();
            let mut client_pub_bytes = vec![0u8; key_len];
            server.read_exact(&mut client_pub_bytes).await.unwrap();

            let client_pub = BigUint::from_bytes_be(&client_pub_bytes);
            let shared = client_pub.modpow(&server_priv, &prime);
            let shared_bytes = to_fixed_be(&shared, key_len).unwrap();
            let aes_key = md5::compute(&shared_bytes).0;
            let cipher = Aes128::new(&Array::from(aes_key));

            let mut plain = ciphertext;
            for chunk in plain.chunks_exact_mut(16) {
                let mut block = Array::from(<[u8; 16]>::try_from(&chunk[..]).unwrap());
                cipher.decrypt_block(&mut block);
                chunk.copy_from_slice(&block);
            }

            let user_nul = plain[..64].iter().position(|&b| b == 0).unwrap();
            let pass_nul = plain[64..128].iter().position(|&b| b == 0).unwrap();
            assert_eq!(&plain[..user_nul], b"alice");
            assert_eq!(&plain[64..64 + pass_nul], b"mac-secret-pass");

            server.write_u32(0).await.unwrap();
        });

        let result = authenticate(&mut client, "alice", "mac-secret-pass")
            .await
            .unwrap();
        assert!(matches!(result, AuthResult::Ok));
        server_task.await.unwrap();
    }

    #[tokio::test]
    async fn ard_rejects_oversized_credentials_and_invalid_dh_lengths() {
        let (_, mut client) = tokio::io::duplex(64);
        let long = "a".repeat(64);
        assert!(matches!(
            authenticate(&mut client, &long, "pw").await,
            Err(VncError::CredentialTooLong)
        ));
        assert!(matches!(
            authenticate(&mut client, "user", &long).await,
            Err(VncError::CredentialTooLong)
        ));

        let (mut server, mut client) = tokio::io::duplex(64);
        server.write_u16(2).await.unwrap();
        server.write_u16(2048).await.unwrap(); // Exceeds MAX_DH_KEY_LEN.
        assert!(matches!(
            authenticate(&mut client, "user", "pw").await,
            Err(VncError::ConnectError)
        ));
    }

    fn decode_hex(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn ard_crypto_matches_openssl_and_nist_reference_vectors() {
        // RFC 1321 MD5("abc")
        assert_eq!(
            md5::compute(b"abc").0.as_slice(),
            decode_hex("900150983cd24fb0d6963f7d28e17f72").as_slice()
        );

        // NIST FIPS-197 Appendix B AES-128-ECB
        let key: [u8; 16] = decode_hex("2b7e151628aed2a6abf7158809cf4f3c")
            .try_into()
            .unwrap();
        let mut nist_block = Array::from(
            <[u8; 16]>::try_from(decode_hex("3243f6a8885a308d313198a2e0370734")).unwrap(),
        );
        Aes128::new(&Array::from(key)).encrypt_block(&mut nist_block);
        assert_eq!(
            nist_block.as_slice(),
            decode_hex("3925841d02dc09fbdc118597196a0b32").as_slice()
        );

        // Independent OpenSSL + Python RFC 2409 Oakley Group 2 DH + MD5 + AES-128-ECB vector
        let prime = decode_hex(concat!(
            "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd1",
            "29024e088a67cc74020bbea63b139b22514a08798e3404dd",
            "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245",
            "e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed",
            "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece65381",
            "ffffffffffffffff"
        ));
        let server_pub = decode_hex(concat!(
            "1a362ff95ab70d019414d0b918ee445bc1fe102da2ea1bd98e96a6f8c49cc0b1",
            "069ba26a11d9c1244c8b3725d8e6a442604282ef3ffcd0c7be8a3117beaafa38",
            "74f4999f889b3d11e6368f8a0df5e41e442f7535ba4356cbde7b4e3cd45c5d97",
            "23faaff3d1c568ff324b821fb5012b82b5c2b3983f34db878a217cbecfbf6145"
        ));
        let client_priv = BigUint::from_bytes_be(&decode_hex(
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543211",
        ));
        let mut pad = [0u8; ARD_CREDENTIAL_BLOCK_LEN];
        for (i, byte) in pad.iter_mut().enumerate() {
            *byte = i as u8;
        }
        let (client_pub, ct) = encrypt_credentials_with_dh(
            2,
            &prime,
            &server_pub,
            &client_priv,
            "zhongxuming",
            "Secret#123!",
            pad,
        )
        .unwrap();
        assert_eq!(
            client_pub,
            decode_hex(concat!(
                "0c6ef932511646bd62b342c7738fe559f496852557a139889fef8212c8f87620",
                "7d0dd5239a5f04580c0702222167d3c2f64c428ec82ddaaa388c917ba58019d3",
                "111c12c726f01e22adb5f5d5c155504198fde4932a38a16b1439fac0c10b6b6e",
                "3fe9bd8a0e084a935737795c8fac340fef43d456a8dff67c8f3da5c13e88a44c"
            ))
        );
        assert_eq!(
            ct.as_slice(),
            decode_hex(concat!(
                "1bf9fa632bf7cf138bafcd7945bbdc6891997c3743445433a901959203c1dc13",
                "6d165b87d51e3fd182d53a1914124c26460466fe5dc1237b5f93bb80c8b7e134",
                "4175bdb9ffcd7cafe06131f7825a37257075a4262eeff22efcd5e6134850330f",
                "dcf9aa43ac9a17cf107616da930b3c8bcd8686955f027f263d79b9b61e3a5e7c"
            ))
            .as_slice()
        );
    }
}
