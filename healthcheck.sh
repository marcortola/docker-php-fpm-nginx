#!/bin/sh

set -e

curl --silent --fail http://127.0.0.1/healthcheck-ping || exit 1
