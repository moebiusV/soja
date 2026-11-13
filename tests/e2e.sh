#!/bin/sh
# End to end: soja in front of a real IRC server (ngircd), inside the
# ada-toolchain container.
#
#   docker run --rm -v "$PWD":/work -w /work ada-toolchain:edge-full \
#       sh tests/e2e.sh
#
# Builds soja and sojadb (static OpenSSL), starts ngircd and soja, and runs
# the scenario in tests/e2e_scenario.py.
set -eu

apk add --no-cache openssl-libs-static zlib-static ngircd python3 openssl >/dev/null 2>&1
(cd cmd/soja && gprbuild -q -P soja.gpr) >&2
(cd cmd/sojadb && gprbuild -q -P sojadb.gpr) >&2
(cd cmd/sojuctl && gprbuild -q -P sojuctl.gpr) >&2

D=$(mktemp -d)
trap 'kill $(cat "$D"/*.pid 2>/dev/null) 2>/dev/null || true' EXIT

cat > "$D/ngircd.conf" <<EOT
[Global]
Name = irc.example.net
Info = test
Listen = 127.0.0.1
Ports = 6667
PidFile = $D/ngircd.pid
ServerUID = 0
ServerGID = 0
[Limit]
MaxConnectionsIP = 0
[Options]
PAM = no
[Channel]
Name = #boot
EOT
ngircd -n -f "$D/ngircd.conf" > "$D/ngircd.log" 2>&1 &
echo $! > "$D/ngircd.pid"

# Two self-signed certificates, for the certificate reload check.
for n in a b; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=soja-$n" \
    -keyout "$D/$n.key" -out "$D/$n.crt" 2>/dev/null
done
cp "$D/a.crt" "$D/tls.crt"; cp "$D/a.key" "$D/tls.key"

# STORE=db (default) or fs: which message store to run the scenario with.
STORE=${STORE:-db}
if [ "$STORE" = fs ]; then STORE_LINE="message-store fs $D/logs"; else STORE_LINE="message-store db"; fi
export E2E_STORE="$STORE"

cat > "$D/soja.conf" <<EOT
listen irc+insecure://127.0.0.1:6697
listen ident://127.0.0.1:1130
listen unix+admin://$D/admin.sock
listen unix://$D/irc.sock
listen ircs://127.0.0.1:6698
listen ws+insecure://127.0.0.1:8081
listen http+insecure://127.0.0.1:8082
listen wss://127.0.0.1:8443
listen ws+unix://$D/ws.sock
http-origin *.allowed.example
tls $D/tls.crt $D/tls.key
hostname soja.example.net
$STORE_LINE
accept-proxy-ip localhost
db sqlite3 $D/soja.db
EOT
export SOJUCTL_BIN="$PWD/cmd/sojuctl/sojuctl" SOJA_BIN="$PWD/cmd/soja/soja" SOJA_CONF="$D/soja.conf" E2E_DIR="$D"

printf 'secret\n' | cmd/sojadb/sojadb -config "$D/soja.conf" create-user alice 2>/dev/null

python3 tests/e2e_scenario.py
