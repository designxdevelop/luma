#!/bin/sh
# Creates Luma's Play upload key outside the repo. keytool asks for the password;
# save it in 1Password, then build with LUMA_UPLOAD_KEYSTORE/LUMA_UPLOAD_PASSWORD (docs/PLAY.md).
set -e
KEYSTORE="${1:-$HOME/.android/luma-upload.jks}"
[ -e "$KEYSTORE" ] && { echo "$KEYSTORE already exists; not overwriting." >&2; exit 1; }
mkdir -p "$(dirname "$KEYSTORE")"
keytool -genkeypair -v -keystore "$KEYSTORE" -alias luma-upload -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=Design X Develop LLC, O=Design X Develop LLC, C=US"
chmod 600 "$KEYSTORE"
echo "Created $KEYSTORE. Back it up: Play needs a reset request if it's lost."
