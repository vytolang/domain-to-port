#!/bin/sh
# Integration tests: build both binaries, run the proxy against real backends,
# and drive real HTTP through it.
#
# These are end-to-end on purpose. The unit tests (t_routes, t_head) cover the
# parsing; what actually breaks in a proxy is the socket lifecycle, and that
# only shows up against a real kernel — the fd-leak this suite's "abandoned
# transfer" case checks for was invisible to every unit test.
#
# No network: every backend is a python http.server on loopback.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
VYTOC=${VYTOC:-/home/eric/voltlang/vytoc}
# The package ROOT is the directory CONTAINING this package, not this one --
# same shape as lib/ holding vyto/. Derived rather than hardcoded so moving the
# checkout needs no edit here.
MODPATH=${MODPATH:-$(cd .. && pwd)}
TMP="$ROOT/tests/tmp"
# Ports are picked free at run time rather than fixed. A fixed port makes the
# suite fail for a reason that has nothing to do with the proxy the moment
# anything else on the machine — including a previous debugging session — is
# holding it, and that failure looks exactly like a real one.
freeport() {
    python3 -c "
import socket
s = socket.socket(); s.bind(('127.0.0.1', 0))
print(s.getsockname()[1]); s.close()"
}
PORT=${PORT:-$(freeport)}
TLSPORT=${TLSPORT:-$(freeport)}
B1=${B1:-$(freeport)}     # static backend
B2=${B2:-$(freeport)}     # echo backend, threaded, keep-alive
PASS=0
FAIL=0

export VYTO_PROXY_HOME="$TMP/state"

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s: %s\n' "$1" "$2"; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

