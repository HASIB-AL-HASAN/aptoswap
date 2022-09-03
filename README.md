# Aptoswap

## Development

- To publish the package:
    - To publish to local network `aptos move publish --named-addresses Aptoswap=default --url="http://localhost:8080/v1" --max-gas 200000`
    - To publish to local network `aptos move publish --named-addresses Aptoswap=default --url="https://fullnode.devnet.aptoslabs.com/v1" --max-gas 200000`
- To initialze the package: run `aptos move run --function-id default::pool::initialize --args u8:6 --url="http://localhost:8080/v1"`
- To create a pool 