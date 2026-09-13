# vyto-proxy

Map a domain to a local port. Instantly.

```sh
domain-to-port -d www.example.com -p 8099
```

That is the whole interface. The route is live before the command returns — no
restart, no config reload dance, no dropped connections.

A 194 KB daemon that links libc and OpenSSL, and nothing else. It is a reverse
proxy with the parts you actually use on a dev machine and none of the parts
you don't.

## Install

```sh
make && make install                 # -> ~/.local/bin
sudo setcap cap_net_bind_service=+ep ~/.local/bin/vyto-proxyd
```

The `setcap` grants the one privilege a proxy needs — binding a port below 1024
— without the daemon ever running as root. Do it once.

## Use

Start the daemon (once, or from systemd):

```sh
vyto-proxyd                 # listens on :80
vyto-proxyd --tls           # :80 and :443, TLS terminated
vyto-proxyd -p 8080 -v      # somewhere else, and log every routing decision
```

Then point domains at ports:

```sh
domain-to-port -d www.example.com -p 8099
domain-to-port -d '*.dev.local'   -p 3000     # wildcard
domain-to-port -d www.example.com --rm        # remove
domain-to-port --list                         # show the table
```

For local development you also need the name to resolve. One line in
`/etc/hosts` does it:

```
127.0.0.1   www.example.com
```

## What it does

- **Routes on the `Host` header** — exact match, or `*.example.com` wildcards
  where the longest match wins.
- **Reloads live.** The CLI writes the table and signals the daemon; in-flight
  connections are untouched.
- **Explains itself when a backend is down.** A 502 that names the domain and
  the port beats a browser error page with nothing in it.
- **Passes anything through.** Once a connection is routed it is a byte pipe,
  so WebSocket upgrades, streaming responses, uploads and HTTP methods this
  proxy has never heard of all work without it understanding them.
- **Terminates TLS** with `--tls`, generates its own certificate if you have
  none, and serves a per-domain certificate via SNI when you do.

Measured on the test suite: a 3 MB response arrives byte-identical, 100
concurrent requests all succeed, and 60 MB of transfers move the daemon's RSS
by **0 kB**.

## TLS

```sh
vyto-proxyd --tls                                   # self-signed, zero setup
vyto-proxyd --tls --cert fullchain.pem --key key.pem
```

With no `--cert`, the daemon generates a self-signed P-256 certificate at
startup naming `localhost`, `127.0.0.1`, and **every domain in the route
table** — wildcard routes become wildcard SANs. Browsers warn until you trust
it, which is correct: it proves nothing. It exists so the TLS path works
without a certificate authority in the loop.

With `--cert` and `--key` (both, or neither — a typo'd path is an error rather
than a silent fall back to self-signed) it serves PEM files from disk: certbot
output, mkcert, anything. The cert chain is leaf first.

Plain HTTP keeps working on `:80` throughout. There is no automatic redirect to
https, because locally plenty of things legitimately want plain HTTP and a
redirect to an untrusted certificate is a dead end for anything that isn't a
browser.

Backends are always spoken to in plain HTTP over loopback — terminating here is
the point, so a dev server on `:3000` never needs to know a certificate exists.

### Per-domain certificates

Point `--certs` at a directory and each domain gets its own certificate,
selected during the handshake from the name the client sent:

```
certs/www.example.com.crt   certs/www.example.com.key
certs/_.dev.local.crt       certs/_.dev.local.key     ->  *.dev.local
```

`_` stands in for `*` because a shell expands an asterisk in a filename.

```sh
vyto-proxyd --tls --certs ./certs
```

A domain with no certificate of its own falls back to the base one and the
handshake still completes — so an unrouted name gets an ordinary 404 rather
than a bare TLS alert, which tells a developer almost nothing.

A `.crt` with no matching `.key`, an unreadable PEM, or a missing directory is
a startup error. The alternative is a proxy that starts fine and then serves
the wrong certificate for one domain, which nobody discovers until they visit
it.

The table is built once at startup. A `SIGHUP` reloads routes, not
certificates: swapping certificates under live connections would mean keeping
the old set alive for their lifetime, and a proxy that can be restarted for a
certificate change does not need that.

## How it works

One process, one epoll loop, non-blocking sockets throughout. No threads —
Vyto has none, deliberately, because they would force atomic refcounting on
every object in the program.

Each connection is a `Tunnel` holding two sockets and two 64 KB buffers. The
loop reads the client's header block only as far as the `Host` header, picks a
backend, and from then on stops parsing entirely. That is what makes protocol
passthrough free rather than a feature.

**TLS enters through an IO seam, not a second loop.** `Tunnel.frontRead` and
`frontWrite` are the only way the loop touches the client, and they are either
a plain socket call or a TLS one. Everything downstream — routing, buffering,
backpressure, teardown — is written once.

That seam has one subtlety worth knowing about: an SSL *read* can need the
socket to become **writable** (a TLS 1.3 key update, a renegotiation), and an
SSL write can need it readable. So a TLS tunnel remembers the direction OpenSSL
last asked for rather than deriving it from buffer state, the way the plain
path can. Code that always re-arms for readability works for months and then
hangs on a long-lived connection under load.

**Backpressure is the load-bearing detail.** A direction stops *reading* when
the buffer it feeds is full, so a fast backend cannot make the proxy hold
megabytes on behalf of a slow client. Ten slow clients pulling 3 MB each grow
RSS by about 1 MB, not 30 MB.

| File | What |
|---|---|
| `src/routes.vt` | the table: parsing, wildcard matching, atomic writes |
| `src/head.vt` | just enough HTTP to find `Host` |
| `src/tunnel.vt` | per-connection state machine and buffers |
| `src/proxyd.vt` | the epoll loop |
| `src/errors.vt` | the 400/404/502 pages |
| `src/tls.vt` | certificate acquisition: files, or self-signed |
| `src/sni.vt` | per-domain certificates, loaded from a directory |
| `src/signal.vt` | pidfile and SIGHUP |

State lives in `$XDG_STATE_HOME/vyto-proxy` (override with `$VYTO_PROXY_HOME`):
`routes.json` and `vyto-proxyd.pid`.

## Notes and limits

**Routing is decided by the first request on a connection.** Keep-alive
connections stay pinned to the backend chosen then. Browsers open one
connection per origin, so in practice this is invisible — but a client that
reuses one connection across several `Host` values will not be re-routed.

**A broken `routes.json` never takes the proxy down.** A reload that fails to
parse keeps the previous table and logs why. The CLI likewise refuses to
overwrite a file it could not read, rather than silently discarding routes.

**Backends are localhost only.** There is no backend *host* field, on purpose:
pointing at another machine needs a trust story this does not have.

Idle connections are dropped after 60 s, at most 256 at a time, header blocks
capped at 16 KB.

## Test

```sh
make test
```

80 checks: unit tests for the table and the header parser, then end-to-end
runs against real backends on loopback — routing, wildcards, keep-alive, a
3 MB download, a 100 KB POST, 100-way concurrency, fd and RSS hygiene, live
reload, the same payload and concurrency set again over TLS, and SNI serving
three distinct certificates to the domains that asked for them. No network access, and every port is picked free at run
time so the suite does not fight whatever else is on the machine.

Two checks are worth keeping honest, and both have been fault-injected to
confirm they still fail when their fix is removed: the fd-hygiene one (a client
that walked away mid-download used to leave both sockets open until the 60 s
sweep) and the TLS payload ones (reading the raw socket instead of the SSL
object hands the parser ciphertext, which hangs only on the TLS path).