cleanup() {
    [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null
    [ -n "${S1:-}" ] && kill "$S1" 2>/dev/null
    [ -n "${S2:-}" ] && kill "$S2" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT INT TERM

rm -rf "$TMP"
mkdir -p "$TMP/state" "$TMP/www"

echo "building"
$VYTOC build src/cli_main.vt --modpath "$MODPATH" -o "$TMP/domain-to-port" >/dev/null || { echo "BUILD FAILED (cli)"; exit 1; }
$VYTOC build src/proxyd.vt   --modpath "$MODPATH" -o "$TMP/vyto-proxyd"   >/dev/null || { echo "BUILD FAILED (daemon)"; exit 1; }
DTP="$TMP/domain-to-port"

echo "unit tests"
$VYTOC run tests/t_routes.vt --modpath "$MODPATH" 2>&1 | sed 's/^/  /'
$VYTOC run tests/t_head.vt   --modpath "$MODPATH" 2>&1 | sed 's/^/  /'
$VYTOC run tests/t_hosts.vt  --modpath "$MODPATH" 2>&1 | sed 's/^/  /'
$VYTOC run tests/t_acme.vt   --modpath "$MODPATH" 2>&1 | sed 's/^/  /'
U=$($VYTOC run tests/t_routes.vt --modpath "$MODPATH" 2>&1; $VYTOC run tests/t_head.vt --modpath "$MODPATH" 2>&1; $VYTOC run tests/t_hosts.vt --modpath "$MODPATH" 2>&1; $VYTOC run tests/t_acme.vt --modpath "$MODPATH" 2>&1)
UF=$(printf '%s\n' "$U" | grep -c '^FAIL')
UP=$(printf '%s\n' "$U" | grep -c '^ok')
PASS=$((PASS+UP)); FAIL=$((FAIL+UF))

# --- backends -------------------------------------------------------------
echo '<h1>backend one</h1>' > "$TMP/www/index.html"
python3 -c "
import random; random.seed(7)
open('$TMP/www/big.bin','wb').write(bytes(random.getrandbits(8) for _ in range(3*1024*1024)))
"
BIGSUM=$(md5sum "$TMP/www/big.bin" | cut -d' ' -f1)

(cd "$TMP/www" && python3 -m http.server $B1 --bind 127.0.0.1 >/dev/null 2>&1) &
S1=$!

cat > "$TMP/echo_srv.py" <<'PYEOF'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        b = self.rfile.read(n)
        self.send_response(200)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        b = b'ka:' + self.path.encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
class T(socketserver.ThreadingTCPServer):
    daemon_threads = True; allow_reuse_address = True
T(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
python3 "$TMP/echo_srv.py" $B2 >/dev/null 2>&1 &
S2=$!
sleep 1.5

# --- routes ---------------------------------------------------------------
echo "routes"
"$DTP" -d www.example.com -p $B1 >/dev/null
"$DTP" -d echo.local      -p $B2 >/dev/null
"$DTP" -d '*.dev.local'   -p $B1 >/dev/null
"$DTP" -d dead.local      -p 9   >/dev/null   # port 9 = discard, nothing listens

# Per-domain certificates, so the SNI path is exercised by the same daemon.
mkdir -p "$TMP/certs"
for d in alpha.local beta.local; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "$TMP/certs/$d.key" -out "$TMP/certs/$d.crt" -days 30 -nodes \
        -subj "/CN=$d" -addext "subjectAltName=DNS:$d" >/dev/null 2>&1
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$TMP/certs/_.wild.local.key" -out "$TMP/certs/_.wild.local.crt" -days 30 -nodes \
    -subj "/CN=*.wild.local" -addext "subjectAltName=DNS:*.wild.local" >/dev/null 2>&1

"$DTP" -d alpha.local    -p $B1 >/dev/null
"$DTP" -d beta.local     -p $B1 >/dev/null
"$DTP" -d '*.wild.local' -p $B1 >/dev/null

"$TMP/vyto-proxyd" -p $PORT --tls --tls-port $TLSPORT --certs "$TMP/certs" --routes "$TMP/state/routes.json" >"$TMP/proxyd.log" 2>&1 &
PROXY_PID=$!
sleep 1.5

if ! kill -0 $PROXY_PID 2>/dev/null; then
    echo "PROXY FAILED TO START:"; cat "$TMP/proxyd.log"; exit 1
fi

H="http://127.0.0.1:$PORT"
echo "routing"
want "exact host routes"      "$(curl -s -m5 -H 'Host: www.example.com' $H/ | tr -d '\n')" '<h1>backend one</h1>'
want "unknown host is 404"    "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: nope.invalid' $H/)" '404'
want "dead backend is 502"    "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: dead.local' $H/)" '502'
want "wildcard matches sub"   "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: a.dev.local' $H/)" '200'
want "wildcard matches deep"  "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: x.y.dev.local' $H/)" '200'
want "wildcard excludes bare" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: dev.local' $H/)" '404'
want "host is case-insensitive" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: WWW.Example.COM' $H/)" '200'
want "host with port routes"  "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: www.example.com:8080' $H/)" '200'

echo "protocol"
want "no Host is 400" "$(printf 'GET / HTTP/1.1\r\n\r\n' | timeout 5 nc -q2 127.0.0.1 $PORT 2>/dev/null | head -1 | tr -d '\r')" 'HTTP/1.1 400 Bad Request'

SPLIT=$(timeout 8 python3 -c "
import socket,time
s=socket.create_connection(('127.0.0.1',$PORT))
s.sendall(b'GET / HTTP/1.1\r\nHost: www.exa')
time.sleep(0.4)
s.sendall(b'mple.com\r\n\r\n')
print(s.recv(100).split(b' ')[1].decode())
s.close()" 2>/dev/null)
want "header split across packets" "$SPLIT" '200'

KA=$(curl -s -m8 -H 'Host: echo.local' -o /dev/null -w '%{num_connects}' $H/a $H/b $H/c 2>/dev/null | tail -c1)
want "keep-alive reuses one connection" "$KA" '0'

echo "payloads"
curl -s -m30 -H 'Host: www.example.com' $H/big.bin -o "$TMP/got.bin"
want "3MB response is byte-identical" "$(md5sum "$TMP/got.bin" | cut -d' ' -f1)" "$BIGSUM"

python3 -c "
import random,string; random.seed(3)
open('$TMP/post.txt','w').write(''.join(random.choice(string.ascii_letters) for _ in range(100000)))"
curl -s -m15 -H 'Host: echo.local' --data-binary @"$TMP/post.txt" $H/ -o "$TMP/echoed.txt"
want "100KB POST body round-trips" "$(md5sum "$TMP/echoed.txt" | cut -d' ' -f1)" "$(md5sum "$TMP/post.txt" | cut -d' ' -f1)"

echo "concurrency"
CODES=$(seq 1 100 | xargs -P 20 -I{} curl -s -m15 -o /dev/null -w '%{http_code}\n' -H 'Host: www.example.com' $H/ | sort -u | tr -d '\n')
want "100 concurrent requests all 200" "$CODES" '200'

echo "resource hygiene"
BASE_FD=$(ls /proc/$PROXY_PID/fd 2>/dev/null | wc -l)
for i in $(seq 1 10); do
    (timeout 12 python3 -c "
import socket,time
s=socket.create_connection(('127.0.0.1',$PORT))
s.sendall(b'GET /big.bin HTTP/1.1\r\nHost: www.example.com\r\nConnection: close\r\n\r\n')
for _ in range(6):
    d=s.recv(4096)
    if not d: break
    time.sleep(0.1)
s.close()" >/dev/null 2>&1 &)
done
sleep 8
AFTER_FD=$(ls /proc/$PROXY_PID/fd 2>/dev/null | wc -l)
# The idle sweep is 60s; anything still held here is held by the teardown bug,
# not by the sweep being slow.
if [ "$AFTER_FD" -le "$((BASE_FD + 2))" ]; then
    ok "abandoned transfers release fds promptly ($BASE_FD -> $AFTER_FD)"
else
    bad "abandoned transfers release fds promptly" "fds grew $BASE_FD -> $AFTER_FD"
fi

RSS=$(grep VmRSS /proc/$PROXY_PID/status | awk '{print $2}')
seq 1 20 | xargs -P 10 -I{} curl -s -m30 -o /dev/null -H 'Host: www.example.com' $H/big.bin
RSS2=$(grep VmRSS /proc/$PROXY_PID/status | awk '{print $2}')
if [ "$RSS2" -lt "$((RSS + 8192))" ]; then
    ok "60MB of transfers do not grow RSS (${RSS}kB -> ${RSS2}kB)"
else
    bad "60MB of transfers do not grow RSS" "${RSS}kB -> ${RSS2}kB"
fi


# --- TLS -------------------------------------------------------------------
# No --cert was given, so the daemon generated a self-signed certificate at
# startup covering every routed domain. curl -k accepts it; what is being tested
# is the termination path, not the trust decision.
echo "tls"
S="https://127.0.0.1:$TLSPORT"
CURLK="curl -sk --resolve www.example.com:$TLSPORT:127.0.0.1 --resolve echo.local:$TLSPORT:127.0.0.1 --resolve nope.invalid:$TLSPORT:127.0.0.1"

want "https routes to the backend" \
    "$($CURLK -m8 https://www.example.com:$TLSPORT/ | tr -d '\n')" '<h1>backend one</h1>'
want "https unknown host is 404" \
    "$($CURLK -m8 -o /dev/null -w '%{http_code}' https://nope.invalid:$TLSPORT/)" '404'

# The generated certificate must actually name the routed domains, or a browser
# rejects it for a reason that has nothing to do with self-signing.
SAN=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:$TLSPORT -servername www.example.com 2>/dev/null \
      | openssl x509 -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1)
case "$SAN" in
    *www.example.com*) ok "generated cert names the routed domain" ;;
    *) bad "generated cert names the routed domain" "SANs were: $SAN" ;;
esac

# TLS is where a want-read/want-write mix-up shows up: a bug there survives
# small responses and hangs on large ones.
$CURLK -m40 https://www.example.com:$TLSPORT/big.bin -o "$TMP/tlsbig.bin"
want "3MB over TLS is byte-identical" "$(md5sum "$TMP/tlsbig.bin" | cut -d' ' -f1)" "$BIGSUM"

$CURLK -m20 --data-binary @"$TMP/post.txt" https://echo.local:$TLSPORT/ -o "$TMP/tlsechoed.txt"
want "100KB POST over TLS round-trips" \
    "$(md5sum "$TMP/tlsechoed.txt" | cut -d' ' -f1)" "$(md5sum "$TMP/post.txt" | cut -d' ' -f1)"

KAT=$($CURLK -m10 -o /dev/null -w '%{num_connects}' \
      https://echo.local:$TLSPORT/a https://echo.local:$TLSPORT/b 2>/dev/null | tail -c1)
want "TLS keep-alive reuses one session" "$KAT" '0'

TCODES=$(seq 1 40 | xargs -P 10 -I{} curl -sk -m20 -o /dev/null -w '%{http_code}\n' \
         --resolve www.example.com:$TLSPORT:127.0.0.1 https://www.example.com:$TLSPORT/ | sort -u | tr -d '\n')
want "40 concurrent https requests all 200" "$TCODES" '200'

# Plain HTTP must be unaffected by TLS being on — both listeners, no redirect.
want "plain http still served alongside tls" \
    "$(curl -s -m5 -H 'Host: www.example.com' $H/ | tr -d '\n')" '<h1>backend one</h1>'

TLSFD=$(ls /proc/$PROXY_PID/fd 2>/dev/null | wc -l)
for i in $(seq 1 8); do
    (timeout 12 python3 -c "
import socket,ssl
c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
s=c.wrap_socket(socket.create_connection(('127.0.0.1',$TLSPORT)),server_hostname='www.example.com')
s.sendall(b'GET /big.bin HTTP/1.1\r\nHost: www.example.com\r\nConnection: close\r\n\r\n')
for _ in range(4):
    d=s.recv(4096)
    if not d: break
s.close()" >/dev/null 2>&1 &)
done
sleep 7
TLSFD2=$(ls /proc/$PROXY_PID/fd 2>/dev/null | wc -l)
if [ "$TLSFD2" -le "$((TLSFD + 2))" ]; then
    ok "abandoned TLS transfers release fds ($TLSFD -> $TLSFD2)"
else
    bad "abandoned TLS transfers release fds" "fds grew $TLSFD -> $TLSFD2"
fi


# --- SNI -------------------------------------------------------------------
# Each domain has its own certificate, so what is being tested is that the
# handshake picks the right one from the name the client sent — and that an
# unknown name still completes against the base certificate rather than
# failing, because a TLS alert tells a developer far less than a 404 does.
echo "sni"

servedcn() {
    echo | timeout 8 openssl s_client -connect 127.0.0.1:$TLSPORT -servername "$1" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//; s/ *CN *= *//'
}

want "sni serves alpha's own certificate"  "$(servedcn alpha.local)" 'alpha.local'
want "sni serves beta's own certificate"   "$(servedcn beta.local)"  'beta.local'
want "sni serves the wildcard certificate" "$(servedcn x.wild.local)" '*.wild.local'

# A wildcard covers exactly one label, the same rule the router applies.
want "wildcard cert does not span two labels" "$(servedcn a.b.wild.local)" 'vyto-proxy local'
want "wildcard cert does not match the bare domain" "$(servedcn wild.local)" 'vyto-proxy local'
# A routed domain with no certificate of its own falls back and still works.
want "unknown sni falls back to the base cert" "$(servedcn www.example.com)" 'vyto-proxy local'

want "traffic flows over a per-domain cert" \
    "$(curl -sk -m8 --resolve alpha.local:$TLSPORT:127.0.0.1 https://alpha.local:$TLSPORT/ | tr -d '\n')" \
    '<h1>backend one</h1>'

# Certificate loading refuses a half pair and a bad path at startup, rather
# than failing later for one domain when somebody happens to visit it.
mkdir -p "$TMP/halfpair" && cp "$TMP/certs/alpha.local.crt" "$TMP/halfpair/"
"$TMP/vyto-proxyd" -p $(freeport) --tls --tls-port $(freeport) --certs "$TMP/halfpair" >"$TMP/half.log" 2>&1
HALF=$?
case "$(cat "$TMP/half.log")" in
    *"has no matching alpha.local.key"*) ok "a .crt with no .key is refused at startup" ;;
    *) bad "a .crt with no .key is refused at startup" "said: $(head -1 "$TMP/half.log")" ;;
esac
want "half a pair exits non-zero" "$HALF" '1'

"$TMP/vyto-proxyd" -p $(freeport) --tls --tls-port $(freeport) --certs "$TMP/nosuchdir" >"$TMP/nodir.log" 2>&1
case "$(cat "$TMP/nodir.log")" in
    *"no such directory"*) ok "a missing --certs directory is reported, not a panic" ;;
    *) bad "a missing --certs directory is reported, not a panic" "said: $(head -1 "$TMP/nodir.log")" ;;
esac


# --- /etc/hosts ------------------------------------------------------------
# Against a copy, never the real file: VYTO_PROXY_HOSTS redirects the target and
# also drops the sudo step, since a path the user chose is one they can write.
# Editing the machine's real /etc/hosts to prove that editing works is not a
# trade worth making.
echo "hosts"
FAKE="$TMP/fake-hosts"
printf '127.0.0.1\tlocalhost\n192.168.1.50 taken.test\n' > "$FAKE"
cp "$FAKE" "$TMP/fake-hosts.orig"
export VYTO_PROXY_HOSTS="$FAKE"

"$DTP" -d hostsy.test -p $B1 --hosts >"$TMP/h1.log" 2>&1
case "$(cat "$TMP/h1.log")" in
    *"hosts: added hostsy.test"*) ok "--hosts adds an entry" ;;
    *) bad "--hosts adds an entry" "said: $(grep hosts: "$TMP/h1.log" | head -1)" ;;
