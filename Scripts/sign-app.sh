#!/bin/zsh
set -euo pipefail
umask 077

APP="${1:?Usage: sign-app.sh /path/to/Wordlinks.app}"
IDENTITY="${WORDLINKS_SIGNING_IDENTITY:-}"

# Serialize certificate setup and keychain unlock/sign/lock across checkouts.
# Keep the lock outside CodeSigning so first-time setup can detect its absence.
SIGNING_PARENT="$HOME/Library/Application Support/ReadingToolDaily"
mkdir -p "$SIGNING_PARENT"
touch "$SIGNING_PARENT/.code-signing.lock"
zmodload zsh/system
if ! zsystem flock -t 30 -f SIGNING_LOCK_FD "$SIGNING_PARENT/.code-signing.lock"; then
    printf 'Timed out waiting for another Wordlinks signing operation.\n' >&2
    exit 1
fi

if [[ -n "$IDENTITY" ]]; then
    if [[ "$IDENTITY" == "-" ]]; then
        printf 'An ad-hoc signature cannot preserve Keychain authorization across builds.\n' >&2
        exit 1
    fi
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
    /usr/bin/codesign --verify --strict "$APP"
    exit 0
fi

# Keep one identity outside the checkout and build products. A self-signed
# certificate is sufficient for Keychain identity; no root trust is installed.
SIGNING_DIR="$SIGNING_PARENT/CodeSigning"
KEYCHAIN="$SIGNING_DIR/wordlinks-signing.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
IDENTITY_FILE="$SIGNING_DIR/certificate-sha1"
SIGNING_TEMP=""

cleanup() {
    local result=$?
    trap - EXIT
    if [[ -e "$KEYCHAIN" ]]; then
        /usr/bin/security lock-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SIGNING_TEMP" ]]; then
        rm -rf -- "$SIGNING_TEMP"
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if [[ ! -e "$SIGNING_DIR" ]]; then
    mkdir -p "${SIGNING_DIR:h}"
    mkdir -m 700 "$SIGNING_DIR"
    SIGNING_TEMP="$(mktemp -d "$SIGNING_DIR/setup.XXXXXX")"
    /usr/bin/openssl rand -hex 32 > "$PASSWORD_FILE"
    PASSWORD="$(cat "$PASSWORD_FILE")"
    /usr/bin/security create-keychain -p "$PASSWORD" "$KEYCHAIN"

    cat > "$SIGNING_TEMP/certificate.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = name
x509_extensions = extensions
[name]
CN = Wordlinks Local Code Signing
O = Wordlinks Local Development
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CONFIG
    /usr/bin/openssl req -new -newkey rsa:2048 -x509 -nodes -days 3650 \
        -config "$SIGNING_TEMP/certificate.cnf" \
        -keyout "$SIGNING_TEMP/private-key.pem" \
        -out "$SIGNING_TEMP/certificate.pem" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export \
        -inkey "$SIGNING_TEMP/private-key.pem" -in "$SIGNING_TEMP/certificate.pem" \
        -out "$SIGNING_TEMP/identity.p12" -passout "file:$PASSWORD_FILE" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    # Only codesign can use this non-extractable private key without a prompt.
    # This dedicated keychain contains no application credentials.
    /usr/bin/security import "$SIGNING_TEMP/identity.p12" -k "$KEYCHAIN" \
        -f pkcs12 -P "$PASSWORD" -x -T /usr/bin/codesign >/dev/null
    IDENTITY="$(/usr/bin/openssl x509 -in "$SIGNING_TEMP/certificate.pem" \
        -noout -fingerprint -sha1)"
    IDENTITY="${IDENTITY##*=}"
    IDENTITY="${IDENTITY//:/}"
    printf '%s\n' "$IDENTITY" > "$IDENTITY_FILE"
fi

# An interrupted setup or lost identity must fail instead of silently rotating
# the certificate and invalidating the user's existing Keychain authorization.
if [[ ! -f "$KEYCHAIN" || ! -f "$PASSWORD_FILE" || ! -f "$IDENTITY_FILE" ]]; then
    printf 'Local signing identity is incomplete at %s; restore it before rebuilding.\n' "$SIGNING_DIR" >&2
    exit 1
fi
chmod 700 "$SIGNING_DIR"
chmod 600 "$KEYCHAIN" "$PASSWORD_FILE" "$IDENTITY_FILE"
PASSWORD="$(cat "$PASSWORD_FILE")"
IDENTITY="$(cat "$IDENTITY_FILE")"
if [[ ! "$IDENTITY" =~ '^[0-9A-Fa-f]{40}$' || -z "$PASSWORD" ]]; then
    printf 'Local signing identity metadata is invalid at %s.\n' "$SIGNING_DIR" >&2
    exit 1
fi
/usr/bin/security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
if [[ "$(/usr/bin/security find-identity "$KEYCHAIN")" != *"$IDENTITY"* ]]; then
    printf 'The saved Wordlinks signing certificate is missing; refusing to replace it.\n' >&2
    exit 1
fi
/usr/bin/codesign --force --keychain "$KEYCHAIN" --sign "$IDENTITY" \
    --timestamp=none "$APP"
/usr/bin/codesign --verify --strict "$APP"
