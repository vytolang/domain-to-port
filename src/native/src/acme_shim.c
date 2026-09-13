/* The crypto ACME needs: an account key, JWS signatures, and a CSR.
 *
 * vyto/crypto/openssl declares ossl_genkey, ossl_sign and ossl_pkey_to_pem but
 * every one of them is still a todo() stub that panics, so this supplies the
 * four operations an ACME client cannot do without. Same reasoning as
 * selfsign_shim.c next door: filling in that package properly owes callers key
 * formats, passwords and round-trips, which is a larger job than this one use
 * needs.
 *
 * Everything here is ES256 (ECDSA on P-256 with SHA-256). ACME requires an
 * account key be RSA or ECDSA, and P-256 is the smallest thing every CA
 * accepts. One algorithm means no negotiation and no way to pick wrong.
 *
 * THE ONE SUBTLETY: ECDSA signature encoding.
 *
 * OpenSSL emits a DER SEQUENCE of two INTEGERs. JWS wants the raw
 * concatenation R||S, each left-padded to exactly 32 bytes. They are not the
 * same bytes, and a DER signature sent to an ACME server is rejected with a
 * malformed-JWS error that says nothing about encoding. vp_acme_sign converts.
 */

#include <string.h>
#include <stdlib.h>

#if defined(VT_NO_LIBC) || defined(VYTO_NO_OPENSSL)

void *vp_acme_genkey(void)                                        { return 0; }
void *vp_acme_key_from_pem(const char *p)                         { (void)p; return 0; }
int   vp_acme_key_to_pem(void *k, char *o, int c)                 { (void)k; if (o && c > 0) o[0] = 0; return 0; }
int   vp_acme_jwk(void *k, char *o, int c)                        { (void)k; if (o && c > 0) o[0] = 0; return 0; }
int   vp_acme_sign(void *k, const void *d, int n, void *o, int c) { (void)k; (void)d; (void)n; (void)o; (void)c; return 0; }
int   vp_acme_csr(void *k, const char *names, void *o, int c)     { (void)k; (void)names; (void)o; (void)c; return 0; }
void  vp_acme_key_free(void *k)                                   { (void)k; }

#else

#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>

#define P256_BYTES 32

/* Generate a P-256 account key. */
void *vp_acme_genkey(void) {
    return EVP_EC_gen("P-256");
}

void *vp_acme_key_from_pem(const char *pem) {
    if (!pem || !*pem) return NULL;
    BIO *b = BIO_new_mem_buf(pem, -1);
    if (!b) return NULL;
    EVP_PKEY *k = PEM_read_bio_PrivateKey(b, NULL, NULL, NULL);
    BIO_free(b);
    return k;
}

int vp_acme_key_to_pem(void *key, char *out, int cap) {
    EVP_PKEY *k = (EVP_PKEY *)key;
    if (!k || !out || cap <= 0) return 0;
    out[0] = 0;
    BIO *b = BIO_new(BIO_s_mem());
    if (!b) return 0;
    int ok = PEM_write_bio_PrivateKey(b, k, NULL, NULL, 0, NULL, NULL);
    if (ok) {
        char *p = NULL;
        long n = BIO_get_mem_data(b, &p);
        if (n > 0 && p && n < (long)cap) { memcpy(out, p, (size_t)n); out[n] = 0; }
        else ok = 0;
    }
    BIO_free(b);
    return ok ? 1 : 0;
}

/* Write the public key as a JWK, with members in the exact order RFC 7638
 * requires for a thumbprint: crv, kty, x, y, lexicographic, no whitespace.
 *
 * The caller hashes this string directly for the key authorization, so the
 * ordering is not cosmetic — a differently ordered JWK produces a different
 * thumbprint and every challenge fails validation. */
