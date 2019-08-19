#!/usr/bin/env bash

bindir=$(cd "$(dirname "$0")" && pwd)
openssl="$bindir/../../install/bin/openssl"

if [ ! -f "$openssl" ]; then
    echo "Could not find openssl executable: $openssl";
    exit 1;
fi

if [ -z "$1" ]; then
    echo "Address arg is missing";
    exit 1;
fi

addr=$1

case "$2" in
    "tls1" | "tls1_1" | "tls1_2" | "tls1_3")
        TLSvsn=$2
        ;;
    "")
        echo "Missing TLS version argument"
        exit 1;
        ;;
    *)
        echo "Invalid TLS version argument"
        exit 1;
        ;;
esac

if [ "$TLSvsn" = "tls1_3" ]; then
    ciphersarg="-ciphersuites"
else
    ciphersarg="-cipher"
fi

for c in `$openssl ciphers 'ALL:eNULL' | tr ':' ' '`; do
    $openssl s_client -connect $addr $ciphersarg $c -$TLSvsn < /dev/null > /dev/null 2>&1;
    if [ $? -eq 0 ]; then
        echo " $c";
    fi;
done
