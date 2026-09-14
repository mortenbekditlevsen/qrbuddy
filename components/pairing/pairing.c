#include "pairing.h"

#include <string.h>

#include "esp_random.h"
#include "esp_timer.h"
#include "nvs.h"
#include "nvs_flash.h"

#include "mbedtls/ecp.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/md.h"
#include "mbedtls/gcm.h"

// MARK: - Random bytes

void pairing_random_bytes(uint8_t *out, size_t len)
{
    esp_fill_random(out, len);
}

/* mbedtls's f_rng callback shape, wrapping the hardware RNG. */
static int rng_cb(void *ctx, unsigned char *out, size_t len)
{
    (void) ctx;
    esp_fill_random(out, len);
    return 0;
}

// MARK: - X25519 (verified against RFC 7748 §6.1's worked example and its
// own round-trip -- see the design doc's crypto section for why the plain
// mbedtls_ecdh_make_public()/read_public() convenience API is deliberately
// NOT used here: it wraps the point in an extra TLS-style length-prefix
// byte we don't want on the wire. Going through mbedtls_ecp_point_write_
// binary()/read_binary() directly gives the clean 32-byte RFC 7748 raw
// encoding instead.)

void pairing_x25519_keypair(uint8_t priv_out[PAIRING_PRIVKEY_LEN], uint8_t pub_out[PAIRING_PUBKEY_LEN])
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519);

    mbedtls_mpi d;
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point Q;
    mbedtls_ecp_point_init(&Q);

    // Generates a correctly-clamped random scalar (RFC 7748 §5) and Q = d*G.
    mbedtls_ecp_gen_keypair(&grp, &d, &Q, rng_cb, NULL);

    mbedtls_mpi_write_binary_le(&d, priv_out, PAIRING_PRIVKEY_LEN);
    size_t olen;
    // point_format is ignored for Montgomery curves (Curve25519 "always
    // uses the same point format" per mbedtls's own ecp.c) -- this writes
    // exactly PAIRING_PUBKEY_LEN raw bytes, no prefix.
    mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_COMPRESSED, &olen, pub_out, PAIRING_PUBKEY_LEN);

    mbedtls_mpi_free(&d);
    mbedtls_ecp_point_free(&Q);
    mbedtls_ecp_group_free(&grp);
}

void pairing_x25519_shared(const uint8_t priv[PAIRING_PRIVKEY_LEN], const uint8_t peer_pub[PAIRING_PUBKEY_LEN],
                            uint8_t shared_out[PAIRING_SECRET_LEN])
{
    mbedtls_ecp_group grp;
    mbedtls_ecp_group_init(&grp);
    mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519);

    mbedtls_mpi d;
    mbedtls_mpi_init(&d);
    mbedtls_mpi_read_binary_le(&d, priv, PAIRING_PRIVKEY_LEN);

    mbedtls_ecp_point Qp;
    mbedtls_ecp_point_init(&Qp);
    mbedtls_ecp_point_read_binary(&grp, &Qp, peer_pub, PAIRING_PUBKEY_LEN);

    mbedtls_mpi z;
    mbedtls_mpi_init(&z);
    mbedtls_ecdh_compute_shared(&grp, &z, &Qp, &d, rng_cb, NULL);
    mbedtls_mpi_write_binary_le(&z, shared_out, PAIRING_SECRET_LEN);

    mbedtls_mpi_free(&d);
    mbedtls_mpi_free(&z);
    mbedtls_ecp_point_free(&Qp);
    mbedtls_ecp_group_free(&grp);
}

// MARK: - HKDF-SHA256 / HMAC-SHA256

void pairing_hmac_sha256(const uint8_t key[PAIRING_SECRET_LEN], const uint8_t *data, size_t data_len,
                          uint8_t *out, size_t out_len)
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    uint8_t full[32];
    mbedtls_md_hmac(md, key, PAIRING_SECRET_LEN, data, data_len, full);
    memcpy(out, full, out_len < 32 ? out_len : 32);
}

void pairing_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                          const uint8_t *salt, size_t salt_len,
                          const uint8_t *info, size_t info_len,
                          uint8_t out[PAIRING_SECRET_LEN])
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);

    // Extract: PRK = HMAC-SHA256(salt, IKM).
    uint8_t prk[32];
    mbedtls_md_hmac(md, salt, salt_len, ikm, ikm_len, prk);

    // Expand: T(1) = HMAC-SHA256(PRK, info || 0x01) -- a single block is
    // exactly enough since every derivation in this protocol wants exactly
    // 32 bytes (== SHA-256's output size), so there's no T(2).. to chain.
    uint8_t buf[128];
    memcpy(buf, info, info_len);
    buf[info_len] = 0x01;
    mbedtls_md_hmac(md, prk, 32, buf, info_len + 1, out);
}

// MARK: - AES-256-GCM

void pairing_aes_gcm_encrypt(const uint8_t key[PAIRING_SECRET_LEN], const uint8_t nonce[PAIRING_NONCE_LEN],
                              const uint8_t *plaintext, size_t len,
                              uint8_t *ciphertext_out, uint8_t tag_out[PAIRING_TAG_LEN])
{
    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, PAIRING_SECRET_LEN * 8);
    mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, len,
                              nonce, PAIRING_NONCE_LEN, NULL, 0,
                              plaintext, ciphertext_out, PAIRING_TAG_LEN, tag_out);
    mbedtls_gcm_free(&gcm);
}

