#!/bin/sh

issue_and_deploy() {
    DOMAIN="$1"
    shift

    CERT="/acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer"

    OLD_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)

    echo ""
    echo "=========================================="
    echo "=== Checking $DOMAIN ==="
    echo "=========================================="

    OUTPUT=$(acme.sh --issue --dns dns_cpanel \
      "$@" \
      --server letsencrypt 2>&1)

    RESULT=$?

    echo "$OUTPUT"

    NEW_MTIME=$(stat -c %Y "$CERT" 2>/dev/null || echo 0)

    if [ "$NEW_MTIME" -gt "$OLD_MTIME" ]; then
        echo "New certificate detected for $DOMAIN."
        echo "Deploying to cPanel..."

        /acme.sh/install-certs.sh "$DOMAIN"
        return $?
    fi

    if echo "$OUTPUT" | grep -q "Skipping. Next renewal time is"; then
        echo "$DOMAIN is not due for renewal."
        return 0
    fi

    if [ $RESULT -ne 0 ]; then
        echo "ERROR: acme.sh failed for $DOMAIN."
        return $RESULT
    fi

    echo "Certificate unchanged for $DOMAIN."
    return 0
}

issue_and_deploy \
  "sub.example.com" \
  -d sub.example.com
  
issue_and_deploy \
  "example2.com" \
  -d example2.com \
  -d '*.example2.com'
