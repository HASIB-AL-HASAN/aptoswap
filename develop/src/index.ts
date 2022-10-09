import { AptosAccount, BCS, AptosClient, TxnBuilderTypes, HexString, MaybeHexString, FaucetClient } from "aptos";
import yaml from "js-yaml";
import path from "path"
import * as crypto from "crypto-js";
import fs from 'fs'
import { execSync } from "child_process";
const prompt_ = require('prompt-sync')();

export const delay = (ms: number) => { return new Promise(resolve => setTimeout(resolve, ms)) };

export interface AptosNetwork {
    fullnode: string;
    faucet: string | null;
}

class Network {
    static local: () => AptosNetwork = () => {
        return { fullnode: "http://127.0.0.1:8080/v1", faucet: "http://127.0.0.1:8081" }
    }

    static devnet: () => AptosNetwork = () => {
        return { fullnode: "https://fullnode.devnet.aptoslabs.com/v1", faucet: "https://faucet.devnet.aptoslabs.com" }
    }

    static testnet: () => AptosNetwork = () => {
        return { fullnode: "https://ait3.aptosdev.com/v1", faucet: null }
    }
}

class Cipher {
    static encrypt = (text: string, secretKey_: string) => {
        const secretKey = secretKey_ + Array(43 - secretKey_.length).fill("0").join("");
        var keyHex = crypto.enc.Base64.parse(secretKey);
        var messageHex = crypto.enc.Utf8.parse(text);
        var encrypted = crypto.AES.encrypt(messageHex, keyHex, {
            "mode": crypto.mode.ECB,
            "padding": crypto.pad.Pkcs7
        });
        return encrypted.toString();
    }

    static decrypt(textBase64: string, secretKey_: string) {
        const secretKey = secretKey_ + Array(43 - secretKey_.length).fill("0").join("");
        var keyHex = crypto.enc.Base64.parse(secretKey);
        var decrypt = crypto.AES.decrypt(textBase64, keyHex, {
            "mode": crypto.mode.ECB,
            "padding": crypto.pad.Pkcs7
        });
        return crypto.enc.Utf8.stringify(decrypt);
    }
}

export type AptosTransacationArgument = string | number | bigint | ["address" | "string", string] | ["u8" | "u16" | "u32" | "u64" | "u128", number | bigint];

export interface AptosTransactionType {
    function: string;
    type_arguments: string[];
    arguments: AptosTransacationArgument[];
}

export interface AptosTransactionOptions {
    maxGasAmount: bigint;
    gasUnitPrice: bigint;
    expirationSecond?: number;
}

const serializeTransactionArgument = (v: AptosTransacationArgument) => {
    let vs: any = v;
    if (typeof v === "string") {
        vs = v.startsWith("0x") ? ["address", v] : ["string", v];
    }
    else if (typeof v === "number") {
        vs = ["u64", v];
    }
    else if (typeof v === "bigint") {
        vs = ["u64", v];
    }
    else {
        vs = v;
    }

    const tag = vs[0] as "address" | "string" | "u8" | "u16" | "u32" | "u64" | "u128";
    const value = vs[1] as (string | number | bigint);
    if (tag === "address") {
        return BCS.bcsToBytes(TxnBuilderTypes.AccountAddress.fromHex(value.toString()));
    }
    else if (tag === "string") {
        return BCS.bcsSerializeStr(value.toString());
    }
    else if (tag === "u8") {
        return BCS.bcsSerializeU8(Number(value));
    }
    else if (tag === "u16") {
        return BCS.bcsSerializeU16(Number(value));
    }
    else if (tag === "u32") {
        return BCS.bcsSerializeU32(Number(value));
    }
    else if (tag === "u64") {
        return BCS.bcsSerializeUint64(BigInt(value));
    }
    else if (tag === "u128") {
        return BCS.bcsSerializeU128(BigInt(value));
    }
    throw Error(`BCS serialize error on argument: ${v}`)
}

const serializeTransactionTypeToPayload = (t: AptosTransactionType) => {
    const transactionFunctionSplit = t.function.split("::");
    const moduleName = transactionFunctionSplit.slice(0, -1).join("::");
    const functionName = transactionFunctionSplit.slice(-1)[0];
    const typeArguments = t.type_arguments.map(ty => new TxnBuilderTypes.TypeTagStruct(TxnBuilderTypes.StructTag.fromString(ty)));
    const args = t.arguments.map(x => serializeTransactionArgument(x));

    const payload = new TxnBuilderTypes.TransactionPayloadEntryFunction(
        TxnBuilderTypes.EntryFunction.natural(
            moduleName,
            functionName,
            typeArguments,
            args
        )
    );
    return payload;
}