esac
grep -q "^127.0.0.1	hostsy.test	# vyto-proxy$" "$FAKE" \
    && ok "the entry is marked as ours" \
    || bad "the entry is marked as ours" "file has: $(tail -1 "$FAKE")"
grep -q "^127.0.0.1	localhost$" "$FAKE" \
    && ok "localhost survives the rewrite" \
    || bad "localhost survives the rewrite" "localhost line is gone"

# Re-running must change nothing: this is what makes the flag safe to pass
# every time rather than only on the first add.
"$DTP" -d hostsy.test -p $B1 --hosts >"$TMP/h2.log" 2>&1
case "$(cat "$TMP/h2.log")" in
    *"already up to date"*) ok "a second --hosts run is a no-op" ;;
    *) bad "a second --hosts run is a no-op" "said: $(grep hosts: "$TMP/h2.log" | head -1)" ;;
esac

# A line somebody else wrote is never touched, even for a domain we manage.
"$DTP" -d taken.test -p $B1 --hosts >"$TMP/h3.log" 2>&1
grep -q "^192.168.1.50 taken.test$" "$FAKE" \
    && ok "a hand-written entry is preserved" \
    || bad "a hand-written entry is preserved" "it was modified or removed"
case "$(cat "$TMP/h3.log")" in
    *"already has an entry written by someone else"*) ok "a shadowing entry is reported" ;;
    *) bad "a shadowing entry is reported" "no warning was printed" ;;
