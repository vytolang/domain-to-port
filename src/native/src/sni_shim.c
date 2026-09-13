/* Server-side SNI: one certificate per domain.
 *
 * vyto/crypto/openssl binds the client half of SNI (the name a client *sends*)
 * but not the server half, so this supplies it. The missing piece is
 * SSL_CTX_set_tlsext_servername_callback: a hook OpenSSL calls mid-handshake,
 * after the ClientHello has been parsed and before a certificate is chosen,
 * whose job is to point the connection at whichever SSL_CTX holds the right
 * certificate for the name the client asked for.
 *
 * WHY THE TABLE LIVES IN C
 *
 * The callback runs inside OpenSSL, on the handshake path, in the middle of a
 * Vyto call. Calling back into Vyto from there has the same hazard as calling
 * into it from a signal handler: it can allocate, and the allocator may already
 * be held by the code we interrupted. So the lookup has to complete without
 * leaving C, which means the name -> context mapping has to be C data. Vyto
 * builds the table before any connection exists and then never touches it
 * during a handshake.
 *
 * WHAT IT DOES NOT DO
 *
 * No reload-while-serving. The table is built once at startup and replaced
 * wholesale; a SIGHUP that changes routes does not rebuild it, because a
 * certificate set is not something a route edit can produce. Swapping it under
 * live connections would need the old table kept alive for their duration, and
 * a proxy that can be restarted for a certificate change does not need that
 * complexity.
 *
 * Platform arm: compiled for every target, so the non-OpenSSL build gets stubs
 * that accept nothing and report failure, leaving the single-certificate path
 * to work as before.
 */

#include <string.h>
#include <stdlib.h>

#if defined(VT_NO_LIBC) || defined(VYTO_NO_OPENSSL)

void *vp_sni_new(void)                                  { return 0; }
int   vp_sni_add(void *t, const char *n, void *c)       { (void)t; (void)n; (void)c; return 0; }
int   vp_sni_install(void *t, void *base)               { (void)t; (void)base; return 0; }
int   vp_sni_count(void *t)                             { (void)t; return 0; }
void  vp_sni_free(void *t)                              { (void)t; }

#else

#include <openssl/ssl.h>
#include <openssl/err.h>

/* The shim's own context wrapper. This file is handed `rawptr`s that came out
 * of vyto/crypto/openssl's tls_server(), so it must agree with that file's
 * layout to reach the SSL_CTX inside.
 *
 * This is a real coupling and worth naming: if VosslCtx ever gains a field
 * before `ctx`, this reads the wrong pointer. It is first, and the struct is
 * append-only in practice, but a check is cheap — see vp_sni_add, which
 * refuses a context whose SSL_CTX does not look like one. */
typedef struct VosslCtxView {
    SSL_CTX      *ctx;
    unsigned char *alpn;
    unsigned      alpn_len;
    int           check_host;
    int           is_server;
} VosslCtxView;

#define SNI_MAX 64

typedef struct SniEntry {
    char     name[256];     /* lowercased, no leading "*." */
    int      wild;          /* matched as *.name */
    SSL_CTX *ctx;           /* borrowed: Vyto owns the TlsContext */
} SniEntry;

typedef struct SniTable {
    SniEntry ent[SNI_MAX];
    int      n;
} SniTable;