let _MOVE_CALL_GAS_SCHEDULE: Array<{key: string, val: string}> | undefined = undefined;
let _MOVE_CALL_MIN_GAS_UNIT_PRICE: bigint | undefined = undefined;

const executeMoveCall = async (client: AptosClient, account: AptosAccount, transaction: AptosTransactionType, exit: boolean = true, option?: AptosTransactionOptions) => {

    if (_MOVE_CALL_GAS_SCHEDULE === undefined) {
        _MOVE_CALL_GAS_SCHEDULE = ((await client.getAccountResource("0x1", "0x1::gas_schedule::GasScheduleV2")).data as any).entries;
        for (const entry of (_MOVE_CALL_GAS_SCHEDULE) ?? []) {
            if (entry.key === "txn.min_price_per_gas_unit") {
                _MOVE_CALL_MIN_GAS_UNIT_PRICE = BigInt(entry.val);
                console.log(`[INFO] Setting min_gas_price to ${_MOVE_CALL_MIN_GAS_UNIT_PRICE}`)
            }
        }
    }

    if (_MOVE_CALL_MIN_GAS_UNIT_PRICE === undefined) {
        throw Error("Unable to get min_gas_price from network");
    }

    console.log(`[INFO] Executing move call: ${transaction.function}<${transaction.type_arguments.join(" ")}>(...)`);

    const payload = serializeTransactionTypeToPayload(transaction);

    const rawTxn = await client.generateRawTransaction(
        account.address(),
        payload,
        {
            maxGasAmount: option?.maxGasAmount ?? BigInt(1000),
            gasUnitPrice: option?.gasUnitPrice ?? _MOVE_CALL_MIN_GAS_UNIT_PRICE,
            expireTimestamp: BigInt(Math.floor(Date.now() / 1000) + (option?.expirationSecond ?? 60.0))
        }
    );

    const signedTransaction = await client.signTransaction(account, rawTxn);
    const submitTransaction = await client.submitSignedBCSTransaction(signedTransaction);

    try {
        await client.waitForTransactionWithResult(submitTransaction.hash, { timeoutSecs: 60.0, checkSuccess: true });
    } catch (e) {
        if (exit) {
            errorAndExit(e);
        }
        else {
            console.log(`[WARNING] Execution failed on ${transaction.function}`);
            // console.log(e);
        }
    }

    return submitTransaction.hash;
}

const workspaceFolder = path.resolve(path.join(process.cwd(), ".."));

const prompt = (s: string, default_?: string): string => {
    const i = prompt_(s);
    if (default_ !== undefined && i.trim().length === 0) {
        return default_;
    }
    return i;
}

const hexToBytes = (hex: string) => {
    console.log(hex);
    let bytes: number[] = [];
    for (let c = (hex.startsWith("0x") ? 2 : 0); c < hex.length; c += 2) {
        const b = hex.slice(c, c + 2);
        bytes.push(parseInt(b, 16));
    }
    return new Uint8Array(bytes);
}

const errorAndExit = (s: any, exitCode?: number) => {
    console.log(`[ERROR] ${s}`);
    process.exit(exitCode ?? 1);
}

const cmd = (s: string, exit: boolean = true, env?: any) => {
    try {
        console.log(`[EXECUTE] ${s}`)
        return execSync(s, { "encoding": "utf-8", env: (env !== undefined) ? { ...process.env, ...env } : process.env })
    } catch (e) {
        console.log((e as any).stdout);
        console.log((e as any).stderr)
        if (exit) {
            errorAndExit(`Command failed when executing \'${s}\"`)
        }
    }
    return "";
}

const getBalance = async (client: AptosClient, accountAddress: MaybeHexString) => {
    try {
        const resource = await client.getAccountResource(
            accountAddress,
            `0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>`,
        );
        return BigInt((resource.data as any)["coin"]["value"]);
    } catch (_) {
        return BigInt(0);
    }
}

const publishModule = async (client: AptosClient, accountFrom: AptosAccount, moduleHexes: Uint8Array[], metadata: Uint8Array) => {
    let txnHash = await client.publishPackage(
        accountFrom, metadata, 
        moduleHexes.map(hex => new TxnBuilderTypes.Module(hex))
    );
    await client.waitForTransaction(txnHash, { checkSuccess: true });
    return txnHash;
}