esac

# A wildcard cannot be expressed in a hosts file, so it must be refused loudly
# rather than written as a line that would never match.
"$DTP" -d '*.wild.test' -p $B1 --hosts >"$TMP/h4.log" 2>&1
case "$(cat "$TMP/h4.log")" in
    *"wildcard route(s) skipped"*) ok "wildcards are skipped with a reason" ;;
    *) bad "wildcards are skipped with a reason" "no wildcard notice" ;;
esac
grep -q "wild.test" "$FAKE" && bad "no wildcard line is written" "found one" \
                            || ok "no wildcard line is written"

# --dry-run reports without touching the file.
BEFORE=$(md5sum "$FAKE" | cut -d' ' -f1)
"$DTP" -d dry.test -p $B1 --hosts --dry-run >"$TMP/h5.log" 2>&1
AFTER=$(md5sum "$FAKE" | cut -d' ' -f1)
want "--dry-run leaves the file alone" "$AFTER" "$BEFORE"
case "$(cat "$TMP/h5.log")" in
    *"would add dry.test"*) ok "--dry-run says what it would do" ;;
    *) bad "--dry-run says what it would do" "said: $(grep hosts: "$TMP/h5.log" | head -1)" ;;
esac

# Removing every route must restore the file exactly.
#
# In its own state dir with its own route table: sync() reconciles against the
# WHOLE table, so with the suite's other routes still present the file would
# correctly keep an entry for each of them, and "restored" would be measuring
# the wrong thing.
ISO="$TMP/iso-state"
mkdir -p "$ISO"
printf '127.0.0.1\tlocalhost\n192.168.1.50 taken.test\n' > "$TMP/iso-hosts"
cp "$TMP/iso-hosts" "$TMP/iso-hosts.orig"
(
    export VYTO_PROXY_HOME="$ISO"
    export VYTO_PROXY_HOSTS="$TMP/iso-hosts"
    "$DTP" -d one.test -p 1234 --hosts >/dev/null 2>&1
    "$DTP" -d two.test -p 1235 --hosts >/dev/null 2>&1
    "$DTP" -d one.test --rm --hosts   >/dev/null 2>&1
    "$DTP" -d two.test --rm --hosts   >/dev/null 2>&1
)
if diff -q "$TMP/iso-hosts.orig" "$TMP/iso-hosts" >/dev/null 2>&1; then
    ok "removing every route restores the file byte-for-byte"