static void lower_copy(char *dst, const char *src, size_t cap) {
    size_t i = 0;
    for (; src[i] && i + 1 < cap; i++) {
        char c = src[i];
        dst[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    dst[i] = 0;
}

/* Does `host` match this entry? A wildcard matches exactly one label, the same
 * rule a wildcard SAN follows and the same rule the Vyto router applies. */
static int entry_matches(const SniEntry *e, const char *host) {
    if (!e->wild) return strcmp(e->name, host) == 0;

    size_t hl = strlen(host), nl = strlen(e->name);
    if (hl <= nl + 1) return 0;
    if (strcmp(host + (hl - nl), e->name) != 0) return 0;
    if (host[hl - nl - 1] != '.') return 0;
    /* Exactly one label in front: no further dot before the suffix. */
    return memchr(host, '.', hl - nl - 1) == NULL;
}

/* The callback. Runs mid-handshake; allocates nothing, calls nothing but
 * OpenSSL and string functions.
 *
 * Returning OK without switching contexts is what happens for an unknown name,
 * and it is deliberate: the handshake then completes against the base
 * certificate, and the request is answered by the proxy's ordinary 404 path.
 * Aborting here instead would give the client a TLS alert with nothing to
 * explain it, which is a much worse way to learn a domain has no route. */
static int on_servername(SSL *ssl, int *al, void *arg) {
    SniTable *t = (SniTable *)arg;
    (void)al;
    if (!t) return SSL_TLSEXT_ERR_OK;

    const char *sni = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
    if (!sni || !*sni) return SSL_TLSEXT_ERR_OK;

    char host[256];
    lower_copy(host, sni, sizeof host);

    /* Exact matches first, then wildcards: the table is ordered that way by
     * vp_sni_add, so one pass is enough. */
    for (int i = 0; i < t->n; i++) {
        if (entry_matches(&t->ent[i], host)) {
            SSL_set_SSL_CTX(ssl, t->ent[i].ctx);
            /* SSL_set_SSL_CTX does NOT copy the verify mode or options, so a
             * context that differs in those would silently lose them. Every
             * context here is built by the same tls_server() call, so they do
             * not differ — restating them anyway keeps that true if one day
             * they do. */
            SSL_set_options(ssl, SSL_CTX_get_options(t->ent[i].ctx));
            return SSL_TLSEXT_ERR_OK;
        }
    }
    return SSL_TLSEXT_ERR_OK;
}

void *vp_sni_new(void) {
    SniTable *t = (SniTable *)calloc(1, sizeof *t);
    return t;
}

/* Add one name -> context mapping. `name` may lead with "*." for a wildcard.
 * Exact names are kept before wildcards so the callback's single pass prefers
 * them; within the wildcards, longer suffixes come first so the most specific
 * wins, matching the router. */
int vp_sni_add(void *table, const char *name, void *vctx) {
    SniTable *t = (SniTable *)table;
    VosslCtxView *w = (VosslCtxView *)vctx;
    if (!t || !name || !*name || !w || !w->ctx) return 0;
    if (t->n >= SNI_MAX) return 0;

    /* Cheap sanity check on the borrowed layout: a real SSL_CTX answers this. */
    if (SSL_CTX_up_ref(w->ctx) != 1) return 0;
    SSL_CTX_free(w->ctx);

    SniEntry e;
    memset(&e, 0, sizeof e);
    e.ctx = w->ctx;
    if (name[0] == '*' && name[1] == '.') {
        e.wild = 1;
        lower_copy(e.name, name + 2, sizeof e.name);
    } else {
        e.wild = 0;
        lower_copy(e.name, name, sizeof e.name);
    }
    if (!e.name[0]) return 0;

    /* Insert in order: exact before wildcard, longer wildcard before shorter. */
    int at = t->n;
    for (int i = 0; i < t->n; i++) {
        int after_exact = (!e.wild && t->ent[i].wild);
        int longer_wild = (e.wild && t->ent[i].wild &&
                           strlen(e.name) > strlen(t->ent[i].name));
        if (after_exact || longer_wild) { at = i; break; }
    }
    for (int i = t->n; i > at; i--) t->ent[i] = t->ent[i - 1];
    t->ent[at] = e;
    t->n++;
    return 1;
}

/* Attach the table to the base context. Every connection accepted on that
 * context will consult it. */
int vp_sni_install(void *table, void *vbase) {
    SniTable *t = (SniTable *)table;
    VosslCtxView *b = (VosslCtxView *)vbase;
    if (!t || !b || !b->ctx) return 0;
    ERR_clear_error();
    if (SSL_CTX_set_tlsext_servername_callback(b->ctx, on_servername) != 1) return 0;
    if (SSL_CTX_set_tlsext_servername_arg(b->ctx, t) != 1) return 0;
    return 1;
}

int vp_sni_count(void *table) {
    SniTable *t = (SniTable *)table;
    return t ? t->n : 0;
}

void vp_sni_free(void *table) { free(table); }

#endif