const newAccount = () => {
    const password = prompt("Enter the password to renew a account: ").trim();

    process.chdir(workspaceFolder); {
        if (fs.existsSync(".aptos")) {
            fs.rmSync(".aptos", { "force": true, "recursive": true });
        }
        cmd("aptos init");
    }

    console.log("Encrypt:")
    console.log("================================================")
    const text = fs.readFileSync(".aptos/config.yaml", "utf-8");
    const encrypted = Cipher.encrypt(text, password);
    console.log(encrypted);
    console.log("================================================\n")

    console.log("Text:")
    console.log("================================================")
    const decripted = Cipher.decrypt(encrypted, password);
    console.log(decripted);
    console.log("================================================")

    process.chdir(workspaceFolder); {
        fs.rmSync(".aptos", { "force": true, "recursive": true });
    }
}

const getAccount = () => {
    const encrypted = "+mRO1QBmGxuAuPTfmziehPP3CCzilyD5HRyLC0FvWoCkOSiZYMMhsv7ckK90A5ersmE8YAZR2Y5tIVsDFejM1Sj+nIrGT9xpo/aUo7aBcCj9h7xLAHTxjI+N6KVnLTE/YkQQqHsVHhY3cDNeLDbl7bWqfTr+hE1vTechuVSgHbv+4dfyLueigVJJgRHEfgOxAnhsbmxRmufxHAnWZhmamA5lnmqycpTXt4l8ylVNS0eMp2XGUfVv3st3jDNXBdUVuqwU4TfRW62aEqBxApbEekUEPf2lpEjKCGJ+HVGjB7racwv3SI4a8Rt39S8/JnukvhDOtPS2Q4ecougyxmtPQS5vCZzwO2tXyAGS6aoOAXNASjBnpaDNkdySyBgp/L2Y+H4Ll7+4tAOI/dzEjJNj7gCMhRnekoX6yCKSsWhRO0Ufb4SHkUJJx7YErYTCj42ZlNJKmLvTjIA1mk8T2UwOMnYaSltbA5Uy8f5hI9lMSJxMszz7LA9QDqg8e62pXGQVvyfhEP5aYBbY9L9kX9Vlbw==";
    const password = prompt("Enter the password to get the account: ");
    const decrypted = Cipher.decrypt(encrypted, password);

    console.log(`[INFO] Use the following config.yaml:\n=======================================\n${decrypted}\n`);

    process.chdir(workspaceFolder); {
        if (!fs.existsSync(".aptos")) {
            fs.mkdirSync(".aptos");
        }

        const configPath = path.join(".aptos", "config.yaml");
        if (fs.existsSync(configPath)) {
            fs.rmSync(configPath, { "force": true, "recursive": true });
        }

        fs.writeFileSync(configPath, decrypted);
    }

    const accountConfig = yaml.load(decrypted) as any;
    const accountPrivateKey = hexToBytes(accountConfig.profiles.default.private_key);
    const accountAddress = accountConfig.profiles.default.account;
    const account = new AptosAccount(accountPrivateKey, accountAddress);

    return account;
}

const getMoveCode = () => {
    const moduleFilenames = [
        'utils.mv',
        'pool.mv',
    ];

    const buffers = moduleFilenames.map(
        moduleFilename => {
            const modulePath = path.join(workspaceFolder, "build", "Aptoswap", "bytecode_modules", moduleFilename);
            const buffer = fs.readFileSync(modulePath);
            return new HexString(buffer.toString("hex")).toUint8Array();
        }
    )

    return buffers;
}

const getMoveMetadata = () => {
    const metadataPath = path.join(workspaceFolder, "build", "Aptoswap", "package-metadata.bcs");
    const buffer = fs.readFileSync(metadataPath);
    return new HexString(buffer.toString("hex")).toUint8Array();
}

const setup = async () => {
    // Get the network

    let selectNetworkInput = prompt("Select your network [devnet|localhost|testnet] (default: localhost): ", "localhost").trim();
    const n: AptosNetwork = ({
        devnet: Network.devnet(),
        localhost: Network.local(),
        testnet: Network.testnet()
    } as any)[selectNetworkInput];

    if (n === undefined) {
        errorAndExit("Invalid network input");
    }

    const client = new AptosClient(n.fullnode);
    const account = getAccount();
    const faucetClient = (n.faucet !== null) ? new FaucetClient(n.fullnode, n.faucet) : null;

    return [account, client, faucetClient, n] as [AptosAccount, AptosClient, FaucetClient | null, AptosNetwork];
}

