// import { AptosAccount, BCS, AptosClient, TxnBuilderTypes, HexString, MaybeHexString, FaucetClient } from "aptos";
// import yaml from "js-yaml";
// import path from "path"
// import fs from 'fs'
// import { StructTag, TypeTagStruct } from "aptos/dist/transaction_builder/aptos_types";

// const LOCAL_NETWORK = "http://127.0.0.1:8080/v1";
// const LOCAL_NETWORK_FAUCET = "http://127.0.0.1:8081"
// const DEVNET_NETWORK = "https://fullnode.devnet.aptoslabs.com/v1";
// const DEVNET_NETWORK_FAUCET = "https://faucet.devnet.aptoslabs.com/";

// const hexToBytes = (hex: string) => {
//     console.log(hex);
//     let bytes: number[] = [];
//     for (let c = (hex.startsWith("0x") ? 2 : 0); c < hex.length; c += 2) {
//         const b = hex.slice(c, c + 2);
//         bytes.push(parseInt(b, 16));
//     }
//     return new Uint8Array(bytes);
// }

// const getBalance = async (client: AptosClient, accountAddress: MaybeHexString) => {
//     try {
//         const resource = await client.getAccountResource(
//             accountAddress,
//             `0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>`,
//         );
//         return BigInt((resource.data as any)["coin"]["value"]);
//     } catch (_) {
//         return BigInt(0);
//     }
// }

// const publishModule = async (client: AptosClient, accountFrom: AptosAccount, moduleHex: Uint8Array) => {
//     const moduleBundlePayload = new TxnBuilderTypes.TransactionPayloadModuleBundle(
//         new TxnBuilderTypes.ModuleBundle([new TxnBuilderTypes.Module(moduleHex)]),
//     );

//     const [{ sequence_number: sequenceNumber }, chainId] = await Promise.all([
//         client.getAccount(accountFrom.address()),
//         client.getChainId(),
//     ]);

//     const rawTxn = new TxnBuilderTypes.RawTransaction(
//         TxnBuilderTypes.AccountAddress.fromHex(accountFrom.address()),
//         BigInt(sequenceNumber),
//         moduleBundlePayload,
//         BigInt(2000000),
//         BigInt(1),
//         BigInt(Math.floor(Date.now() / 1000) + 80),
//         new TxnBuilderTypes.ChainId(chainId),
//     );

//     const bcsTxn = AptosClient.generateBCSTransaction(accountFrom, rawTxn);
//     const transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
//     for (let _; ; ++_) {
//         try {
//             const transacationResult = await client.waitForTransactionWithResult(transactionRes.hash);
//             console.log(transacationResult);
//             return transacationResult.hash    
//         } catch {
//             console.log("Retrying...");
//             continue;
//         }
//     }
// }

// const getAccount = () => {
//     const accountConfig = yaml.load(fs.readFileSync(
//         path.join(process.cwd(), "..", ".aptos", "config.yaml"),
//         "utf-8"
//     )) as any;
//     const accountPrivateKey = hexToBytes(accountConfig.profiles.default.private_key);
//     const accountAddress = accountConfig.profiles.default.account;
//     const account = new AptosAccount(accountPrivateKey, accountAddress);
//     return account;
// }

// const getMoveCode = () => {
//     const modulePath = path.join(process.cwd(), "..", "build", "Aptoswap", "bytecode_modules", "pool.mv")
//     const buffer = fs.readFileSync(modulePath);
//     return buffer;
// }

// const setup = async () => {
//     // Get the network
//     let network: string = LOCAL_NETWORK;
//     let networkFaucet: string | null = LOCAL_NETWORK_FAUCET;

//     const ENV_NETWORK = process.env.APTOS_PUBLISH_NETWORK as (string | undefined);
//     if (ENV_NETWORK !== undefined) {
//         if (ENV_NETWORK.toLowerCase() === "local" || ENV_NETWORK.toLowerCase() == "localnet") {
//             network = LOCAL_NETWORK;
//             networkFaucet = LOCAL_NETWORK_FAUCET;
//         }
//         else {
//             network = DEVNET_NETWORK;
//             networkFaucet = DEVNET_NETWORK_FAUCET;
//         }
//     }
//     console.log(`Config: netowrk=${network}, faucet=${networkFaucet}`);

//     const client = new AptosClient(network);
//     const account = getAccount();
//     const faucetClient = (networkFaucet !== null) ? new FaucetClient(network, networkFaucet) : null;

//     return [account, client, faucetClient] as [AptosAccount, AptosClient, FaucetClient | null];
// }

// const autoFund = async (account: AptosAccount, client: AptosClient, faucetClient: FaucetClient | null) => {
//     if (faucetClient !== null) {

//         console.log(`[BEGIN] Funding...`)
//         await faucetClient.fundAccount(account.address(), 1000000);
//         console.log(`[DONE] Funding...`)

//         // const data = await client.getAccount(account.address());
//         // const balance = await getBalance(client, account.address());
//         // console.log(`Getting current balance for account ${account.address()}: ${balance}`)
//         // if (balance < BigInt(1e6)) {
//         //     const fundBalance = Number(BigInt(1e6) - balance);
//         //     console.log(`[BEGIN] Funding ${fundBalance}`)
//         //     await faucetClient.fundAccount(account.address(), fundBalance);
//         //     console.log(`[DONE] Funding ${fundBalance}`)
//         // }
//     }
// }

// const submitTransaction = async (client: AptosClient, account: AptosAccount, entryFunc: TxnBuilderTypes.EntryFunction) => {
//     const accountAddr = account.address();
    
//     const payload = new TxnBuilderTypes.TransactionPayloadEntryFunction(entryFunc);