else
    bad "removing every route restores the file byte-for-byte" "$(diff "$TMP/iso-hosts.orig" "$TMP/iso-hosts" | head -3)"
fi

# A hosts failure must be visible to a script, not just to a reader. The route
# table is written first on purpose -- it is the source of truth, and a hosts
# problem should not undo a route edit -- so the exit status is the only thing
# that tells a caller the two ended up out of step.
#
# Driven by pointing the override at a path that cannot be written: a directory.
# That exercises the failure branch without needing sudo or a tty.
(
    export VYTO_PROXY_HOME="$TMP/failstate"
    mkdir -p "$TMP/failstate" "$TMP/adir"
    export VYTO_PROXY_HOSTS="$TMP/adir"
    "$DTP" -d fail.test -p 1236 --hosts >"$TMP/hf.log" 2>&1
    echo $? > "$TMP/hf.code"
)
# 101 is a Vyto panic. readfile() aborts on a directory and file_exists() is
# true for one, so a mistyped path used to crash rather than report.
want "a hosts failure exits non-zero (not a panic)" "$(cat "$TMP/hf.code")" '1'
case "$(cat "$TMP/hf.log")" in
    *"is a directory, not a file"*) ok "a directory as the hosts file is reported" ;;
    *) bad "a directory as the hosts file is reported" "said: $(grep hosts: "$TMP/hf.log" | head -1)" ;;
