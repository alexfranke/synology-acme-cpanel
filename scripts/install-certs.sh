#!/bin/sh

DOMAIN="$1"

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 domain"
    exit 1
fi

CPUSER="${CPANEL_USER:?CPANEL_USER is not set}"
CPTOKEN="${CPANEL_API_TOKEN:?CPANEL_API_TOKEN is not set}"
HOST="${CPANEL_HOST:?CPANEL_HOST is not set}"

CERT="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"
KEY="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
CA="/acme.sh/${DOMAIN}_ecc/ca.cer"

if [ ! -f "$CERT" ] || [ ! -f "$KEY" ] || [ ! -f "$CA" ]; then
    echo "ERROR: Certificate files not found for $DOMAIN"
    exit 1
fi

echo "Installing certificate for $DOMAIN..."

curl -sS \
  -H "Authorization: cpanel ${CPUSER}:${CPTOKEN}" \
  --data-urlencode "domain=${DOMAIN}" \
  --data-urlencode "cert=$(cat "${CERT}")" \
  --data-urlencode "key=$(cat "${KEY}")" \
  --data-urlencode "cabundle=$(cat "${CA}")" \
  "${HOST}/execute/SSL/install_ssl"
