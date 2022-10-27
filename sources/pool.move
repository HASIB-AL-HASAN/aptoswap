module Aptoswap::pool {
    use std::string;
    use std::signer;
    use std::vector;
    use std::option;
    use aptos_std::event::{ Self, EventHandle };
    use aptos_std::type_info;
    use aptos_framework::managed_coin;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::timestamp;

    use Aptoswap::utils::{ WeeklySmaU128, create_sma128, add_sma128, pow10 };
    use Aptoswap::u256::{ 
        U256, add, sub, mul, div, from_u64, is_zero, zero, one,
        less_or_equals, greater_or_equals, abs_sub
    };

    #[test_only]
    friend Aptoswap::pool_test;

    const NUMBER_1E8: u128 = 100000000;

    const ERouteSwapDirectionForward: u8 = 0;
    const ERouteSwapDirectionReverse: u8 = 1;

    const EPoolTypeV2: u8 = 100;
    const EPoolTypeStableSwap: u8 = 101;

    const EFeeDirectionX: u8 = 200;
    const EFeeDirectionY: u8 = 201;

    /// For when supplied Coin is zero.
    const EInvalidParameter: u64 = 13400;
    /// For when pool fee is set incorrectly.  Allowed values are: [0-10000)
    const EWrongFee: u64 = 134001;
    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 134002;
    /// For when initial LSP amount is zero.02
    const EShareEmpty: u64 = 134003;
    /// For when someone attemps to add more liquidity than u128 Math allows.3
    const EPoolFull: u64 = 134004;
    /// For when the internal operation overflow.
    const EOperationOverflow: u64 = 134005;
    /// For when some intrinsic computation error detects
    const EComputationError: u64 = 134006;
    /// Can not operate this operation
    const EPermissionDenied: u64 = 134007;
    /// Not enough balance for operation
    const ENotEnoughBalance: u64 = 134008;
    /// Not coin registed
    const ECoinNotRegister: u64 = 134009;
    /// Pool freezes for operation
    const EPoolFreeze: u64 = 134010;
    /// Slippage limit error
    const ESlippageLimit: u64 = 134011;
    /// Pool not found
    const EPoolNotFound: u64 = 134012;
    /// Create duplicate pool
    const EPoolDuplicate: u64 = 134013;
    /// Stable coin decimal too large
    const ECreatePoolStableCoinDecimalTooLarge: u64 = 134014;
    /// No implementeed error code
    const ENoImplement: u64 = 134015;
    /// Deprecated
    const EDeprecated: u64 = 134016;

    /// The integer scaling setting for fees calculation.
    const BPS_SCALING: u128 = 10000;
    /// The maximum number of u64
    const U64_MAX: u128 = 18446744073709551615;
    /// The max decimal of stable swap coin
    const STABLESWAP_COIN_MAX_DECIMAL: u8 = 18;

    /// The interval between the snapshot in seconds
    const SNAPSHOT_INTERVAL_SEC: u64 = 900;
    /// The interval between the refreshing the total trade 24h
    const TOTAL_TRADE_24H_INTERVAL_SEC: u64 = 86400;
    /// The interval between captuing the bank amount
    const BANK_AMOUNT_SNAPSHOT_INTERVAL_SEC: u64 = 3600 * 6;

    const STABLESWAP_N_COINS: u64 = 2;
    const STABLESWAP_MIN_AMP: u64 = 1;
    const STABLESWAP_MAX_AMP: u64 = 1000000;

    struct PoolCreateEvent has drop, store {
        index: u64
    }

    struct SwapTokenEvent has drop, store {
        // When the direction is x to y or y to x
        x_to_y: bool,
        // The in token amount
        in_amount: u64,
        // The out token amount
        out_amount: u64,
    }

    struct LiquidityEvent has drop, store {
        // Whether it is a added/removed liqulity event or remove liquidity event
        is_added: bool,
        // The x amount to added/removed
        x_amount: u64,
        // The y amount to added/removed
        y_amount: u64,
        // The lsp amount to added/removed
        lsp_amount: u64
    }

    struct SnapshotEvent has drop, store {
        x: u64,
        y: u64
    }

    struct CoinAmountEvent has drop, store {
        amount: u64
    }

    struct SwapCap has key {
        /// Points to the next pool id that should be used
        pool_create_counter: u64,
        pool_create_event: EventHandle<PoolCreateEvent>,
        /// The capability to get the account the could be used to generate a account that could used 
        /// for minting test token
        test_token_owner_cap: account::SignerCapability
    }

    struct Token { }
    struct TestToken { }

    struct TestTokenCapabilities has key {
        mint: coin::MintCapability<TestToken>,
        freeze: coin::FreezeCapability<TestToken>,
        burn: coin::BurnCapability<TestToken>,
    }

    struct LSP<phantom X, phantom Y> {}

    struct LSPCapabilities<phantom X, phantom Y> has key {
        mint: coin::MintCapability<LSP<X, Y>>,
        freeze: coin::FreezeCapability<LSP<X, Y>>,
        burn: coin::BurnCapability<LSP<X, Y>>,
    }

    struct Bank<phantom X> has key {
        coin: coin::Coin<X>,
        coin_amount_event: EventHandle<CoinAmountEvent>,
        coin_amount_event_last_time: u64
    }

    struct Pool<phantom X, phantom Y> has key {
        /// The index of the pool
        index: u64,
        /// The pool type
        pool_type: u8,
        /// The balance of X token in the pool
        x: coin::Coin<X>,
        /// The balance of token in the pool
        y: coin::Coin<Y>,
        /// The current lsp supply value as u64
        lsp_supply: u64,

        /// Affects how the admin fee and connect fee are extracted.
        /// For a pool with quote coin X and base coin Y. 
        /// - When `fee_direction` is EFeeDirectionX, we always
        /// collect quote coin X for admin_fee & conY. 
        /// - When `fee_direction` is EFeeDirectionY, we always 
        /// collect base coin Y for admin_fee & connect_fee.
        fee_direction: u8,

        /// Admin fee is denominated in basis points, in bps
        admin_fee: u64,
        /// Liqudity fee is denominated in basis points, in bps
        lp_fee: u64,
        /// Fee for incentive
        incentive_fee: u64,
        /// Fee when connect to a token reward pool
        connect_fee: u64,
        /// Fee when user withdraw lsp token
        withdraw_fee: u64,

        /// Stable pool amplifier
        stable_amp: u64, 
        /// The scaling factor that aligns x's decimal to 18
        stable_x_scale: u64,
        /// The scaling factor that aligns y's decimal to 18
        stable_y_scale: u64,
        
        /// Whether the pool is freezed for swapping and adding liquidity
        freeze: bool,

        /// Last trade time
        last_trade_time: u64,

        /// Number of x has been traded
        total_trade_x: u128,
        /// Number of y has been traded
        total_trade_y: u128,

        /// Total trade 24h last capture time
        total_trade_24h_last_capture_time: u64,
        /// Number of x has been traded (in one day)
        total_trade_x_24h: u128,
        /// Number of y has been traded (in one day)
        total_trade_y_24h: u128,

        /// The term "ksp_e7" means (K / lsp * 10^8), record in u128 format
        ksp_e8_sma: WeeklySmaU128,

        /// Swap token events
        swap_token_event: EventHandle<SwapTokenEvent>,
        /// Add liquidity events
        liquidity_event: EventHandle<LiquidityEvent>,
        /// Snapshot events
        snapshot_event: EventHandle<SnapshotEvent>,
        /// Snapshot last capture time (in sec)
        snapshot_last_capture_time: u64
    }

    // ============================================= Entry points =============================================
    public entry fun initialize(owner: &signer, demicals: u8) {
        initialize_impl(owner, demicals);
    }

    public entry fun withdraw_bank<X>(owner: &signer, amount: u64) acquires Bank {
        withdraw_bank_impl<X>(owner, amount);
    }

    public entry fun mint_token(owner: &signer, amount: u64, recipient: address) {
        mint_token_impl(owner, amount, recipient);
    }

    public entry fun mint_test_token(owner: &signer, amount: u64, recipient: address) acquires SwapCap, TestTokenCapabilities {
        mint_test_token_impl(owner, amount, recipient);
    }

    public entry fun create_pool<X, Y>(owner: &signer, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64) acquires SwapCap, Pool {
        let _ = create_pool_impl<X, Y>(owner, EPoolTypeV2, fee_direction, admin_fee, lp_fee, incentive_fee, connect_fee, withdraw_fee, 0);
    }

    public entry fun create_stable_pool<X, Y>(owner: &signer, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64, amp: u64) acquires SwapCap, Pool {
        let _ = create_pool_impl<X, Y>(owner, EPoolTypeStableSwap, fee_direction, admin_fee, lp_fee, incentive_fee, connect_fee, withdraw_fee, amp);
    }

    public entry fun change_fee<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64) acquires Pool {
        change_fee_impl<X, Y>(owner, admin_fee, lp_fee, incentive_fee, connect_fee);
    }

    public entry fun freeze_pool<X, Y>(owner: &signer) acquires Pool {
        freeze_or_unfreeze_pool_impl<X, Y>(owner, true)
    }

    public entry fun unfreeze_pool<X, Y>(owner: &signer) acquires Pool {
        freeze_or_unfreeze_pool_impl<X, Y>(owner, false)
    }

    public entry fun swap_x_to_y<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64) acquires Pool, Bank {
        swap_x_to_y_impl<X, Y>(user, in_amount, min_out_amount, timestamp::now_seconds());
    }

    public entry fun swap_y_to_x<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64) acquires Pool, Bank {
        swap_y_to_x_impl<X, Y>(user, in_amount, min_out_amount, timestamp::now_seconds());
    }

    public entry fun add_liquidity<X, Y>(user: &signer, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {
        add_liquidity_impl<X, Y>(user, x_added, y_added);
    }

    /// On-chain route swapping for for asset X -> Y -> Z. 
    /// This uses two swap pool to swap assets from X asset to Z asset with intermediate asset Y.
    /// The direction specifies the routing direction and which pool to use:
    ///    1. When _direction1 is ERouteSwapDirectionForward, it will use `Pool<X, Y>` and `swap_x_to_y` to do the swapping
    ///    2. When _direction1 is ERouteSwapDirectionReverse, it will use `Pool<Y, X>` and `swap_y_to_x` to do the swapping.
    ///    3. When _direction2 is ERouteSwapDirectionForward, it will use `Pool<Y, Z>` and `swap_x_to_y` to do the swapping
    ///    4. When _direction2 is ERouteSwapDirectionReverse, it will use `Pool<Z, Y>` and `swap_y_to_x` to do the swapping.
    public entry fun route_swap<X, Y, Z>(user: &signer, in_amount: u64, min_out_amount: u64, direction1: u8, direction2: u8) acquires Pool, Bank {
        route_swap_impl<X, Y, Z>(user, in_amount, min_out_amount, direction1, direction2, timestamp::now_seconds());
    }

    public entry fun remove_liquidity<X, Y>(user: &signer, lsp_amount: u64) acquires Pool, LSPCapabilities, Bank {
        remove_liquidity_impl_v2<X, Y>(user, lsp_amount, timestamp::now_seconds());
    }
    // ============================================= Entry points =============================================

    // ============================================= Public functions =============================================
    public fun swap_x_to_y_direct<X, Y>(in_coin: coin::Coin<X>): coin::Coin<Y> acquires Pool, Bank {
        swap_x_to_y_direct_impl(in_coin,  timestamp::now_seconds())
    }

    public fun swap_y_to_x_direct<X, Y>(in_coin: coin::Coin<Y>): coin::Coin<X> acquires Pool, Bank {
        swap_y_to_x_direct_impl(in_coin,  timestamp::now_seconds())
    }
    // ============================================= Public functions =============================================


    // ============================================= Implementations =============================================
    public(friend) fun initialize_impl(owner: &signer, demicals: u8) {
        validate_admin(owner);

        // Register the tokens
        managed_coin::initialize<Token>(
            owner,
            b"Aptoswap",
            b"APTS",
            demicals,
            true
        );
        managed_coin::register<Token>(owner);

        // Register the test token
        let (test_token_owner, test_token_owner_cap) = account::create_resource_account(
            owner, 
            get_seed_from_hint_and_index(b"Aptoswap::TestToken", 0)
        );
        let test_token_owner = &test_token_owner;
        let (test_burn_cap, test_freeze_cap, test_mint_cap) = coin::initialize<TestToken>(
            owner,
            string::utf8(b"Aptoswap Test"),
            string::utf8(b"tAPTS"),
            demicals,
            true
        );
        managed_coin::register<TestToken>(test_token_owner);
        move_to(test_token_owner, TestTokenCapabilities{
           mint: test_mint_cap,
           burn: test_burn_cap,
           freeze: test_freeze_cap,
        });

        // Move the pool account address to the SwapCap
        let aptos_cap = SwapCap { 
            pool_create_counter: 0,
            pool_create_event: account::new_event_handle<PoolCreateEvent>(owner),
            test_token_owner_cap: test_token_owner_cap
        };
        move_to(owner, aptos_cap);
    }

    public(friend) fun withdraw_bank_impl<X>(owner: &signer, amount: u64) acquires Bank {
        validate_admin(owner);

        let bank = borrow_global_mut<Bank<X>>(@Aptoswap);
        let max_amount = coin::value(&bank.coin);

        if (amount == 0) {
            amount = max_amount;
        };
        assert!(amount <= max_amount, ENotEnoughBalance);

        let c = coin::extract(&mut bank.coin, amount);

        let owner_addr = signer::address_of(owner);
        register_coin_if_needed<X>(owner);
        coin::deposit(owner_addr, c);

        event::emit_event(&mut bank.coin_amount_event, CoinAmountEvent { 
            amount: coin::value(&bank.coin)
        });
    }

    public(friend) fun mint_test_token_impl(owner: &signer, amount: u64, recipient: address) acquires SwapCap, TestTokenCapabilities {
        assert!(amount > 0, EInvalidParameter);

        let owner_addr = signer::address_of(owner);

        let package_addr = type_info::account_address(&type_info::type_of<TestToken>());
        let aptos_cap = borrow_global_mut<SwapCap>(package_addr);
        let test_token_owner = &account::create_signer_with_capability(&aptos_cap.test_token_owner_cap);
        let test_token_caps = borrow_global_mut<TestTokenCapabilities>(signer::address_of(test_token_owner));

        let mint_coin = coin::mint(amount, &test_token_caps.mint);

        if (!coin::is_account_registered<TestToken>(owner_addr) && (owner_addr == recipient)) {
            managed_coin::register<TestToken>(owner);
        };
        coin::deposit(recipient, mint_coin);
    }

    public(friend) fun mint_token_impl(owner: &signer, amount: u64, recipient: address) {
        validate_admin(owner);

        assert!(amount > 0, EInvalidParameter);

        let owner_addr = signer::address_of(owner);
        if (!coin::is_account_registered<Token>(owner_addr) && (owner_addr == recipient)) {
            managed_coin::register<Token>(owner);
        };

        managed_coin::mint<Token>(owner, recipient, amount);
    }

    public(friend) fun create_pool_impl<X, Y>(owner: &signer, pool_type: u8, fee_direction: u8, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64, withdraw_fee: u64, amp: u64): address acquires SwapCap, Pool {
        validate_admin(owner);

        let owner_addr = signer::address_of(owner);

        assert!(fee_direction == EFeeDirectionX || fee_direction == EFeeDirectionY, EInvalidParameter);
        assert!(pool_type == EPoolTypeV2 || pool_type == EPoolTypeStableSwap, EInvalidParameter);
        
        assert!(lp_fee >= 0 && admin_fee >= 0 && incentive_fee >= 0 && connect_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee + incentive_fee + connect_fee < (BPS_SCALING as u64), EWrongFee);
        assert!(withdraw_fee < (BPS_SCALING as u64), EWrongFee);

        // Note: we restrict the owner to the admin, which is @Aptoswap in create_pool 
        let pool_account = owner;
        let pool_account_addr = owner_addr;
        assert!(pool_account_addr == @Aptoswap, EPermissionDenied); // We can delete it, leave it here

        let aptos_cap = borrow_global_mut<SwapCap>(owner_addr);
        let pool_index = aptos_cap.pool_create_counter;
        aptos_cap.pool_create_counter = aptos_cap.pool_create_counter + 1;

        // Check whether the pool we've created
        assert!(!exists<Pool<X, Y>>(pool_account_addr), EPoolDuplicate);

        // Get the coin scale for x and y, used for stable
        let stable_x_scale: u64 = 0;
        let stable_y_scale: u64 = 0;
        if (pool_type == EPoolTypeStableSwap) {
            
            let x_decimal = coin::decimals<X>();
            let y_decimal = coin::decimals<Y>();

            assert!(x_decimal <= STABLESWAP_COIN_MAX_DECIMAL && y_decimal <= STABLESWAP_COIN_MAX_DECIMAL, ECreatePoolStableCoinDecimalTooLarge);
            assert!(amp > 0, EInvalidParameter);

            stable_x_scale = pow10(STABLESWAP_COIN_MAX_DECIMAL - x_decimal);
            stable_y_scale = pow10(STABLESWAP_COIN_MAX_DECIMAL - x_decimal);
        };

        // Create pool and move
        let pool = Pool<X, Y> {
            index: pool_index,
            pool_type: pool_type,

            x: coin::zero<X>(),
            y: coin::zero<Y>(),
            lsp_supply: 0,

            fee_direction: fee_direction,

            admin_fee: admin_fee,
            lp_fee: lp_fee,
            incentive_fee: incentive_fee,
            connect_fee: connect_fee,
            withdraw_fee: withdraw_fee,

            stable_amp: amp,
            stable_x_scale: stable_x_scale,
            stable_y_scale: stable_y_scale,

            freeze: false,

            last_trade_time: 0,

            total_trade_x: 0,
            total_trade_y: 0,

            total_trade_24h_last_capture_time: 0,
            total_trade_x_24h: 0,
            total_trade_y_24h: 0,

            ksp_e8_sma: create_sma128(),

            swap_token_event: account::new_event_handle<SwapTokenEvent>(pool_account),
            liquidity_event: account::new_event_handle<LiquidityEvent>(pool_account),
            snapshot_event: account::new_event_handle<SnapshotEvent>(pool_account),

            snapshot_last_capture_time: 0
        };
        move_to(pool_account, pool);

        // Register coin if needed for pool account
        register_coin_if_needed<X>(pool_account);
        register_coin_if_needed<Y>(pool_account);
        if (!exists<Bank<X>>(pool_account_addr)) {
            move_to(pool_account, empty_bank<X>(pool_account));
        };
        if (!exists<Bank<Y>>(pool_account_addr)) {
            move_to(pool_account, empty_bank<Y>(pool_account));
        };


        // Initialize the LSP<X, Y> token and transfer the ownership to pool account 
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LSP<X, Y>>(
            owner, 
            string::utf8(b"Aptoswap Pool Token"),
            string::utf8(b"APTSLSP"),
            0, 
            true
        );
        let lsp_cap = LSPCapabilities<X, Y> {
            mint: mint_cap,
            freeze: freeze_cap,
            burn: burn_cap
         };
         move_to(pool_account, lsp_cap);

        // Register the lsp token for the pool account 
        managed_coin::register<LSP<X, Y>>(pool_account);

        let pool = borrow_global<Pool<X, Y>>(pool_account_addr);
        validate_lsp(pool);

        // Emit event
        event::emit_event(
            &mut aptos_cap.pool_create_event,
            PoolCreateEvent {
                index: pool_index
            }
        );

        pool_account_addr
    }
    
    public(friend) fun change_fee_impl<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64, incentive_fee: u64, connect_fee: u64) acquires Pool {
        validate_admin(owner);
        assert!(lp_fee >= 0 && admin_fee >= 0 && incentive_fee >= 0 && connect_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee + incentive_fee + connect_fee < (BPS_SCALING as u64), EWrongFee);

        // Check whether the pool we've created
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.admin_fee = admin_fee;
        pool.lp_fee = lp_fee;
        pool.incentive_fee = incentive_fee;
        pool.connect_fee = connect_fee;
    }

    public(friend) fun freeze_or_unfreeze_pool_impl<X, Y>(owner: &signer, freeze: bool) acquires Pool {
        validate_admin(owner);

        let pool_account_addr = @Aptoswap;
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.freeze = freeze;
    }

    public(friend) fun swap_x_to_y_direct_impl<X, Y>(in_coin: coin::Coin<X>, current_time: u64): coin::Coin<Y> acquires Pool, Bank {
        let pool_account_addr = @Aptoswap;

        let in_amount = coin::value(&in_coin);
        assert!(in_amount > 0, EInvalidParameter);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        if (pool.fee_direction == EFeeDirectionX) {
            collect_admin_fee(&mut in_coin, get_total_admin_fee(pool), current_time);
        };

        let fee_coin = collect_fee(&mut in_coin, get_total_lp_fee(pool));

        // Get the output amount
        let output_amount = compute_amount(
            coin::value(&in_coin),
            x_reserve_amt,
            y_reserve_amt,
        );

        // 2. pool.x = pool.x + x_remain_amt + x_lp
        coin::merge(&mut pool.x, in_coin);
        coin::merge(&mut pool.x, fee_coin);

        // 3. pool.y = pool.y - output_amount
        let out_coin = coin::extract(&mut pool.y, output_amount);
        if (pool.fee_direction == EFeeDirectionY) {
            collect_admin_fee(&mut out_coin, get_total_admin_fee(pool), current_time);
        };

        let k_after = compute_k(pool);  
        assert!(k_after >= k_before, EComputationError);

        // Emit swap event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: true,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );

        // Accumulate total_trade
        pool.total_trade_x = pool.total_trade_x + (in_amount as u128);
        pool.total_trade_y = pool.total_trade_y + (output_amount as u128);

        if (current_time > 0) {

            pool.last_trade_time = current_time;

            if (pool.total_trade_24h_last_capture_time + TOTAL_TRADE_24H_INTERVAL_SEC < current_time) {
                pool.total_trade_24h_last_capture_time = current_time;
                pool.total_trade_x_24h = 0;
                pool.total_trade_y_24h = 0;
            };

            pool.total_trade_x_24h = pool.total_trade_x_24h + (in_amount as u128);
            pool.total_trade_y_24h = pool.total_trade_y_24h + (output_amount as u128);

            // Emit snapshot event
            if (pool.snapshot_last_capture_time + SNAPSHOT_INTERVAL_SEC < current_time) {
                pool.snapshot_last_capture_time = current_time;
                event::emit_event(
                    &mut pool.snapshot_event,
                    SnapshotEvent {
                        x: coin::value(&pool.x),
                        y: coin::value(&pool.y)
                    }
                );
            };

            // Add ksp_e8 sma average
            let ksp_e8: u128 = k_after * NUMBER_1E8 / (pool.lsp_supply as u128);
            add_sma128(&mut pool.ksp_e8_sma, current_time, ksp_e8);
        };

        out_coin
    }

    public(friend) fun swap_x_to_y_impl<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64, current_time: u64): u64 acquires Pool, Bank {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);
        assert!(in_amount <= coin::balance<X>(user_addr), ENotEnoughBalance);

        let in_coin = coin::withdraw<X>(user, in_amount);
        let out_coin = swap_x_to_y_direct_impl<X, Y>(in_coin, current_time);
        let out_coin_value = coin::value(&out_coin);
        assert!(out_coin_value >= min_out_amount, ESlippageLimit);

        coin::deposit(user_addr, out_coin);

        out_coin_value
    }

    public(friend) fun swap_y_to_x_direct_impl<X, Y>(in_coin: coin::Coin<Y>, current_time: u64): coin::Coin<X> acquires Pool, Bank {
        let pool_account_addr = @Aptoswap;

        let in_amount = coin::value(&in_coin);
        assert!(in_amount > 0, EInvalidParameter);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        if (pool.fee_direction == EFeeDirectionY) {
            collect_admin_fee(&mut in_coin, get_total_admin_fee(pool), current_time);
        };

        let fee_coin = collect_fee(&mut in_coin, get_total_lp_fee(pool));

        // Get the output amount
        let output_amount = compute_amount(
            coin::value(&in_coin),
            y_reserve_amt,
            x_reserve_amt,
        );

        // 2. pool.y = pool.y + y_remain_amt + y_lp;
        coin::merge(&mut pool.y, in_coin);
        coin::merge(&mut pool.y, fee_coin);

        // 3. pool.x = pool.x - output_amount;
        let out_coin = coin::extract(&mut pool.x, output_amount);
        if (pool.fee_direction == EFeeDirectionX) {
            collect_admin_fee(&mut out_coin, get_total_admin_fee(pool), current_time);
        };

        let k_after = compute_k(pool); 
        assert!(k_after >= k_before, EComputationError);

        // Emit swap event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: false,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );

        // Accumulate total_trade
        pool.total_trade_y = pool.total_trade_y + (in_amount as u128);
        pool.total_trade_x = pool.total_trade_x + (output_amount as u128);

        if (current_time > 0) {

            pool.last_trade_time = current_time;

            if (pool.total_trade_24h_last_capture_time + TOTAL_TRADE_24H_INTERVAL_SEC < current_time) {
                pool.total_trade_24h_last_capture_time = current_time;
                pool.total_trade_x_24h = 0;
                pool.total_trade_y_24h = 0;
            };

            pool.total_trade_y_24h = pool.total_trade_y_24h + (in_amount as u128);
            pool.total_trade_x_24h = pool.total_trade_x_24h + (output_amount as u128);

            // Emit snapshot event
            if (pool.snapshot_last_capture_time + SNAPSHOT_INTERVAL_SEC < current_time) {
                pool.snapshot_last_capture_time = current_time;
                event::emit_event(
                    &mut pool.snapshot_event,
                    SnapshotEvent {
                        x: coin::value(&pool.x),
                        y: coin::value(&pool.y)
                    }
                );
            };

            // Add ksp_e8 sma average
            let ksp_e8: u128 = k_after * NUMBER_1E8 / (pool.lsp_supply as u128);
            add_sma128(&mut pool.ksp_e8_sma, current_time, ksp_e8);
        };

        out_coin
    }

    public(friend) fun swap_y_to_x_impl<X, Y>(user: &signer, in_amount: u64, min_out_amount: u64, current_time: u64): u64 acquires Pool, Bank {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);
        assert!(in_amount <= coin::balance<Y>(user_addr), ENotEnoughBalance);

        let in_coin = coin::withdraw<Y>(user, in_amount);
        let out_coin = swap_y_to_x_direct_impl<X, Y>(in_coin, current_time);
        let out_coin_value = coin::value(&out_coin);
        assert!(out_coin_value >= min_out_amount, ESlippageLimit);

        coin::deposit(user_addr, out_coin);

        out_coin_value
    }

    public(friend) fun route_swap_impl<X, Y, Z>(user: &signer, in_amount: u64, min_out_amount: u64, direction1: u8, direction2: u8, current_time: u64): u64 acquires Pool, Bank {
        assert!(in_amount > 0, EInvalidParameter);
        assert!(direction1 == ERouteSwapDirectionForward || direction1 == ERouteSwapDirectionReverse, EInvalidParameter);
        assert!(direction2 == ERouteSwapDirectionForward || direction2 == ERouteSwapDirectionReverse, EInvalidParameter);

        let user_addr = signer::address_of(user);

        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);
        register_coin_if_needed<Z>(user);

        assert!(in_amount <= coin::balance<X>(user_addr), ENotEnoughBalance);

        let in_coin = coin::withdraw<X>(user, in_amount);

        let route_coin = if (direction1 == ERouteSwapDirectionForward) { 
            swap_x_to_y_direct_impl<X, Y>(in_coin, current_time)
        } else { 
            swap_y_to_x_direct_impl<Y, X>(in_coin, current_time)
        };

        let out_coin = if (direction2 == ERouteSwapDirectionForward) {
            swap_x_to_y_direct_impl<Y, Z>(route_coin, current_time)
        } else {
            swap_y_to_x_direct_impl<Z, Y>(route_coin, current_time)
        };

        let out_coin_value = coin::value(&out_coin);
        assert!(out_coin_value >= min_out_amount, ESlippageLimit);

        coin::deposit(user_addr, out_coin);

        out_coin_value
    }

    public(friend) fun add_liquidity_impl<X, Y>(user: &signer, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {

        let pool_account_addr = @Aptoswap;

        let user_addr = signer::address_of(user);

        assert!(x_added > 0 && y_added > 0, EInvalidParameter);
        assert!(exists<Pool<X, Y>>(pool_account_addr), EPoolNotFound);
        assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(x_added <= coin::balance<X>(user_addr), ENotEnoughBalance);
        assert!(y_added <= coin::balance<Y>(user_addr), ENotEnoughBalance);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let share_minted = if (lsp_supply > 0) {
            // When it is not a intialized the deposit, we compute the amount of minted lsp by
            // not reducing the "token / lsp" value.

            // We should make the value "token / lsp" larger than the previous value before adding liqudity
            // Thus 
            // (token + dtoken) / (lsp + dlsp) >= token / lsp
            //  ==> (token + dtoken) * lsp >= token * (lsp + dlsp)
            //  ==> dtoken * lsdp >= token * dlsp
            //  ==> dlsp <= dtoken * lsdp / token
            //  ==> dslp = floor[dtoken * lsdp / token] <= dtoken * lsdp / token
            // We use the floor operation
            let x_shared_minted: u128 = ((x_added as u128) * (lsp_supply as u128)) / (x_amt as u128);
            let y_shared_minted: u128 = ((y_added as u128) * (lsp_supply as u128)) / (y_amt as u128);
            let share_minted: u128 = if (x_shared_minted < y_shared_minted) { x_shared_minted } else { y_shared_minted };
            let share_minted: u64 = (share_minted as u64);
            share_minted
        } else {
            // When it is a initialzed deposit, we compute using sqrt(x_added) * sqrt(y_added)
            let share_minted: u64 = sqrt(x_added) * sqrt(y_added);
            share_minted
        };


        // Transfer the X, Y to the pool and transfer 
        let mint_cap = &borrow_global<LSPCapabilities<X, Y>>(pool_account_addr).mint;

        // Depsoit the coin to user
        register_coin_if_needed<LSP<X, Y>>(user);
        coin::deposit<LSP<X, Y>>(
            user_addr,
            coin::mint<LSP<X, Y>>(
                share_minted,
                mint_cap
            )
        );
        // 1. pool.x = pool.x + x_added;
        coin::merge(&mut pool.x, coin::withdraw(user, x_added));
        // 2. pool.y = pool.y + y_added;
        coin::merge(&mut pool.y, coin::withdraw(user, y_added));
        pool.lsp_supply = pool.lsp_supply + share_minted;

        // Check:
        // x_amt / lsp_supply <= x_amt_after / lsp_supply_after
        //    ==> x_amt * lsp_supply_after <= x_amt_after * lsp_supply
        let (x_amt_after, y_amt_after, lsp_supply_after) = get_amounts(pool); {
            let x_amt_ = (x_amt as u128);
            let y_amt_ = (y_amt as u128);
            let lsp_supply_ = (lsp_supply as u128);
            let x_amt_after_ = (x_amt_after as u128);
            let y_amt_after_ = (y_amt_after as u128);
            let lsp_supply_after_ = (lsp_supply_after as u128);
            assert!(x_amt_ * lsp_supply_after_ <= x_amt_after_ * lsp_supply_, EComputationError);
            assert!(y_amt_ * lsp_supply_after_ <= y_amt_after_ * lsp_supply_, EComputationError);
        };

        validate_lsp(pool);

        event::emit_event(
            &mut pool.liquidity_event,
            LiquidityEvent {
                is_added: true,
                x_amount: x_added,
                y_amount: y_added,
                lsp_amount: share_minted
            }
        );
    }

    public(friend) fun remove_liquidity_impl<X, Y>(_user: &signer, _lsp_amount: u64) {
        assert!(false, EDeprecated);
    }

    public(friend) fun remove_liquidity_impl_v2<X, Y>(user: &signer, lsp_amount: u64, current_time: u64) acquires Pool, LSPCapabilities, Bank {

        let pool_account_addr = @Aptoswap;

        let user_addr = signer::address_of(user);

        assert!(lsp_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<LSP<X, Y>>(user_addr), ECoinNotRegister);
        assert!(lsp_amount <= coin::balance<LSP<X, Y>>(user_addr), ENotEnoughBalance);

        // Note: We don't need freeze check, user can still burn lsp token and get original token when pool
        // is freeze
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);

        // We should make the value "token / lsp" larger than the previous value before removing liqudity
        // Thus 
        // (token - dtoken) / (lsp - dlsp) >= token / lsp
        //  ==> (token - dtoken) * lsp >= token * (lsp - dlsp)
        //  ==> -dtoken * lsp >= -token * dlsp
        //  ==> dtoken * lsp <= token * dlsp
        //  ==> dtoken <= token * dlsp / lsp
        //  ==> dtoken = floor[token * dlsp / lsp] <= token * dlsp / lsp
        // We use the floor operation
        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let x_removed = ((x_amt as u128) * (lsp_amount as u128)) / (lsp_supply as u128);
        let y_removed = ((y_amt as u128) * (lsp_amount as u128)) / (lsp_supply as u128);

        let x_removed = (x_removed as u64);
        let y_removed = (y_removed as u64);

        let burn_cap = &borrow_global<LSPCapabilities<X, Y>>(pool_account_addr).burn;

        // 1. pool.x = pool.x - x_removed;
        let coin_x_removed = coin::extract(&mut pool.x, x_removed);
        // 2. pool.y = pool.y - y_removed;
        let coin_y_removed = coin::extract(&mut pool.y, y_removed);

        // Deposit the withdraw fee to the admin
        collect_admin_fee(&mut coin_x_removed, pool.withdraw_fee, current_time);
        collect_admin_fee(&mut coin_y_removed, pool.withdraw_fee, current_time);

        pool.lsp_supply = pool.lsp_supply - lsp_amount;
        register_coin_if_needed<X>(user);
        register_coin_if_needed<Y>(user);

        coin::deposit(user_addr, coin_x_removed);
        coin::deposit(user_addr, coin_y_removed);

        coin::burn_from<LSP<X, Y>>(user_addr, lsp_amount, burn_cap);

        // Check:
        // x_amt / lsp_supply <= x_amt_after / lsp_supply_after
        //    ==> x_amt * lsp_supply_after <= x_amt_after * lsp_supply
        let (x_amt_after, y_amt_after, lsp_supply_after) = get_amounts(pool); {
            let x_amt_ = (x_amt as u128);
            let y_amt_ = (y_amt as u128);
            let lsp_supply_ = (lsp_supply as u128);
            let x_amt_after_ = (x_amt_after as u128);
            let y_amt_after_ = (y_amt_after as u128);
            let lsp_supply_after_ = (lsp_supply_after as u128);
            assert!(x_amt_ * lsp_supply_after_ <= x_amt_after_ * lsp_supply_, EComputationError);
            assert!(y_amt_ * lsp_supply_after_ <= y_amt_after_ * lsp_supply_, EComputationError);
        };

        validate_lsp(pool);

        event::emit_event(
            &mut pool.liquidity_event,
            LiquidityEvent {
                is_added: false,
                x_amount: x_removed,
                y_amount: y_removed,
                lsp_amount: lsp_amount
            }
        );
    }
    // ============================================= Implementations =============================================

    // ============================================= Helper Function =============================================

    fun validate_admin(user: &signer) {
        // assert!(exists<SwapCap>(user_addr), EPermissionDenied);
        assert!(signer::address_of(user) == @Aptoswap, EPermissionDenied);
    }

    fun register_coin_if_needed<X>(user: &signer) {
        if (!coin::is_account_registered<X>(signer::address_of(user))) {
            managed_coin::register<X>(user);
        };
    }

    fun empty_bank<X>(owner: &signer): Bank<X> {
        Bank<X> {
            coin: coin::zero<X>(),
            coin_amount_event: account::new_event_handle<CoinAmountEvent>(owner),
            coin_amount_event_last_time: 0
        }
    }

    fun deposit_to_bank<X>(bank: &mut Bank<X>, c: coin::Coin<X>, current_time: u64) {
        // Merge coin
        coin::merge(&mut bank.coin, c);

        // Capture the event if needed
        if (current_time > 0) {
            if (bank.coin_amount_event_last_time + BANK_AMOUNT_SNAPSHOT_INTERVAL_SEC < current_time) {
                bank.coin_amount_event_last_time = current_time;
                event::emit_event(&mut bank.coin_amount_event, CoinAmountEvent { 
                    amount: coin::value(&bank.coin)
                });
            }
        }
    }

    public(friend) fun get_bank_balance<X>(): u64 acquires Bank {
        let bank = borrow_global_mut<Bank<X>>(@Aptoswap);
        coin::value(&bank.coin)
    }

    public(friend) fun is_swap_cap_exists(addr: address): bool {
        exists<SwapCap>(addr)
    }

    public(friend) fun is_pool_freeze<X, Y>(): bool acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.freeze
    }

    public(friend) fun get_pool_x<X, Y>(): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        coin::value(&pool.x)
    }

    public(friend) fun get_pool_y<X, Y>(): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        coin::value(&pool.y)
    }

    public(friend) fun get_pool_lsp_supply<X, Y>(): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.lsp_supply
    }

    public(friend) fun get_pool_admin_fee<X, Y>(): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.admin_fee
    }

    public(friend) fun get_pool_connect_fee<X, Y>(): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.connect_fee
    }

    public(friend) fun get_pool_lp_fee<X, Y>(): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.lp_fee
    }

    public(friend) fun get_pool_incentive_fee<X, Y>(): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(@Aptoswap);
        pool.incentive_fee
    }


    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - amount of current LSP
    public(friend) fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            coin::value(&pool.x),
            coin::value(&pool.y), 
            pool.lsp_supply
        )
    }

    public(friend) fun get_admin_balance<X>(): u64 {
        coin::balance<X>(@Aptoswap)
    }

    public(friend) fun get_total_lp_fee<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.lp_fee + pool.incentive_fee
    }

    public(friend) fun get_total_admin_fee<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.admin_fee + pool.connect_fee
    }

    /// Get current lsp supply in the pool
    public(friend) fun get_lsp_supply<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.lsp_supply
    }

    /// Given dx (dx > 0), x and y. Ensure the constant product 
    /// market making (CPMM) equation fulfills after swapping:
    /// (x + dx) * (y - dy) = x * y
    /// Due to the integter operation, we change the equality into
    /// inequadity operation, i.e:
    /// (x + dx) * (y - dy) >= x * y
    public(friend) fun compute_amount(dx: u64, x: u64, y: u64): u64 {
        // (x + dx) * (y - dy) >= x * y
        //    ==> y - dy >= (x * y) / (x + dx)
        //    ==> dy <= y - (x * y) / (x + dx)
        //    ==> dy <= (y * dx) / (x + dx)
        //    ==> dy = floor[(y * dx) / (x + dx)] <= (y * dx) / (x + dx)
       let (dx, x, y) = ((dx as u128), (x as u128), (y as u128));
        
        let numerator: u128 = y * dx;
        let denominator: u128 = x + dx;
        let dy: u128 = numerator / denominator;
        assert!(dy <= U64_MAX, EOperationOverflow);

        // Addition liqudity check, should not happen
        let k_after: u128 = (x + dx) * (y - dy);
        let k_before: u128 = x * y;
        assert!(k_after >= k_before, EComputationError);

        (dy as u64)
    }

    public(friend) fun compute_k<T1,T2>(pool: &Pool<T1, T2>): u128 {
        let (x_amt, y_amt, _) = get_amounts(pool);
        (x_amt as u128) * (y_amt as u128)
    }

    fun validate_lsp<X, Y>(pool: &Pool<X, Y>) {
        let lsp_supply_checked = *option::borrow(&coin::supply<LSP<X, Y>>());
        assert!(lsp_supply_checked == (pool.lsp_supply as u128), EComputationError);
    }

    public(friend) fun validate_lsp_from_address<X, Y>() acquires Pool {
        let pool_account_addr = @Aptoswap;
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let lsp_supply_checked = *option::borrow(&coin::supply<LSP<X, Y>>());
        assert!(lsp_supply_checked == (pool.lsp_supply as u128), EComputationError);
    }

    public(friend) fun collect_fee<T>(coin: &mut coin::Coin<T>, fee: u64): coin::Coin<T> {
        let x = (coin::value(coin) as u128);
        let fee = (fee as u128);
        
        let x_fee_value = (((x * fee) / BPS_SCALING) as u64);
        let x_fee = coin::extract(coin, x_fee_value);
        x_fee
    }

    public(friend) fun collect_admin_fee<T>(coin: &mut coin::Coin<T>, fee: u64, current_time: u64) acquires Bank {
        deposit_to_bank(
            borrow_global_mut<Bank<T>>(@Aptoswap),
            collect_fee(coin, fee),
            current_time
        );
    }

    // ============================================= Helper Function =============================================


    // ============================================= Utilities =============================================
    public(friend) fun sqrt(x: u64): u64 {
        let bit = 1u128 << 64;
        let res = 0u128;
        let x = (x as u128);

        while (bit != 0) {
            if (x >= res + bit) {
                x = x - (res + bit);
                res = (res >> 1) + bit;
            } else {
                res = res >> 1;
            };
            bit = bit >> 2;
        };

        (res as u64)
    }

    public(friend) fun get_seed_from_hint_and_index(hint: vector<u8>, index: u64): vector<u8> {
        vector::push_back(&mut hint, (((index & 0xff00000000000000u64) >> 56) as u8));
        vector::push_back(&mut hint, (((index & 0x00ff000000000000u64) >> 48) as u8));
        vector::push_back(&mut hint, (((index & 0x0000ff0000000000u64) >> 40) as u8));
        vector::push_back(&mut hint, (((index & 0x000000ff00000000u64) >> 32) as u8));
        vector::push_back(&mut hint, (((index & 0x00000000ff000000u64) >> 24) as u8));
        vector::push_back(&mut hint, (((index & 0x0000000000ff0000u64) >> 16) as u8));
        vector::push_back(&mut hint, (((index & 0x000000000000ff00u64) >> 8) as u8));
        vector::push_back(&mut hint, (((index & 0x00000000000000ffu64)) as u8));
        hint
    }

    public(friend) fun get_pool_seed_from_pool_index(pool_id: u64): vector<u8> {
        get_seed_from_hint_and_index(b"Aptoswap::Pool_", pool_id)
    }

    // ============================================= Utilities =============================================


    // ============================================= Stable Swap =============================================

    public fun ss_compute_next_d(amp: U256, d_init: U256, d_prod: U256, sum_x: U256): U256 {
        let n = from_u64(STABLESWAP_N_COINS);
        let ann = mul(amp, n); // ann = amp * N_COINS
        let leverage = mul(sum_x, ann); // leverage = sum_x * ann
        let numerator = mul(
            d_init,
            add(mul(d_prod, n), leverage)
        );
        let denominator = add(
            mul(
                d_init,
                sub(ann, one())
            ),
            mul(d_prod, add(n, one()))
        );

        div(numerator, denominator)
    }

    public fun ss_compute_d(amount_a: U256, amount_b: U256, amp: U256): U256 {
        let sum_x = add(amount_a, amount_b);
        if (is_zero(&sum_x)) {
            return zero()
        };

        let amount_a_times_coins = mul(amount_a, from_u64(STABLESWAP_N_COINS));
        let amount_b_times_coins = mul(amount_b, from_u64(STABLESWAP_N_COINS));

        let d_prev;
        let d = sum_x;

        let counter = 0;
        while (counter < 256) {
            let d_prod = d;
            d_prod = div(mul(d_prod, d), amount_a_times_coins);
            d_prod = div(mul(d_prod, d), amount_b_times_coins);
            d_prev = d;
            d = ss_compute_next_d(amp, d, d_prod, sum_x);

            if (less_or_equals(&abs_sub(d, d_prev), &one())) {
                break
            };

            counter = counter + 1;
        };

        d
    }

    public fun ss_compute_y(x: U256, d: U256, amp: U256): U256 {
        let n = from_u64(STABLESWAP_N_COINS);
        let ann = mul(amp, n);

        // sum' = prod' = x
        // c =  D ** (n + 1) / (n ** (2 * n) * prod' * A)
        let c = div(mul(d, d), mul(x, n));
        let c = div(mul(c, d), mul(ann, n));
        // b = sum' - (A*n**n - 1) * D / (A * n**n)
        let b = add(div(d, ann), x);

        // Solve for y by approximating: y**2 + b*y = c
        let y_prev: U256;
        let y = d;

        let counter = 0;
        while (counter < 256) {
            y_prev = y;
            // y = (y * y + c) / (2 * y + b - d);
            let y_numerator = add(mul(y, y), c);
            let y_denominator = sub(add(mul(y, from_u64(2)), b), d);
            y = div(y_numerator, y_denominator);

            if (less_or_equals(&abs_sub(y, y_prev), &one())) {
                break
            };

            counter = counter + 1;
        };

        y
    }

    public fun ss_swap_to(source_amount: U256, swap_source_amount: U256, swap_destination_amount: U256, amp: U256): U256 {
        let (dy, d_0) = ss_swap_to_internal(source_amount, swap_source_amount, swap_destination_amount, amp);
        let d_1 = ss_compute_d(
            add(source_amount, swap_source_amount),
            add(swap_destination_amount, dy),
            amp
        );
        assert!(greater_or_equals(&d_1, &d_0), EComputationError);
        dy
    }

    public fun ss_swap_to_internal(source_amount: U256, swap_source_amount: U256, swap_destination_amount: U256, amp: U256): (U256, U256) {
        // Returns the dy and d with previous amount
        let d = ss_compute_d(swap_source_amount, swap_destination_amount, amp);
        let y = ss_compute_y(
            add(swap_source_amount, source_amount),
            d,
            amp
        );
        // https://github.com/curvefi/curve-contract/blob/b0bbf77f8f93c9c5f4e415bce9cd71f0cdee960e/contracts/pool-templates/base/SwapTemplateBase.vy#L466
        let dy = sub(sub(swap_destination_amount, y), one());
        (dy, d)
    }

    public fun ss_compute_mint_amount_for_deposit(
        deposit_amount_a: U256, 
        deposit_amount_b: U256, 
        swap_amount_a: U256, 
        swap_amount_b: U256,
        pool_token_supply: U256,
        amp: U256
    ): U256 {
        // Initial invariant
        let d_0 = ss_compute_d(swap_amount_a, swap_amount_b, amp);
        
        let new_balances_0 = add(swap_amount_a, deposit_amount_a);
        let new_balances_1 = add(swap_amount_b, deposit_amount_b);
        
        // Invariant after change
        let d_1 = ss_compute_d(new_balances_0, new_balances_1, amp);

        if (less_or_equals(&d_1, &d_0)) {
            zero()
        }
        else {
            // d1 / (p + dp) >= d0 / p
            // ==> d1 * p >= d0 * (p + dp)
            // ==> (d1 - d0) p >= d0 dp
            // ==> dp <= (d1 - d0) p / d0
            // ==> dp = Floor[(d1 - d0) p / d0] <= (d1 - d0) p / d0
            let amount = div(mul(pool_token_supply, sub(d_1, d_0)), d_0);
            ss_validate_lsp_value_increase(d_0, d_1, pool_token_supply, add(pool_token_supply, amount));

            amount
        }
    }

    public fun ss_compute_withdraw_one(
        pool_token_amount: U256,
        pool_token_supply: U256,
        swap_base_amount: U256,  // Same denomination of token to be withdrawn
        swap_quote_amount: U256, // Counter denomination of token to be withdrawn
        amp: U256
    ): U256 {

        let d_0 = ss_compute_d(swap_base_amount, swap_quote_amount, amp);
        let d_1 = sub(d_0, div(mul(pool_token_amount, d_0), pool_token_supply));
        let new_swap_base_amount = ss_compute_y(swap_quote_amount, d_1, amp);

        let dy = sub(
            swap_base_amount,
            add(new_swap_base_amount, one())
        );

        ss_validate_lsp_value_increase(d_0, d_1, pool_token_supply, sub(pool_token_supply, pool_token_amount));

        dy
    }

    public fun ss_validate_lsp_value_increase(d_0: U256, d_1: U256, lsp_0: U256, lsp_1: U256) {
        // Validate the d per lsp not decreased
        assert!(
            greater_or_equals(
                &div(d_1, lsp_1),
                &div(d_0, lsp_0)
            ),
            EComputationError
        );
    }
    // ============================================= Stable Swap =============================================
}