bool pairing_aes_gcm_decrypt(const uint8_t key[PAIRING_SECRET_LEN], const uint8_t nonce[PAIRING_NONCE_LEN],
                              const uint8_t *ciphertext, size_t len,
                              const uint8_t tag[PAIRING_TAG_LEN],
                              uint8_t *plaintext_out)
{
    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, PAIRING_SECRET_LEN * 8);
    int ret = mbedtls_gcm_auth_decrypt(&gcm, len, nonce, PAIRING_NONCE_LEN, NULL, 0,
                                       tag, PAIRING_TAG_LEN, ciphertext, plaintext_out);
    mbedtls_gcm_free(&gcm);
    return ret == 0;
}

// MARK: - Trust storage (NVS)

#define NVS_NAMESPACE  "qrb_pair"
#define NVS_KEY_TRUST  "trust"
#define TRUST_BLOB_LEN (PAIRING_CLIENT_ID_LEN + PAIRING_SECRET_LEN)

bool pairing_has_trust(void)
{
    uint8_t dummy_id[PAIRING_CLIENT_ID_LEN], dummy_ltk[PAIRING_SECRET_LEN];
    return pairing_load_trust(dummy_id, dummy_ltk);
}

bool pairing_load_trust(uint8_t client_id_out[PAIRING_CLIENT_ID_LEN], uint8_t ltk_out[PAIRING_SECRET_LEN])
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READONLY, &h) != ESP_OK) return false;

    uint8_t blob[TRUST_BLOB_LEN];
    size_t len = sizeof(blob);
    esp_err_t err = nvs_get_blob(h, NVS_KEY_TRUST, blob, &len);
    nvs_close(h);

    if (err != ESP_OK || len != TRUST_BLOB_LEN) return false;

    memcpy(client_id_out, blob, PAIRING_CLIENT_ID_LEN);
    memcpy(ltk_out, blob + PAIRING_CLIENT_ID_LEN, PAIRING_SECRET_LEN);
    return true;
}

void pairing_store_trust(const uint8_t client_id[PAIRING_CLIENT_ID_LEN], const uint8_t ltk[PAIRING_SECRET_LEN])
{
    uint8_t blob[TRUST_BLOB_LEN];
    memcpy(blob, client_id, PAIRING_CLIENT_ID_LEN);
    memcpy(blob + PAIRING_CLIENT_ID_LEN, ltk, PAIRING_SECRET_LEN);

    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_blob(h, NVS_KEY_TRUST, blob, sizeof(blob));
    nvs_commit(h);
    nvs_close(h);
}

void pairing_clear_trust(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, NVS_KEY_TRUST);   // ESP_ERR_NVS_NOT_FOUND (nothing to erase) is fine to ignore
    nvs_commit(h);
    nvs_close(h);
}

// MARK: - Pairing window

// Crockford base32 -- excludes ambiguous I/L/O/U (see docs/ble-provisioning.md §7).
static const char POP_ALPHABET[32] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

#define POP_WINDOW_TIMEOUT_US   (5LL * 60 * 1000 * 1000)   // 5 minutes
#define POP_MAX_FAILURES        5

static struct {
    bool open;
    uint8_t pop[PAIRING_POP_LEN];      // raw ASCII bytes, e.g. "7K2M9XAB"
    int64_t opened_at_us;
    int fail_count;
} s_window;

void pairing_open_window(char pop_out[PAIRING_POP_LEN + 1])
{
    uint8_t raw[PAIRING_POP_LEN];
    pairing_random_bytes(raw, sizeof(raw));
    for (int i = 0; i < PAIRING_POP_LEN; i++) {
        s_window.pop[i] = (uint8_t) POP_ALPHABET[raw[i] & 0x1F];   // 5 bits, uniform (32 is a power of 2)
    }

    s_window.open = true;
    s_window.opened_at_us = esp_timer_get_time();
    s_window.fail_count = 0;

    memcpy(pop_out, s_window.pop, PAIRING_POP_LEN);
    pop_out[PAIRING_POP_LEN] = '\0';
}

void pairing_close_window(void)
{
    s_window.open = false;
}

bool pairing_window_is_open(void)
{
    return s_window.open;
}

bool pairing_window_pop_bytes(uint8_t pop_out[PAIRING_POP_LEN])
{
    if (!s_window.open) return false;
    memcpy(pop_out, s_window.pop, PAIRING_POP_LEN);
    return true;
}

bool pairing_window_tick_expiry(void)
{
    if (!s_window.open) return false;
    if (esp_timer_get_time() - s_window.opened_at_us < POP_WINDOW_TIMEOUT_US) return false;
    pairing_close_window();
    return true;
}

bool pairing_window_note_failure(void)
{
    if (!s_window.open) return false;
    s_window.fail_count++;
    if (s_window.fail_count < POP_MAX_FAILURES) return false;
    pairing_close_window();
    return true;
}
