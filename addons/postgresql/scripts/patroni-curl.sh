#!/bin/sh

patroni_curl() {
    username_set=${PATRONI_RESTAPI_USERNAME+x}
    password_set=${PATRONI_RESTAPI_PASSWORD+x}
    if [ -z "$username_set" ] && [ -z "$password_set" ]; then
        curl --fail "$@"
        return
    fi

    username=${PATRONI_RESTAPI_USERNAME-}
    password=${PATRONI_RESTAPI_PASSWORD-}
    if [ -z "$username_set" ] || [ -z "$password_set" ] || [ -z "$username" ] || [ -z "$password" ]; then
        echo "PATRONI_RESTAPI_USERNAME and PATRONI_RESTAPI_PASSWORD must be set together and must not be empty" >&2
        return 2
    fi

    # Keep credentials out of argv. Curl reads Basic Auth from stdin config.
    newline_count=$(printf "%s%s" "$username" "$password" | wc -l)
    if [ "$newline_count" -ne 0 ] || printf "%s%s" "$username" "$password" | grep -q "$(printf "\r")"; then
        echo "PATRONI_RESTAPI credentials must not contain carriage returns or newlines" >&2
        return 2
    fi
    escaped_username=$(printf "%s" "$username" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g")
    escaped_password=$(printf "%s" "$password" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g")
    printf "user = \"%s:%s\"\n" "$escaped_username" "$escaped_password" | curl --fail --config - "$@"
}
