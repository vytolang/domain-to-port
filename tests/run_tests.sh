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
$VYTOC build src/cli_main.vt --modpath /home/eric -o "$TMP/domain-to-port" >/dev/null || { echo "BUILD FAILED (cli)"; exit 1; }
$VYTOC build src/proxyd.vt   --modpath /home/eric -o "$TMP/vyto-proxyd"   >/dev/null || { echo "BUILD FAILED (daemon)"; exit 1; }
DTP="$TMP/domain-to-port"

echo "unit tests"
$VYTOC run tests/t_routes.vt --modpath /home/eric 2>&1 | sed 's/^/  /'
$VYTOC run tests/t_head.vt   --modpath /home/eric 2>&1 | sed 's/^/  /'
U=$($VYTOC run tests/t_routes.vt --modpath /home/eric 2>&1; $VYTOC run tests/t_head.vt --modpath /home/eric 2>&1)
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

"$TMP/vyto-proxyd" -p $PORT --tls --tls-port $TLSPORT --routes "$TMP/state/routes.json" >"$TMP/proxyd.log" 2>&1 &
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