esac
case "$(cat "$TMP/hf.log")" in
    *"out of step"*) ok "a hosts failure says the two are out of step" ;;
    *) bad "a hosts failure says the two are out of step" "said: $(grep hosts: "$TMP/hf.log" | head -1)" ;;
esac
unset VYTO_PROXY_HOSTS

# --- bind failures ---------------------------------------------------------
# "cannot listen" used to always blame privilege, which sends the reader to
# setcap even when the real problem is that something else holds the port —
# the common case on a machine with Apache or nginx installed.
echo "bind failures"
BUSY=$(freeport)
python3 -c "
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $BUSY)); s.listen(1); time.sleep(12)" &
SQUAT=$!
sleep 1
"$TMP/vyto-proxyd" -p $BUSY --routes "$TMP/state/routes.json" >"$TMP/busy.log" 2>&1
BUSYCODE=$?
kill $SQUAT 2>/dev/null
want "binding an occupied port exits non-zero" "$BUSYCODE" '1'
case "$(cat "$TMP/busy.log")" in
    *"already listening on port"*) ok "an occupied port says so, not 'needs privilege'" ;;
    *) bad "an occupied port says so, not 'needs privilege'" "said: $(tail -1 "$TMP/busy.log")" ;;
esac
case "$(cat "$TMP/busy.log")" in
    *"setcap"*) bad "an occupied high port does not mention setcap" "it suggested setcap" ;;
    *) ok "an occupied high port does not mention setcap" ;;
esac


