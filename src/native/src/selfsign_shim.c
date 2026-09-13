/* Generate a self-signed certificate, so `vyto-proxyd --tls` works with no
 * setup at all.
 *
 * This lives here rather than in vyto/crypto/openssl because that package's
 * key-generation surface (ossl_genkey and friends) is still a todo() stub, and
 * filling it in properly is a bigger job than this one use needs — a real
 * implementation owes callers key formats, passwords and PEM round-trips. What
 * a dev proxy needs is narrower: one EC key and one certificate, both as PEM
 * text, once, at startup.
 *
 * The certificate is deliberately weak in the ways that do not matter locally
 * and strict in the ones that do. It is valid for one year, names localhost
 * plus whatever domains the route table holds, and is signed by itself — a
 * browser will warn about it until it is trusted, which is correct, because
 * nothing about it proves anything. It exists so the TLS path is exercisable
 * without a certificate authority, not so it can be relied on.
 *
 * P-256 rather than RSA: key generation is effectively instant, where an
 * RSA-2048 keygen can take a visible second at startup on a slow machine.
 *
 * Platform arm: this file is globbed and compiled for every target, so the
 * non-OpenSSL build gets stubs that report failure and let the caller fall
 * back to --cert/--key.
 */

#include <string.h>
#include <stdlib.h>

#if defined(VT_NO_LIBC) || defined(VYTO_NO_OPENSSL)

int vp_selfsign(const char *names, char *cert_out, int cert_cap,
                char *key_out, int key_cap) {
    (void)names;
    if (cert_out && cert_cap > 0) cert_out[0] = 0;
    if (key_out && key_cap > 0) key_out[0] = 0;
    return 0;
}

#else

#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/evp.h>
#include <openssl/bio.h>
#include <openssl/rand.h>

/* Copy a BIO's contents out as a NUL-terminated C string. Returns 0 if it does
 * not fit, so a caller with a small buffer gets a failure rather than a
 * truncated PEM that would fail to parse later in a much more confusing place. */
static int bio_to_buf(BIO *b, char *out, int cap) {
    char *p = NULL;
    long n = BIO_get_mem_data(b, &p);
    if (n <= 0 || !p || n >= (long)cap) return 0;
    memcpy(out, p, (size_t)n);
    out[n] = 0;
    return 1;
}

/* `names` is a comma-separated SAN list already built by the caller, e.g.
 * "DNS:localhost,DNS:*.dev.local,IP:127.0.0.1".
 *
 * Returns 1 on success with PEM text in both buffers, 0 on any failure. */
int vp_selfsign(const char *names, char *cert_out, int cert_cap,
                char *key_out, int key_cap) {
    EVP_PKEY *pkey = NULL;
    X509 *x = NULL;
    BIO *bc = NULL, *bk = NULL;
    int ok = 0;

    if (!cert_out || cert_cap <= 0 || !key_out || key_cap <= 0) return 0;
    cert_out[0] = 0;
    key_out[0] = 0;

    /* P-256, via the 3.0 one-shot helper. */
    pkey = EVP_EC_gen("P-256");
    if (!pkey) goto done;

    x = X509_new();
    if (!x) goto done;

    /* v3, which is what a SAN extension requires to be honoured at all. */
    if (!X509_set_version(x, 2)) goto done;

    /* A random serial. Reusing a serial across regenerations makes a browser
     * that cached the old one treat the new one as a duplicate. */
    {
        unsigned char sbuf[16];
        if (RAND_bytes(sbuf, sizeof sbuf) != 1) goto done;
        sbuf[0] &= 0x7f;                    /* keep it positive */
        BIGNUM *bn = BN_bin2bn(sbuf, sizeof sbuf, NULL);
        if (!bn) goto done;
        ASN1_INTEGER *ai = BN_to_ASN1_INTEGER(bn, NULL);
        BN_free(bn);
        if (!ai) goto done;
        int sok = X509_set_serialNumber(x, ai);
        ASN1_INTEGER_free(ai);
        if (!sok) goto done;
    }

    if (!X509_gmtime_adj(X509_getm_notBefore(x), -3600)) goto done;  /* clock skew */
    if (!X509_gmtime_adj(X509_getm_notAfter(x), 365L * 24 * 3600)) goto done;
    if (!X509_set_pubkey(x, pkey)) goto done;

    {
        X509_NAME *nm = X509_get_subject_name(x);
        if (!nm) goto done;
        if (!X509_NAME_add_entry_by_txt(nm, "CN", MBSTRING_ASC,
                                        (const unsigned char *)"vyto-proxy local", -1, -1, 0))
            goto done;
        /* Self-signed: issuer is the subject. */
        if (!X509_set_issuer_name(x, nm)) goto done;
    }

    /* The SAN is the part that matters — modern clients ignore CN entirely. */
    if (names && names[0]) {
        X509_EXTENSION *e = X509V3_EXT_conf_nid(NULL, NULL, NID_subject_alt_name,
                                                (char *)names);
        if (!e) goto done;
        int aok = X509_add_ext(x, e, -1);
        X509_EXTENSION_free(e);
        if (!aok) goto done;
    }

    /* Mark it a CA so it can be added to a trust store and actually be trusted;
     * without this, importing it still yields a warning in some clients. */
    {
        X509_EXTENSION *e = X509V3_EXT_conf_nid(NULL, NULL, NID_basic_constraints,
                                                (char *)"critical,CA:TRUE");
        if (e) { X509_add_ext(x, e, -1); X509_EXTENSION_free(e); }
    }

    if (!X509_sign(x, pkey, EVP_sha256())) goto done;

    bc = BIO_new(BIO_s_mem());
    bk = BIO_new(BIO_s_mem());
    if (!bc || !bk) goto done;
    if (!PEM_write_bio_X509(bc, x)) goto done;
    if (!PEM_write_bio_PrivateKey(bk, pkey, NULL, NULL, 0, NULL, NULL)) goto done;
    if (!bio_to_buf(bc, cert_out, cert_cap)) goto done;
    if (!bio_to_buf(bk, key_out, key_cap)) goto done;
    ok = 1;

done:
    if (bc) BIO_free(bc);
    if (bk) BIO_free(bk);
    if (x) X509_free(x);
    if (pkey) EVP_PKEY_free(pkey);
    if (!ok) { cert_out[0] = 0; key_out[0] = 0; }
    return ok;
}

#endif
