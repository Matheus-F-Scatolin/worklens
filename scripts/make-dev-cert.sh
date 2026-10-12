#!/usr/bin/env bash
# Creates the self-signed "Worklens Dev" code-signing certificate that `make sign` looks for.
#
# macOS ties Screen Recording and Accessibility to the code signature. An ad-hoc signature ("-")
# is a different signature every time, so without a certificate every rebuild is a brand-new app
# to TCC and both grants have to be given again — which is also why `AutoUpdatePolicy` refuses to
# auto-update an ad-hoc build. The README used to ask for an eight-step trip through Keychain
# Access; this is that trip, scripted, with the two steps the wizard leaves out.
#
# Nothing here needs an Apple Developer account: this certificate is for building from source.
# A release build would use a Developer ID, which this project does not have.
#
# Unrelated to the Keychain *partition list* decision in docs/decisions.md:95-118 — that dropped
# signing the CLI binary as a fix for the Google token prompt (solved with GOOGLE_TOKEN_STORE=file).
# This is about TCC grants and the app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME="${SIGN_IDENTITY:-Worklens Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# LibreSSL, deliberately: OpenSSL 3 from Homebrew writes a PKCS#12 with PBKDF2/AES that
# `security import` rejects, and $PATH may well have one.
OPENSSL=/usr/bin/openssl

if [[ ! -f "$KEYCHAIN" ]]; then
  echo "error: no login keychain at $KEYCHAIN" >&2
  exit 1
fi

# Idempotent: `find-identity -v` lists only identities codesign will actually accept, so this is
# the same question `sign.sh` asks, and re-running after a success is a no-op.
if security find-identity -v -p codesigning | grep -Fq "\"$NAME\""; then
  echo "\"$NAME\" is already installed and trusted — nothing to do."
  security find-identity -v -p codesigning | grep -F "\"$NAME\""
  exit 0
fi

cat <<EOF
This creates a self-signed code-signing certificate called "$NAME" in your login keychain,
so Worklens keeps its Screen Recording and Accessibility grants across rebuilds.

You will be asked for:
  • your login password, typed here, for the key's partition list (without it codesign
    raises a keychain dialog on every build, which would also wedge unattended auto-updates)
  • an authentication prompt from macOS, to mark the certificate as trusted for code signing

EOF

WORK=$(mktemp -d)
# The private key is on disk for a few seconds. It leaves with the shell, whatever happens.
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# A config file rather than -addext: LibreSSL's support for -addext has varied, and [req]'s
# x509_extensions is understood by every version macOS has shipped.
cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = codesign

[ dn ]
CN = $NAME

[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> generating the key and certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The passphrase only has to survive the next command.
P12PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$P12PASS"

echo "==> importing into the login keychain"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# `-T` alone is not enough on modern macOS: the new key's partition list still stops codesign,
# and the dialog it raises is the one #36 spent a day on in another guise. Scoped to this key by
# label, so no other item's partitions move.
if [[ -t 0 ]]; then
  echo
  read -rsp "login password (for the key's partition list, not shown): " LOGIN_PASSWORD
  echo
  if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" \
      -k "$LOGIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "partition list set"
  else
    echo "warning: could not set the key's partition list — the first 'make sign' will raise a" >&2
    echo "         keychain dialog; click \"Always Allow\" there and it will not come back." >&2
  fi
  unset LOGIN_PASSWORD
else
  echo "warning: not a terminal, so the partition list was left alone — the first 'make sign'" >&2
  echo "         will raise a keychain dialog; click \"Always Allow\"." >&2
fi

echo "==> trusting it for code signing (macOS will ask you to authenticate)"
# User trust domain: no -d, so this needs no admin rights and touches nothing system-wide.
# codeSign only — the certificate has no business being trusted for anything else.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -Fq "\"$NAME\""; then
  security find-identity -v -p codesigning | grep -F "\"$NAME\""
  cat <<EOF

Done. Now: make bundle sign run

macOS sees a signature it has never seen before, so it will ask for Screen Recording and
Accessibility one more time. That is the last time — from here the signature stops changing.
EOF
else
  echo "error: the certificate was created but codesign will not accept it yet." >&2
  echo "       'security find-identity -v -p codesigning' should list \"$NAME\";" >&2
  echo "       if it does not, the trust step was cancelled. Re-run this script." >&2
  exit 1
fi
