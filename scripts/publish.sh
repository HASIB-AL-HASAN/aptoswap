#!/bin/bash
# Copyright (c) 2022, Vivid Network Contributors
# SPDX-License-Identifier: Apache-2.0

HIPPO_DEVNET_TOKEN_PACKAGE="0x498d8926f16eb9ca90cab1b3a26aa6f97a080b3fcbe6e83ae150b7243a00fb68"

LOCALTEST_FULLNODE_URL="http://localhost:8080/v1"
LOCALTEST_FAUCET_URL="http://localhost:8081"

DEVNET_FULLNODE_URL="https://fullnode.devnet.aptoslabs.com/v1"
DEVNET_FAUCET_URL="https://faucet.devnet.aptoslabs.com/"

TESTNET_FULLNODE_URL="https://ait3.aptosdev.com/v1"
TESTNET_FAUCET_URL=""

FULLNODE_URL="${LOCALTEST_FULLNODE_URL}"
FAUCET_URL="${LOCALTEST_FAUCET_URL}"

if [[ ${APTOSWAP_PUBLISH_NETWORK} == "devnet" ]]; then
    FULLNODE_URL="${DEVNET_FULLNODE_URL}"
    FAUCET_URL="${DEVNET_FAUCET_URL}"
elif [[ ${APTOSWAP_PUBLISH_NETWORK} == "testnet" ]]; then
    FULLNODE_URL="${TESTNET_FULLNODE_URL}"
    FAUCET_URL="${TESTNET_FAUCET_URL}"
elif [[ ${APTOSWAP_PUBLISH_NETWORK} == "localhost" ]]; then
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
    aptos account fund-with-faucet --account ${APTOSWAP_PACKAGE_ADDR} --amount 1000000 --faucet-url ${FAUCET_URL} --url ${FULLNODE_URL}
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
echo "[5] Create pools..."

echo "    Create pool[${APTOSWAP_PACKAGE_ADDR}::pool::TestToken / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${APTOSWAP_PACKAGE_ADDR}::pool::TestToken 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${APTOSWAP_PACKAGE_ADDR}::pool::Token / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${APTOSWAP_PACKAGE_ADDR}::pool::Token 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetBNB / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetBNB 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetBTC / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetBTC 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetDAI / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetDAI 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetETH / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetETH 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetSOL / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetSOL 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetUSDC / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetUSDC 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "    Create pool[${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetUSDT / 0x1::aptos_coin::AptosCoin]"
aptos move run --function-id default::pool::create_pool --type-args ${HIPPO_DEVNET_TOKEN_PACKAGE}::devnet_coins::DevnetUSDT 0x1::aptos_coin::AptosCoin --args u64:4 u64:26 --url ${FULLNODE_URL}

echo "[6] Create Minting APTS..."
aptos move run --function-id default::pool::mint_token --args u64:10000000000 address:${APTOSWAP_PACKAGE_ADDR} --url ${FULLNODE_URL}
