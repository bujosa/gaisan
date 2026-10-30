#!/bin/zsh
set -euo pipefail
name="Gaisan Local"
if security find-identity -p codesigning | grep -q "$name"; then
  exit 0
fi
dir="${HOME}/Library/Application Support/Gaisan/signing"
mkdir -p "$dir"
chmod 700 "$dir"
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=${name}" \
  -keyout "$dir/gaisan.key" -out "$dir/gaisan.crt" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -legacy -export -inkey "$dir/gaisan.key" -in "$dir/gaisan.crt" -out "$dir/gaisan.p12" -passout pass:gaisan >/dev/null 2>&1
security import "$dir/gaisan.p12" -k "${HOME}/Library/Keychains/login.keychain-db" -P gaisan -T /usr/bin/codesign -A
rm -f "$dir/gaisan.p12"
echo "Created signing identity: $name"
