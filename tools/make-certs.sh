#!/bin/sh
# tools/make-certs.sh — certificates for the registry checks.
#
#   sh tools/make-certs.sh <dir>
#
# Two authorities, not one. The gate has to show three things and the third
# needs an authority the guest does NOT have: a registry it may speak to in the
# clear, a registry whose certificate checks out, and a registry whose
# certificate does not. With one CA the third is unaskable.
set -u
d="${1:?usage: make-certs.sh <dir>}"
mkdir -p "$d"
for who in trusted untrusted; do
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/$who-ca.key" -out "$d/$who-ca.pem" \
    -days 3650 -subj "/CN=mvm $who CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$d/$who.key" -out "$d/$who.csr" \
    -subj "/CN=127.0.0.1" 2>/dev/null
  # An IP, not a name: the guest has no resolver, so a registry is reached by
  # address and the certificate has to say so.
  printf "subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\n" > "$d/$who.ext"
  openssl x509 -req -in "$d/$who.csr" -CA "$d/$who-ca.pem" -CAkey "$d/$who-ca.key" \
    -CAcreateserial -out "$d/$who.pem" -days 3650 -extfile "$d/$who.ext" 2>/dev/null
  [ -s "$d/$who.pem" ] || { echo "make-certs.sh: $who certificate is empty" >&2; exit 1; }
done
openssl x509 -in "$d/trusted.pem" -noout -text | grep -q "IP Address:127.0.0.1" \
  || { echo "make-certs.sh: the certificate has no IP SAN" >&2; exit 1; }
ls -1 "$d"/*.pem
