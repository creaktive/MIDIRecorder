#!/bin/bash
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
swiftc -Onone -framework AudioToolbox ChannelParser.swift Tests/main.swift -o "$T/tests"
"$T/tests"
