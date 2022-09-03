#!/bin/bash
# Copyright (c) 2022, Vivid Network Contributors
# SPDX-License-Identifier: Apache-2.0

LOCALTEST_FULLNODE_URL="http://localhost:8080/v1"
LOCALTEST_FAUCET_URL="http://localhost:8081"

DEVNET_FULLNODE_URL="https://fullnode.devnet.aptoslabs.com/v1"
DEVNET_FAUCET_URL="https://faucet.devnet.aptoslabs.com/"

FULLNODE_URL="${LOCALTEST_FULLNODE_URL}"
FAUCET_URL="${LOCALTEST_FAUCET_URL}"

if [[ ${APTOSWAP_PUBLISH_NETWORK} == "devnet" ]]; then
    FULLNODE_URL="${DEVNET_FULLNODE_URL}"
    FAUCET_URL="${DEVNET_FAUCET_URL}"
else
    FULLNODE_URL="${LOCALTEST_FULLNODE_URL}"
    FAUCET_URL="${LOCALTEST_FAUCET_URL}"
fi

if [ ! -f "./Move.toml" ]; then
    echo "[ERROR]: Wrong working directory, should be in the root of Aptoswap"
    exit 1
fi

if [ ! -d "./.aptos" ]; then
    echo "[ERROR]: Cannot find ./.aptos, please run \"aptos init\""
    exit 1
fi

cd ./develop
npm i
APTOSWAP_PACKAGE_ADDR=$(npx ts-node ./src/index.ts)
echo "[1] Generating package address: ${APTOSWAP_PACKAGE_ADDR}"
cd ..

if [[ ${FAUCET_URL} != "" ]] ; then
    echo "[1-additional] Funding ${APTOSWAP_PACKAGE_ADDR}"
    aptos account fund-with-faucet --account ${APTOSWAP_PACKAGE_ADDR} --amount 1000000 --faucet-url ${FAUCET_URL}
fi

echo "[2] Remove previous build"
aptos move clean
if [ -f "./build" ]; then
    rm -rf "./build"
fi

echo "[3] Publish..."
aptos move publish --named-addresses Aptoswap=default --url=${FULLNODE_URL} --max-gas 200000
echo "[4] Initilaize..."
aptos move run --function-id default::pool::initialize --args u8:6 --url=${FULLNODE_URL}
echo "[5] Create pool..."
aptos move run --function-id default::pool::create_pool --type-args 0x1::aptos_coin::AptosCoin ${APTOSWAP_PACKAGE_ADDR}::pool::TestToken --args u64:5 u64:25 --url ${FULLNODE_URL}