//     console.log(payload);

//     const [{ sequence_number: sequenceNumber }, chainId] = await Promise.all([
//         client.getAccount(accountAddr),
//         client.getChainId(),
//     ]);

//     const rawTxn = new TxnBuilderTypes.RawTransaction(
//         TxnBuilderTypes.AccountAddress.fromHex(accountAddr),
//         BigInt(sequenceNumber),
//         payload,
//         BigInt(20000),
//         BigInt(1),
//         BigInt(Math.floor(Date.now() / 1000) + 50),
//         new TxnBuilderTypes.ChainId(chainId),
//     );

//     const bcsTxn = AptosClient.generateBCSTransaction(account, rawTxn);
//     console.log("[BEGIN] Submit transaction")
//     const transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
//     console.log(`[END] Submit transaction, tx: ${transactionRes.hash}`);

//     console.log("[BEGIN] Wating transaction returns")
//     const result = await client.waitForTransactionWithResult(transactionRes.hash);
//     console.log("[DONE] Wating transaction returns")
//     console.log(result);
// }

// const actionPublish = async () => {

//     const [account, client, faucetClient] = await setup();
//     const accountAddr = account.address();
//     await autoFund(account, client, faucetClient);

//     const code = getMoveCode();
//     console.log("[BEGIN] Publish module...")
//     const txHashPublish = await publishModule(client, account, code);
//     console.log(`[DONE] Publish module, tx: ${txHashPublish}`);
// }

// const actionInitialize = async () => {
//     const [account, client, faucetClient] = await setup();
//     const accountAddr = account.address();
//     await autoFund(account, client, faucetClient);

//     // Run the initialize entry function
//     await submitTransaction(
//         client, account,
//         TxnBuilderTypes.EntryFunction.natural(
//             `${accountAddr.toString()}::pool`,
//             "initialize",
//             [],
//             [BCS.bcsSerializeU8(6)]
//         )
//     );
// }

// const actionCreatTestPool = async () => {
//     const [account, client, faucetClient] = await setup();
//     const accountAddr = account.address();
//     await autoFund(account, client, faucetClient);

//     const payload = new TxnBuilderTypes.TransactionPayloadEntryFunction(
//         TxnBuilderTypes.EntryFunction.natural(
//             `${accountAddr.toString()}::pool`,
//             "create_pool",
//             [
//                 new TypeTagStruct(StructTag.fromString("0x1::aptos_coin::AptosCoin")),
//                 new TypeTagStruct(StructTag.fromString(`${accountAddr.toString()}::pool::TestToken`))
//             ],
//             [
//                 BCS.bcsSerializeUint64(5),
//                 BCS.bcsSerializeUint64(25)
//             ]
//         )
//     );

//     console.log(payload);

//     const [{ sequence_number: sequenceNumber }, chainId] = await Promise.all([
//         client.getAccount(accountAddr),
//         client.getChainId(),
//     ]);

//     const rawTxn = new TxnBuilderTypes.RawTransaction(
//         TxnBuilderTypes.AccountAddress.fromHex(accountAddr),
//         BigInt(sequenceNumber),
//         payload,
//         BigInt(20000),
//         BigInt(1),
//         BigInt(Math.floor(Date.now() / 1000) + 50),
//         new TxnBuilderTypes.ChainId(chainId),
//     );

//     const bcsTxn = AptosClient.generateBCSTransaction(account, rawTxn);
//     console.log("[BEGIN] Submit transaction")
//     const transactionRes = await client.submitSignedBCSTransaction(bcsTxn);
//     console.log(`[END] Submit transaction, tx: ${transactionRes.hash}`);

//     console.log("[BEGIN] Wating transaction returns")
//     const result = await client.waitForTransactionWithResult(transactionRes.hash);
//     console.log("[DONE] Wating transaction returns")
//     console.log(result);
// }

// const actionGetPools = async () => {

//     const [account, client, faucetClient] = await setup();
//     const accountAddr = account.address();

//     const createEvents = await client.getEventsByEventHandle(
//         `${accountAddr}`,
//         `${accountAddr}::pool::SwapCap`,
//         "pool_create_event"
//     );

//     const poolAddrs = createEvents.map(e => e.data.pool_account_addr as string);
//     for (const p of poolAddrs) {
//         const resources = (await client.getAccountResources(p)).filter(resource => resource.type.startsWith(`${accountAddr}::pool::Pool`));
//         if (resources.length > 0) {
//             console.log(resources[0])
//         }
//     }

//     // const getPoolDataPromise = poolAddrs.map(
//     // (addr) => { client.getAccountResources(addr) }
//     // )

//     // console.log(poolAddrs);
// }

// actionPublish();


import yaml from "js-yaml";
import path from "path"
import fs from 'fs'

const hexToBytes = (hex: string) => {
    let bytes: number[] = [];
    for (let c = (hex.startsWith("0x") ? 2 : 0); c < hex.length; c += 2) {
        const b = hex.slice(c, c + 2);
        bytes.push(parseInt(b, 16));
    }
    return new Uint8Array(bytes);
}

const getAccount = () => {
    const accountConfig = yaml.load(fs.readFileSync(
        path.join(process.cwd(), "..", ".aptos", "config.yaml"),
        "utf-8"
    )) as any;
    const accountPrivateKey = hexToBytes(accountConfig.profiles.default.private_key);
    const accountAddress = accountConfig.profiles.default.account;
    
    fs.writeFileSync(
        path.join(process.cwd(), "..", "package_info.json"),
        JSON.stringify({ 
            "package": accountAddress 
        })   
    );

    process.stdout.write(accountAddress);
}

getAccount();