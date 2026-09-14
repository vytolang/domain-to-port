# domain-to-port

Map a domain to a local port. Instantly.

```sh
domain-to-port -d www.example.com -p 8099
```

That is the whole interface. The route is live before the command returns — no
restart, no config reload dance, no dropped connections.

Two binaries: `domain-to-port` is the command above, and `vyto-proxyd` is the
daemon that does the routing. The daemon is 194 KB and links libc, OpenSSL and
libcurl — a reverse proxy with the parts you actually use on a dev machine and
none of the parts you don't.

## Install

### A prebuilt binary

```sh
curl -LO https://github.com/vytolang/domain-to-port/releases/latest/download/domain-to-port-linux-x86_64.tar.gz
tar xzf domain-to-port-linux-x86_64.tar.gz
cd domain-to-port-*-linux-x86_64
sudo install -m 755 domain-to-port vyto-proxyd /usr/local/bin/
sudo setcap cap_net_bind_service=+ep /usr/local/bin/vyto-proxyd
```

Needs glibc 2.35+, OpenSSL 3.x and libcurl — Ubuntu 22.04+, Debian 12+,
Fedora 36+ or anything newer ships all three. Check a release's `.sha256` before trusting the
download.

### From source

Needs the [Vyto compiler](https://github.com/vytolang/vyto) and OpenSSL
headers. Vyto compiles to C and shells out to a host C compiler, so there is no
other toolchain to install.

```sh
git clone https://github.com/vytolang/domain-to-port
cd domain-to-port
make && make install                 # -> ~/.local/bin
sudo setcap cap_net_bind_service=+ep ~/.local/bin/vyto-proxyd
```

`make` finds `vytoc` on your `PATH`, or via `$VYTO_HOME`, or you can point at a
checkout: `make VYTO_ROOT=/path/to/vyto`. `PREFIX` and `DESTDIR` work as usual.

**A package root contains packages**, so this has to sit inside one — `make`
derives the root as the parent directory. Cloning into `~/src/domain-to-port`
makes `~/src` the root, which is what you want; cloning into `/` would not.

### After either

The `setcap` grants the one privilege a proxy needs — binding a port below 1024
— without the daemon ever running as root. Do it once, and again after any
upgrade that replaces the binary.

If something else already owns `:80` — Apache and nginx usually do — see
[Port 80](#port-80).

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
domain-to-port -d '*.dev.test'    -p 3000     # wildcard
domain-to-port -d www.example.com --rm        # remove
domain-to-port --list                         # show the table
```

For local development you also need the name to resolve. Pass `--hosts` and the
tool writes the `/etc/hosts` entry too:

```sh
domain-to-port -d www.example.com -p 8099 --hosts
```

It asks for `sudo` only for that step, and only when there is something to
change. See [Hosts entries](#hosts-entries) for what it will and will not
touch.

## Port 80

The whole point is typing `http://myapp.test/` with no port in it, which means
the proxy has to own `:80`. Two things stand between you and that.

### 1. Binding a low port

Ports below 1024 need a capability. Grant it once, to the binary:

```sh
sudo setcap cap_net_bind_service=+ep ~/.local/bin/vyto-proxyd
```

The daemon then binds `:80` while running as you. It is attached to the file,
so re-grant it after any reinstall that replaces the binary.

Without it, `vyto-proxyd` exits with the setcap line in the error — but only
when privilege is actually the problem. If the port is simply taken, it says
that instead, because on most machines both are true at once and being sent to
`setcap` first just delays finding the real cause.

### 2. Something else is probably already there

On a machine that has ever done web development, `:80` is usually taken —
Apache and nginx both install enabled and start at boot. Check before you
wonder why nothing works:

```sh
ss -lntp | grep ':80 '
sudo ss -lntp | grep ':80 '    # add sudo to see WHICH process
```

Without `sudo`, `ss` shows that the port is taken but not by what — it cannot
read another user's process names, and a root-owned web server is the usual
culprit. `curl -sI http://127.0.0.1/ | grep -i ^server` names it too.

If that prints a line, the process in it owns the port, and a browser hitting
`http://myapp.test/` reaches **that**, not vyto-proxy. The symptom is
confusing precisely because it half-works: the hostname resolves (your
`/etc/hosts` entry is fine) and something answers, so it looks like a routing
bug rather than a port conflict. A default Apache page is the usual tell.

You have three ways out.

**Run vyto-proxy somewhere else.** Simplest, and costs you the clean URL:

```sh
vyto-proxyd -p 8080
# http://myapp.test:8080/
```

**Move the other server and put vyto-proxy in front.** This is the arrangement
the tool is built for — one thing owning `:80`, routing by name to everything
else, including the server you displaced. For Apache:

```sh
# /etc/apache2/ports.conf      Listen 80  ->  Listen 8081
# /etc/apache2/sites-enabled/*.conf   <VirtualHost *:80>  ->  <VirtualHost *:8081>
sudo systemctl restart apache2

sudo setcap cap_net_bind_service=+ep ~/.local/bin/vyto-proxyd
domain-to-port -d existing-site.test -p 8081 --hosts    # keep it reachable
vyto-proxyd
```

nginx is the same shape: change `listen 80;` to `listen 8081;` in
`/etc/nginx/sites-enabled/*`, reload, then route a domain at 8081.

Give every vhost you moved its own route, or it becomes unreachable the moment
vyto-proxy takes the port.

**Stop the other server**, if you were not using it:

```sh
sudo systemctl disable --now apache2
```

### Checking it took

```sh
sudo ss -lntp | grep ':80 '   # should now name vyto-proxyd
curl -sI http://myapp.test/   # should reach your backend, not a default page
```

`vyto-proxyd -v` logs every routing decision, which is the quickest way to tell
"the request never arrived" from "it arrived and had nowhere to go".

## What it does

- **Routes on the `Host` header** — exact match, or `*.example.com` wildcards
  where the longest match wins.
- **Reloads live.** The CLI writes the table and signals the daemon; in-flight
  connections are untouched.
- **Writes the `/etc/hosts` entry too**, with `--hosts`, so the name resolves
  as well as routes.
- **Explains itself when a backend is down.** A 502 that names the domain and
  the port beats a browser error page with nothing in it.
- **Passes anything through.** Once a connection is routed it is a byte pipe,
  so WebSocket upgrades, streaming responses, uploads and HTTP methods this
  proxy has never heard of all work without it understanding them.
- **Terminates TLS** with `--tls`, generates its own certificate if you have
  none, and serves a per-domain certificate via SNI when you do.
- **Gets real certificates** from Let's Encrypt with `--acme`, answering the
  challenge itself and renewing on its own.

Measured on the test suite: a 3 MB response arrives byte-identical, 100
concurrent requests all succeed, and 60 MB of transfers move the daemon's RSS
by **0 kB**.

## Hosts entries

`--hosts` keeps `/etc/hosts` in step with the route table. It is opt-in: without
the flag nothing outside the project is ever touched.

```sh
domain-to-port -d www.example.com -p 8099 --hosts     # add the entry too
domain-to-port -d www.example.com --rm --hosts        # and take it away again
domain-to-port -d www.example.com -p 8099 --hosts --dry-run
```

Entries it writes are marked:

```
127.0.0.1	www.example.com	# vyto-proxy
```

**It only ever changes its own lines.** A line without that marker belongs to
you or to another program and is copied through untouched, even when it names
the same domain — in which case you get a warning, because that line comes
first in the file and the first match wins, so your route would not be reached.
Deleting it is not the tool's call to make; telling you is.

Removing every route the tool added restores the file byte-for-byte.

The whole file is rewritten through a temp file and installed atomically, and a
result that somehow lost `localhost` is refused rather than written — a
half-written `/etc/hosts` is a machine that cannot resolve anything, including
the tools you would use to fix it.

`sudo` is invoked for the install step alone, and only when something actually
changes. The daemon never needs root for this; nothing here runs privileged for
longer than one `install` command.

If the hosts update fails — sudo declined, or no terminal to ask for a password
on, which is what happens in a script — the command exits non-zero and says so.
The route itself is still written, because the route table is the source of
truth and a hosts problem should not undo an edit you asked for; re-run with
`--hosts` to reconcile the two.

**Wildcards are skipped.** `/etc/hosts` matches literal names only, so a route
like `*.dev.test` gets a warning rather than a line that could never match.
For wildcards you need a real resolver — dnsmasq with
`address=/dev.test/127.0.0.1`, or systemd-resolved — or just list the names
you actually use.

### Pick the right suffix

Use **`.test`**. It is reserved by RFC 6761 for exactly this and will never be
delegated.

Avoid **`.local`**: it belongs to mDNS. On a machine running avahi — which is
most Linux desktops, including the one this was developed on — `nsswitch.conf`
typically reads `hosts: files mdns4_minimal [NOTFOUND=return] dns`. A hosts
entry still wins, because `files` comes first, but anything that falls past it
stops at mDNS instead of reaching DNS, and `.local` names you did not put in
the file resolve to link-local addresses rather than loopback. The examples in this README use `.test` throughout for that reason.

Also fine: `.localhost`, and any domain you actually control.

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
certs/_.dev.test.crt        certs/_.dev.test.key      ->  *.dev.test
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

### Real certificates, automatically

`--acme` gets certificates from Let's Encrypt and renews them, with no cron
entry and nothing to remember:

```sh
vyto-proxyd --tls --certs ./certs --acme --acme-email you@example.com
```

Use staging until it works. Production rate limits lock you out for a week, and
a staging certificate proves the whole flow without spending that budget:

```sh
vyto-proxyd --tls --certs ./certs --acme --acme-staging --acme-email you@example.com
```

Issued certificates land in `--certs` under the same `<domain>.crt`/`.key`
names a hand-placed one uses, so the two are indistinguishable to everything
else and you can mix them freely.

**The proxy answers its own challenge.** Let's Encrypt fetches
`http://<domain>/.well-known/acme-challenge/<token>`, and the proxy is already
the thing listening there, so there is no webroot to configure and no second
server to run. That also means the requirements are just:

- the domain resolves publicly to this machine
- port 80 reaches the proxy from the internet
- `--certs` is writable

Renewal is checked daily and starts at 30 days of remaining life, which leaves
thirty chances to succeed before anything expires. A new certificate is loaded
without a restart. A renewal that fails leaves the existing certificate serving
and logs why — a certificate with a fortnight left is worth more than a correct
error message.

**Wildcards are not covered.** `*.example.com` needs DNS-01, which means
credentials for your DNS provider; `--acme` refuses one with that reason rather
than failing obscurely half a minute later.

The account key is written once to `<certs>/account.key` and reused. It *is*
the account as far as the CA is concerned, so keep it: a new key is a new
account with its own rate-limit budget.

For a private or test ACME server, `--acme-ca` points at its directory and
`--acme-ca-file` trusts its CA. There is deliberately no way to switch
certificate verification off.

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

A direction stops *reading* when the buffer it feeds is full, so a fast backend cannot make the proxy hold
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
| `src/hosts.vt` | /etc/hosts reconciliation, marked lines only |
| `src/acme.vt` | the ACME protocol: orders, challenges, issuance |
| `src/jws.vt` | the account key and the JWS every request is signed with |
| `src/challenge.vt` | live http-01 tokens, answered before routing |
| `src/certstore.vt` | certificates on disk, and when to renew them |
| `src/autocert.vt` | issuance and renewal while the proxy runs |
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

**Nothing here takes a port away from another program.** If Apache or nginx
holds `:80`, vyto-proxy refuses to start and says so; it will not stop a service
for you. Moving the other server is a deliberate decision about a machine the
tool does not own — see [Port 80](#port-80).

Idle connections are dropped after 60 s, at most 256 at a time, header blocks
capped at 16 KB.

## Test

```sh
make test
```

154 checks, no network access, every port picked free at run time so the suite
never fights whatever else is on the machine.

Unit tests cover the route table, the HTTP header parser, the `/etc/hosts`
rewriter and the ACME crypto. Everything else runs end to end against real
backends on loopback:

| Area | What is checked |
|---|---|
| routing | exact hosts, wildcards, case, ports, 400/404/502 |
| protocol | keep-alive, headers split across packets, a 3 MB download, a 100 KB POST |
| load | 100 concurrent requests, fd and RSS hygiene under abandoned transfers |
| TLS | the same payloads and concurrency again, plus SNI serving three distinct certificates |
| hosts | reconciliation against a copy — never the real file, `$VYTO_PROXY_HOSTS` redirects it |
| ACME | a full issuance against Pebble: the daemon obtains a certificate, answers its own challenge, and serves it without a restart |

The ACME section is skipped when Pebble is absent, so the suite runs with no Go
toolchain:

```sh
go install github.com/letsencrypt/pebble/v2/cmd/pebble@latest
```

Several checks have been fault-injected — the fix deliberately removed to
confirm the test fails without it. A test of this shape passes trivially the
moment it stops finding anything, so the ones guarding real bugs earn it:

- **fd hygiene.** A client that walked away mid-download left both sockets open
  until the 60 s sweep. Removing the fix: fds grow 11 → 31.
- **the TLS seam.** Reading the raw socket instead of the SSL object hands the
  parser ciphertext, and hangs only on the TLS path. Removing it: 63 passed,
  7 failed, plain HTTP untouched.
- **SNI selection.** Removing the context switch: 77 passed, 3 failed — exactly
  the three "serves its own certificate" checks.

## Contributing

Issues and pull requests are welcome. `make test` should be green before and
after your change; if you are touching the proxy loop, run it with Pebble
installed so the ACME path is exercised rather than skipped.

The code is commented for *why*, not *what* — if a line exists because of a bug
that was hard to find, the comment says so. Several of them are the only record
of a failure that took hours to diagnose, so please keep that style.
