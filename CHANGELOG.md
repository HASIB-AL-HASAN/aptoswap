# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2022-08-25
- Initial Uniswap V2 like implementation. 
- Support:
    - Create pool.
    - Swapping assets.
    - Adding or removing liqudity.

## [0.1.2] - 2022-08-25
- Changing creating pool without deposit any coin.
- Add freeze operation to the pool so that user could not swap or adding liqudity to the pool.

## [0.1.3] - 2022-08-26
- Adding pool index to the pool struct

## [0.1.3] - 2022-08-27
- Add slippage control.

## [0.1.5] - 2022-09-03
- Upgrade the dependency aptos core to branch `@e6e2f9f7`

## [0.2.0] - 2022-09-18
- Upgrade the dependency aptos core to newest devnet branch.
- Split the test and the implementations.
- Refactor and remove sending the pool account address each entrypoints in the smart contract. All the pools are now located in the package address.