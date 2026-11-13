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

apk add --no-cache openssl-libs-static zlib-static ngircd python3 >/dev/null 2>&1
(cd cmd/soja && gprbuild -q -P soja.gpr) >&2
(cd cmd/sojadb && gprbuild -q -P sojadb.gpr) >&2

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

cat > "$D/soja.conf" <<EOT
listen irc+insecure://127.0.0.1:6697
hostname soja.example.net
db sqlite3 $D/soja.db
EOT
export SOJA_BIN="$PWD/cmd/soja/soja" SOJA_CONF="$D/soja.conf" E2E_DIR="$D"

printf 'secret\n' | cmd/sojadb/sojadb -config "$D/soja.conf" create-user alice 2>/dev/null

python3 tests/e2e_scenario.py
