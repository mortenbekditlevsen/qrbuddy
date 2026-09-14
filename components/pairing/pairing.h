#ifndef __PAIRING_H__
#define __PAIRING_H__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* App-level BLE provisioning -- see docs/ble-provisioning.md for the full
 * design (wire format, KDF construction, threat model). This header is
 * plain C (no mbedtls/NVS/esp-idf types), so it's safe for Swift's
 * ClangImporter to parse directly, same as tileview/particle.h. All the
 * mbedtls/NVS complexity lives in pairing.c; the Swift side (a future
 * Pairing.swift, alongside GATTServer.swift) only ever holds plain
 * fixed-size byte arrays -- never a live mbedtls context or NVS handle --
 * matching how particle_t/particle.h keep LVGL out of the Swift <-> C
 * boundary. In particular, an ephemeral X25519 private scalar is just 32
 * plain bytes Swift holds in its per-connection session state between the
 * "generate keypair" and "compute shared secret" calls; nothing on the C
 * side stays alive across that gap. */

#define PAIRING_PUBKEY_LEN    32   // raw X25519 public key (RFC 7748 wire format)
#define PAIRING_PRIVKEY_LEN   32   // raw X25519 private scalar (already clamped)
#define PAIRING_SECRET_LEN    32   // shared secret / session key / LTK -- all 32 bytes
#define PAIRING_TAG_LEN       16   // confirm tag (truncated HMAC-SHA256) and AES-GCM auth tag
#define PAIRING_CLIENT_ID_LEN 16
#define PAIRING_NONCE_LEN     12   // AES-GCM nonce
#define PAIRING_POP_LEN        8   // Crockford base32 characters

// MARK: - Trust storage (NVS-backed; docs/ble-provisioning.md §9)

/** Whether a trusted client is currently stored. False on a factory-fresh
 * unit, or right after pairing_clear_trust(). */
bool pairing_has_trust(void);

/** Loads the stored trust entry into the two out-params. Returns false
 * (leaving both untouched) if none is stored. */
bool pairing_load_trust(uint8_t client_id_out[PAIRING_CLIENT_ID_LEN],
                         uint8_t ltk_out[PAIRING_SECRET_LEN]);

/** Persists a new trust entry, replacing any previous one. */
void pairing_store_trust(const uint8_t client_id[PAIRING_CLIENT_ID_LEN],
                          const uint8_t ltk[PAIRING_SECRET_LEN]);

/** Erases the stored trust entry -- the firmware side of "re-pair"
 * (docs/ble-provisioning.md §3c). Doesn't itself open a new pairing
 * window; call pairing_open_window() right after. */
void pairing_clear_trust(void);

// MARK: - Pairing window (POP lifetime, timeout, lockout -- §7)

/** Opens a fresh pairing window: generates a new POP, arms the timeout and
 * failure counter, and writes the POP as an 8-character (plus NUL)
 * Crockford-base32 string to `pop_out`, ready to render into the QR (§8)
 * and as a plaintext fallback. */
void pairing_open_window(char pop_out[PAIRING_POP_LEN + 1]);

/** Closes the pairing window early -- a pairing attempt actually
 * succeeded, or the caller wants to give up on it for some other reason. */
void pairing_close_window(void);

bool pairing_window_is_open(void);

/** The open window's POP, as raw bytes (its ASCII characters -- see
 * docs/ble-provisioning.md §6, "salt=POP_bytes") for use as an HKDF salt.
 * Returns false (leaving `pop_out` untouched) if no window is open. */
bool pairing_window_pop_bytes(uint8_t pop_out[PAIRING_POP_LEN]);

/** Call periodically (e.g. once a second) to expire a stale pairing
 * window. Returns true if this call is what just closed it. */
bool pairing_window_tick_expiry(void);

/** Records one failed ClientConfirm against the open window. Returns true
 * if this failure is what just closed the window (lockout). */
bool pairing_window_note_failure(void);

// MARK: - Crypto primitives (mbedtls-backed; §6)

/** Fresh ephemeral X25519 keypair. `priv_out` is the caller's to hold for
 * the lifetime of one handshake and pass back into pairing_x25519_shared()
 * once the peer's public key arrives. */
void pairing_x25519_keypair(uint8_t priv_out[PAIRING_PRIVKEY_LEN],
                             uint8_t pub_out[PAIRING_PUBKEY_LEN]);

/** Raw X25519 shared secret from our own ephemeral private scalar and the
 * peer's public key. */
void pairing_x25519_shared(const uint8_t priv[PAIRING_PRIVKEY_LEN],
                            const uint8_t peer_pub[PAIRING_PUBKEY_LEN],
                            uint8_t shared_out[PAIRING_SECRET_LEN]);

/** HKDF-SHA256 (RFC 5869), fixed to a single 32-byte output block -- every
 * derivation in this protocol needs exactly 32 bytes, which is exactly one
 * SHA-256 block, so there's no multi-block Expand loop to implement. */
void pairing_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                          const uint8_t *salt, size_t salt_len,
                          const uint8_t *info, size_t info_len,
                          uint8_t out[PAIRING_SECRET_LEN]);

/** HMAC-SHA256 over `data`, truncated to `out_len` bytes (used for the
 * PAIRING_TAG_LEN-byte confirm tags). */
void pairing_hmac_sha256(const uint8_t key[PAIRING_SECRET_LEN],
                          const uint8_t *data, size_t data_len,
                          uint8_t *out, size_t out_len);

/** AES-256-GCM encrypt. `nonce` is PAIRING_NONCE_LEN bytes; `ciphertext_out`
 * must have room for `len` bytes (GCM doesn't pad -- ciphertext is exactly
 * as long as the plaintext). */
void pairing_aes_gcm_encrypt(const uint8_t key[PAIRING_SECRET_LEN],
                              const uint8_t nonce[PAIRING_NONCE_LEN],
                              const uint8_t *plaintext, size_t len,
                              uint8_t *ciphertext_out,
                              uint8_t tag_out[PAIRING_TAG_LEN]);

/** AES-256-GCM decrypt + verify. Returns false (and leaves `plaintext_out`
 * undefined) if the tag doesn't verify -- callers must treat that as "drop
 * this message", never fall back to trusting the plaintext. */
bool pairing_aes_gcm_decrypt(const uint8_t key[PAIRING_SECRET_LEN],
                              const uint8_t nonce[PAIRING_NONCE_LEN],
                              const uint8_t *ciphertext, size_t len,
                              const uint8_t tag[PAIRING_TAG_LEN],
                              uint8_t *plaintext_out);

/** Cryptographically strong random bytes (hardware RNG). */
void pairing_random_bytes(uint8_t *out, size_t len);

#endif
