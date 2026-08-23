#!/usr/bin/env bash
# requests 2.2.1 ships a `staticssl` configuration whose OpenSSL adapter is
# missing SSL_CTX_set_keylog_callback, which streams.d calls unconditionally.
# The static build therefore fails to compile upstream. This adds the one
# missing binding to the fetched copy so `--config=static` works.
#
# Remove this script once the fix lands upstream:
#   https://github.com/ikod/dlang-requests
set -euo pipefail

adapter="$(find "${DUB_HOME:-$HOME/.dub}/packages" -path '*/requests/*/source/requests/ssl_adapter_static.d' 2>/dev/null | head -1)"
if [ -z "$adapter" ]; then
    echo "requests source not found; run 'dub upgrade' first" >&2
    exit 1
fi

if grep -q 'SSL_CTX_set_keylog_callback' "$adapter"; then
    echo "requests static adapter already patched"
    exit 0
fi

# The alias inside `struct openssl`, and the extern(C) prototype it points at.
sed -i \
    -e 's|^\( *\)alias SSL_CTX_set_verify = \.SSL_CTX_set_verify;|\1alias SSL_CTX_set_verify = .SSL_CTX_set_verify;\n\1alias SSL_CTX_set_keylog_callback = .SSL_CTX_set_keylog_callback;|' \
    -e 's|^\( *\)static void SSL_CTX_set_verify(SSL_CTX\* ctx, int mode, void\* callback) @nogc nothrow;|\1static void SSL_CTX_set_verify(SSL_CTX* ctx, int mode, void* callback) @nogc nothrow;\n\1static void SSL_CTX_set_keylog_callback(SSL_CTX* ctx, void* callback) @nogc nothrow;|' \
    "$adapter"

grep -q 'SSL_CTX_set_keylog_callback' "$adapter" || {
    echo "failed to patch $adapter" >&2
    exit 1
}
echo "patched $adapter"