# --- ACME ------------------------------------------------------------------
# Against Pebble, Let's Encrypt's own test server: the full protocol with no
# rate limits and no public domain. Skipped when it is not installed, so the
# suite stays runnable on a machine with no Go toolchain.
#
# Pebble validates HTTP-01 against port 5002, which is why the proxy listens
# there rather than on 80 — no privilege needed.
PEBBLE="${PEBBLE:-$HOME/go/bin/pebble}"
PEBBLE_SRC=$(ls -d "$HOME"/go/pkg/mod/github.com/letsencrypt/pebble/v2@* 2>/dev/null | tail -1)
if [ -x "$PEBBLE" ] && [ -n "$PEBBLE_SRC" ]; then
    echo "acme (pebble)"
    mkdir -p "$TMP/pebble"
    cp -r "$PEBBLE_SRC/test" "$TMP/pebble/" 2>/dev/null
    chmod -R u+w "$TMP/pebble"
    ( cd "$TMP/pebble" && "$PEBBLE" -config test/config/pebble-config.json >"$TMP/pebble.log" 2>&1 ) &
    PEBBLE_PID=$!
    sleep 3

    if curl -sk -m5 https://127.0.0.1:14000/dir >/dev/null 2>&1; then
        ACMEDIR="$TMP/acmecerts"
        mkdir -p "$ACMEDIR"
        (
            export VYTO_PROXY_HOME="$TMP/acmestate"
            mkdir -p "$VYTO_PROXY_HOME"
            "$DTP" -d localhost -p $B1 >/dev/null 2>&1
            # stdbuf: the daemon's stdout is block-buffered into a file, so a
            # log-based assertion reads an empty file unless it is flushed per
            # line. The certificate checks below read the filesystem and the
            # live socket instead, which is why they passed while this did not.
            stdbuf -oL "$TMP/vyto-proxyd" -p 5002 -v --tls --tls-port 15443 \
                --certs "$ACMEDIR" --acme \
                --acme-ca https://127.0.0.1:14000/dir \
                --acme-ca-file "$TMP/pebble/test/certs/pebble.minica.pem" \
                --acme-email test@example.com >"$TMP/acmed.log" 2>&1 &
            echo $! > "$TMP/acmed.pid"
        )
        sleep 22
        ACMED_PID=$(cat "$TMP/acmed.pid" 2>/dev/null)

        if [ -f "$ACMEDIR/localhost.crt" ]; then
            ok "the daemon obtains a certificate by itself"
        else
            bad "the daemon obtains a certificate by itself" "$(grep acme: "$TMP/acmed.log" | tail -1)"
        fi

        # The proxy answering its own challenge is the whole trick: it is
        # single-threaded, so the issuance has to keep serving while it waits.
        case "$(cat "$TMP/acmed.log")" in
            *"acme challenge"*) ok "the proxy answers its own http-01 challenge" ;;
            *) bad "the proxy answers its own http-01 challenge" "no challenge was served" ;;
        esac

        if [ -f "$ACMEDIR/localhost.crt" ]; then
            ISSUER=$(openssl x509 -in "$ACMEDIR/localhost.crt" -noout -issuer 2>/dev/null)
            case "$ISSUER" in
                *Pebble*) ok "the certificate really came from the CA" ;;
                *) bad "the certificate really came from the CA" "issuer was: $ISSUER" ;;
            esac

            CPUB=$(openssl x509 -in "$ACMEDIR/localhost.crt" -noout -pubkey 2>/dev/null | openssl md5)
            KPUB=$(openssl pkey -in "$ACMEDIR/localhost.key" -pubout 2>/dev/null | openssl md5)
            want "the saved key matches the certificate" "$CPUB" "$KPUB"

            # A certificate nobody serves is not a renewal: the SNI table has to
            # be rebuilt, or this would need a restart to take effect.
            SERVED=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:15443 -servername localhost 2>/dev/null \
                     | openssl x509 -noout -issuer 2>/dev/null)
            case "$SERVED" in
                *Pebble*) ok "the new certificate is served without a restart" ;;
                *) bad "the new certificate is served without a restart" "serving: $SERVED" ;;
            esac
        fi

        [ -n "$ACMED_PID" ] && kill "$ACMED_PID" 2>/dev/null
    else
        echo "  (pebble did not start; skipping)"
    fi
    kill $PEBBLE_PID 2>/dev/null
else
    echo "acme (pebble not installed - skipping end-to-end ACME)"
fi

echo "live reload"
want "unrouted before add" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: late.local' $H/)" '404'
RELOAD=$("$DTP" -d late.local -p $B1 | tail -1 | tr -d ' ')
want "cli reports reloaded" "$RELOAD" 'reloaded'
want "routed immediately after add" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: late.local' $H/)" '200'
"$DTP" -d late.local --rm >/dev/null
want "unrouted immediately after rm" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: late.local' $H/)" '404'

# A broken routes file must not take the running proxy down.
cp "$TMP/state/routes.json" "$TMP/routes.bak"
echo '{ this is not json' > "$TMP/state/routes.json"
kill -HUP $PROXY_PID
sleep 0.7
want "broken routes file keeps the old table" "$(curl -s -m5 -o /dev/null -w '%{http_code}' -H 'Host: www.example.com' $H/)" '200'
cp "$TMP/routes.bak" "$TMP/state/routes.json"
kill -HUP $PROXY_PID
sleep 0.5

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