int vp_acme_jwk(void *key, char *out, int cap) {
    EVP_PKEY *k = (EVP_PKEY *)key;
    if (!k || !out || cap <= 0) return 0;
    out[0] = 0;

    BIGNUM *x = NULL, *y = NULL;
    if (!EVP_PKEY_get_bn_param(k, "qx", &x)) return 0;
    if (!EVP_PKEY_get_bn_param(k, "qy", &y)) { BN_free(x); return 0; }

    unsigned char xb[P256_BYTES], yb[P256_BYTES];
    int ok = (BN_bn2binpad(x, xb, P256_BYTES) == P256_BYTES)
          && (BN_bn2binpad(y, yb, P256_BYTES) == P256_BYTES);
    BN_free(x);
    BN_free(y);
    if (!ok) return 0;

    /* base64url, no padding — the encoding JWK coordinates use. */
    static const char A[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    char xs[48], ys[48];
    for (int pass = 0; pass < 2; pass++) {
        const unsigned char *src = pass ? yb : xb;
        char *dst = pass ? ys : xs;
        int j = 0;
        for (int i = 0; i < P256_BYTES; i += 3) {
            unsigned v = (unsigned)src[i] << 16;
            int rem = P256_BYTES - i;
            if (rem > 1) v |= (unsigned)src[i + 1] << 8;
            if (rem > 2) v |= (unsigned)src[i + 2];
            dst[j++] = A[(v >> 18) & 63];
            dst[j++] = A[(v >> 12) & 63];
            if (rem > 1) dst[j++] = A[(v >> 6) & 63];
            if (rem > 2) dst[j++] = A[v & 63];
        }
        dst[j] = 0;
    }

    int n = snprintf(out, (size_t)cap,
                     "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"%s\",\"y\":\"%s\"}", xs, ys);
    return (n > 0 && n < cap) ? 1 : 0;
}

/* Sign `data` with SHA-256, writing 64 raw bytes (R||S) to `out`.
 *
 * The DER-to-raw conversion is the part that bites: OpenSSL gives a DER
 * SEQUENCE, JWS wants fixed-width R and S concatenated. */
int vp_acme_sign(void *key, const void *data, int len, void *out, int cap) {
    EVP_PKEY *k = (EVP_PKEY *)key;
    if (!k || !data || len <= 0 || !out || cap < 2 * P256_BYTES) return 0;

    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx) return 0;

    unsigned char *der = NULL;
    size_t derlen = 0;
    int ok = 0;

    if (EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, k) != 1) goto done;
    if (EVP_DigestSign(ctx, NULL, &derlen, (const unsigned char *)data, (size_t)len) != 1) goto done;
    der = (unsigned char *)malloc(derlen);
    if (!der) goto done;
    if (EVP_DigestSign(ctx, der, &derlen, (const unsigned char *)data, (size_t)len) != 1) goto done;

    {
        const unsigned char *p = der;
        ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &p, (long)derlen);
        if (!sig) goto done;
        const BIGNUM *r = ECDSA_SIG_get0_r(sig);
        const BIGNUM *s = ECDSA_SIG_get0_s(sig);
        unsigned char *o = (unsigned char *)out;
        ok = (BN_bn2binpad(r, o, P256_BYTES) == P256_BYTES)
          && (BN_bn2binpad(s, o + P256_BYTES, P256_BYTES) == P256_BYTES);
        ECDSA_SIG_free(sig);
    }

done:
    free(der);
    EVP_MD_CTX_free(ctx);
    return ok ? 1 : 0;
}

/* Build a DER CSR for `names`, a comma-separated list of DNS names.
 *
 * The first name goes in the subject CN and every name goes in the SAN
 * extension. Modern CAs read only the SAN, but a CSR with an empty subject is
 * rejected by some, so both are filled. Returns the DER length, or 0. */
int vp_acme_csr(void *key, const char *names, void *out, int cap) {
    EVP_PKEY *k = (EVP_PKEY *)key;
    if (!k || !names || !*names || !out || cap <= 0) return 0;

    X509_REQ *req = X509_REQ_new();
    STACK_OF(X509_EXTENSION) *exts = NULL;
    char *copy = NULL;
    unsigned char *der = NULL;
    int outlen = 0;

    if (!req) goto done;
    if (!X509_REQ_set_version(req, 0)) goto done;
    if (!X509_REQ_set_pubkey(req, k)) goto done;

    copy = strdup(names);
    if (!copy) goto done;

    /* Subject CN = the first name. */
    {
        char *comma = strchr(copy, ',');
        if (comma) *comma = 0;
        X509_NAME *nm = X509_REQ_get_subject_name(req);
        int nok = X509_NAME_add_entry_by_txt(nm, "CN", MBSTRING_ASC,
                                             (const unsigned char *)copy, -1, -1, 0);
        if (comma) *comma = ',';
        if (!nok) goto done;
    }

    /* SAN: "DNS:a,DNS:b" built from the caller's plain list. */
    {
        size_t need = strlen(names) * 5 + 8;
        char *san = (char *)malloc(need);
        if (!san) goto done;
        san[0] = 0;
        char *save = NULL;
        char *tmp = strdup(names);
        if (!tmp) { free(san); goto done; }
        for (char *t = strtok_r(tmp, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
            while (*t == ' ') t++;
            if (!*t) continue;
            if (san[0]) strcat(san, ",");
            strcat(san, "DNS:");
            strcat(san, t);
        }
        free(tmp);

        exts = sk_X509_EXTENSION_new_null();
        X509_EXTENSION *e = exts ? X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name, san) : NULL;
        free(san);
        if (!e) goto done;
        sk_X509_EXTENSION_push(exts, e);
        if (!X509_REQ_add_extensions(req, exts)) goto done;
    }

    if (!X509_REQ_sign(req, k, EVP_sha256())) goto done;

    {
        int n = i2d_X509_REQ(req, &der);
        if (n > 0 && n <= cap) { memcpy(out, der, (size_t)n); outlen = n; }
    }

done:
    if (der) OPENSSL_free(der);
    if (exts) sk_X509_EXTENSION_pop_free(exts, X509_EXTENSION_free);
    free(copy);
    if (req) X509_REQ_free(req);
    return outlen;
}

void vp_acme_key_free(void *key) { EVP_PKEY_free((EVP_PKEY *)key); }

#endif
