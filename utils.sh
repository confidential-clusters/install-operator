#!/bin/bash

# Utility functions shared across install-operator scripts.

require_cmds() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "Error: required command(s) not found: ${missing[*]}. Install them and ensure they are on PATH." >&2
        exit 1
    fi
}
