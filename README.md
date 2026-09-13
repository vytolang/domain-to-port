# vyto-proxy

Map a domain to a local port. Instantly.

```sh
domain-to-port -d www.example.com -p 8099
```

That is the whole interface. The route is live before the command returns — no
restart, no config reload dance, no dropped connections.

A 147 KB binary that links nothing but libc. It is a reverse proxy with the
parts you actually use on a dev machine and none of the parts you don't.

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

Measured on the test suite: a 3 MB response arrives byte-identical, 100
concurrent requests all succeed, and 60 MB of transfers move the daemon's RSS
by **0 kB**.

## How it works

One process, one epoll loop, non-blocking sockets throughout. No threads —
Vyto has none, deliberately, because they would force atomic refcounting on
every object in the program.

Each connection is a `Tunnel` holding two sockets and two 64 KB buffers. The
loop reads the client's header block only as far as the `Host` header, picks a
backend, and from then on stops parsing entirely. That is what makes protocol
passthrough free rather than a feature.

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

**No TLS yet.** `vyto/crypto/openssl` has everything needed for termination —
`tls_server` takes PEM text, `tls_accept` takes a raw fd, and `handshakeStep`
is non-blocking-aware — so the wiring is the work, not the primitives.
Multi-certificate SNI needs one new shim entry point:
`SSL_CTX_set_tlsext_servername_callback` is not currently bound.

**Backends are localhost only.** There is no backend *host* field, on purpose:
pointing at another machine needs a trust story this does not have.

Idle connections are dropped after 60 s, at most 256 at a time, header blocks
capped at 16 KB.

## Test

```sh
make test
```

61 checks: unit tests for the table and the header parser, then end-to-end
runs against real backends on loopback — routing, wildcards, keep-alive, a
3 MB download, a 100 KB POST, 100-way concurrency, fd and RSS hygiene, and
live reload. No network access.

The fd-hygiene check is the one worth keeping honest: it was written against a
real bug (a client that walked away mid-download left both sockets open until
the 60 s sweep) and has been fault-injected to confirm it still fails when the
fix is removed.
