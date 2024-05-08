#!/bin/bash

set -eo pipefail

# Don't prompt for answers during apt-get install
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y git apt-transport-https ca-certificates tzdata curl python3

TESTNET_NAME="berkeley"

git config --global --add safe.directory /workdir
source buildkite/scripts/export-git-env-vars.sh

DEBS="mina-${TESTNET_VERSION_NAME}"
source buildkite/scripts/debian/install.sh 

K=1
MAX_NUM_UPDATES=4
MIN_NUM_UPDATES=2   

echo "-- Run Snark Transaction Profiler with parameters: --zkapps --k ${K} --max-num-updates ${MAX_NUM_UPDATES} --min-num-updates ${MIN_NUM_UPDATES}"
python3 ./scripts/snark_transaction_profiler.py ${K} ${MAX_NUM_UPDATES} ${MIN_NUM_UPDATES}