const autoFund = async (account: AptosAccount, client: AptosClient, faucetClient: FaucetClient | null, target?: number) => {
    if (faucetClient !== null) {
        console.log(`[BEGIN] Funding...`)

        while (true) {
            await faucetClient.fundAccount(account.address(), 100000 * (10 ** 8));


            if (target === undefined) {
                break;
            }

            const balance = await getBalance(client, account.address());
            if (Number(balance) / (10 ** 8) < target) {
                await delay(3000.0);
                continue;
            }

            break;
        }

        console.log(`[DONE] Funding...`)
    }
}

const actionPublish = async () => {
    const HIPPO_TOKEN_PACKAGE_ADDR = "0xdeae46f81671e76f444e2ce5a299d9e1ea06a8fa26e81dfd49aa7fa5a5a60e01";

    const [account, client, faucetClient, net] = await setup();
    const accountAddr = account.address();
    const packageAddr = accountAddr;
    await autoFund(account, client, faucetClient, 0.07);

    const currentBalance = await getBalance(client, accountAddr);
    const currentBalanceShow = Number(currentBalance) / (10 ** 8);
    console.log(`[INFO] Current balance: ${currentBalance}(${currentBalanceShow})`);

    process.chdir(workspaceFolder); {
        if (fs.existsSync("package_info.json")) {
            fs.rmSync("package_info.json", { "force": true });
        }

        fs.writeFileSync(
            "package_info.json",
            JSON.stringify({
                "package": accountAddr.toString()
            })
        );
    }

    process.chdir(workspaceFolder); {
        // Clean & build
        if (fs.existsSync("build")) {
            fs.rmSync("build", { "force": true, "recursive": true });
        }
        cmd("aptos move clean --assume-yes", false);
        cmd("aptos move compile --named-addresses Aptoswap=default --save-metadata");

        const code = getMoveCode();
        const metadata = getMoveMetadata();

        console.log("[BEGIN] Publish module...")
        const txHashPublish = await publishModule(client, account, code, metadata);
        console.log(`[DONE] Publish module, tx: ${txHashPublish}`);
    }

    const poolTokens = [
        `${packageAddr}::pool::TestToken`,
        `${packageAddr}::pool::Token`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetBNB`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetBTC`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetDAI`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetETH`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetSOL`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetUSDC`,
        `${HIPPO_TOKEN_PACKAGE_ADDR}::devnet_coins::DevnetUSDT`
    ]

    // Initialize
    await executeMoveCall(
        client, account,
        {
            function: `${packageAddr}::pool::initialize`,
            type_arguments: [],
            arguments: [["u8", 6]]
        },
        true
    );

    // Mint token
    await executeMoveCall(
        client, account,
        {
            function: `${packageAddr}::pool::mint_token`,
            type_arguments: [],
            arguments: [
                BigInt(100 * (10 ** 8)),
                ["address", accountAddr.toString()]
            ]
        },
        false
    );

    // Create pool
    for (const poolToken of poolTokens) {
        await executeMoveCall(
            client, account,
            {
                function: `${packageAddr}::pool::create_pool`,
                type_arguments: [poolToken, "0x1::aptos_coin::AptosCoin"],
                arguments: [
                    ["u8", 201], // Fee direction (base coin)
                    3, // Admin fee: 0.03%
                    26, // Lp fee: 0.26%
                    0, // Incentive fee: 0%
                    1, // Connect fee: 0.01%
                    10, // Withdraw fee: 0.1% 
                ]
            },
            false
        );
    }
}

const actionNewAccount = async () => { await newAccount(); }

const actionGetAccount = async () => { await getAccount(); }

const executeAction = async () => {
    const commands: Map<string, () => Promise<void>> = new Map([
        ["publish", actionPublish],
        ["new-account", actionNewAccount],
        ["account", actionGetAccount]
    ]);

    if (process.argv.length < 3) {
        errorAndExit("Not enough argument, please enter the command");
    }

    const commandStr = process.argv[2].trim();
    const command = commands.get(commandStr);

    if (command !== undefined) {
        await command();
    }
    else {
        errorAndExit(`Invalid action \"${commandStr}\", possible options: \"${Array(commands.keys()).join("|")}\"`)
    }
}

executeAction()