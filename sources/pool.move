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

    #[test_only]
    friend Aptoswap::pool_test;

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

    /// The integer scaling setting for fees calculation.
    const BPS_SCALING: u128 = 10000;
    /// The maximum number of u64
    const U64_MAX: u128 = 18446744073709551615;

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

    struct SwapCap has key {
        /// Points to the next pool id that should be used
        pool_create_counter: u64,
        pool_create_event: EventHandle<PoolCreateEvent>,
        /// The capability to get the account the could be used to generate a account that could used 
        /// for minting test token
        test_token_owner_cap: account::SignerCapability,
        /// The account address which holds all the pools
        pool_account_addr: address
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

    struct PoolAccount has key {
        /// The capability to get the shared pool account who owns all the pools that manage by the SwapCap
        cap: account::SignerCapability
    }

    struct Pool<phantom X, phantom Y> has key {
        /// The index of the pool
        index: u64,
        /// The balance of X token in the pool
        x: u64,
        /// The balance of token in the pool
        y: u64,
        /// The balance of X that admin collects
        x_admin: u64,
        /// The balance of token that admin collects
        y_admin: u64,
        /// The current lsp supply value as u64
        lsp_supply: u64,
        /// Admin fee is denominated in basis points, in bps
        admin_fee: u64,
        /// Liqudity fee is denominated in basis points, in bps
        lp_fee: u64,
        /// Whether the pool is freezed for swapping and adding liquidity
        freeze: bool,
        /// Swap token events
        swap_token_event: EventHandle<SwapTokenEvent>,
        /// Add liquidity events
        liquidity_event: EventHandle<LiquidityEvent>,
    }

    // ============================================= Entry points =============================================
    public entry fun initialize(owner: &signer, demicals: u8) {
        initialize_impl(owner, demicals);
    }

    public entry fun mint_token(owner: &signer, amount: u64, recipient: address) {
        mint_token_impl(owner, amount, recipient);
    }

    public entry fun mint_test_token(owner: &signer, amount: u64, recipient: address) acquires SwapCap, TestTokenCapabilities {
        mint_test_token_impl(owner, amount, recipient);
    }

    public entry fun create_pool<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64) acquires SwapCap, Pool, PoolAccount {
        let _ = create_pool_impl<X, Y>(owner, admin_fee, lp_fee);
    }

    public entry fun freeze_pool<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool {
        freeze_or_unfreeze_pool_impl<X, Y>(owner, pool_account_addr, true)
    }

    public entry fun unfreeze_pool<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool {
        freeze_or_unfreeze_pool_impl<X, Y>(owner, pool_account_addr, false)
    }

    public entry fun swap_x_to_y<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64, min_out_amount: u64) acquires Pool, PoolAccount {
        swap_x_to_y_impl<X, Y>(user, pool_account_addr, in_amount, min_out_amount);
    }

    public entry fun swap_y_to_x<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64, min_out_amount: u64) acquires Pool, PoolAccount {
        swap_y_to_x_impl<X, Y>(user, pool_account_addr, in_amount, min_out_amount);
    }

    public entry fun add_liquidity<X, Y>(user: &signer, pool_account_addr: address, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {
        add_liquidity_impl<X, Y>(user, pool_account_addr, x_added, y_added);
    }

    public entry fun remove_liquidity<X, Y>(user: &signer, pool_account_addr: address, lsp_amount: u64) acquires Pool, LSPCapabilities, PoolAccount {
        remove_liquidity_impl<X, Y>(user, pool_account_addr, lsp_amount);
    }

    public entry fun redeem_admin_balance<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool, PoolAccount {
        redeem_admin_balance_impl<X, Y>(owner, pool_account_addr);
    }
    // ============================================= Entry points =============================================


    // ============================================= Implementations =============================================
    public(friend) fun initialize_impl(owner: &signer, demicals: u8) {
        // let owner_addr = signer::address_of(owner);
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

        // Register the pool account and move the cap to itself
        let (pool_account, pool_account_cap) = account::create_resource_account(
            owner,
            get_seed_from_hint_and_index(b"Aptoswap::PoolAccount", 0)
        );
        let pool_account = &pool_account;
        let pool_account_addr = signer::address_of(pool_account);
        move_to(
            pool_account, 
            PoolAccount { 
                cap: pool_account_cap 
            }
        );

        // Move the pool account address to the SwapCap
        let aptos_cap = SwapCap { 
            pool_create_counter: 0,
            pool_create_event: account::new_event_handle<PoolCreateEvent>(owner),
            test_token_owner_cap: test_token_owner_cap,
            pool_account_addr: pool_account_addr
        };
        move_to(owner, aptos_cap);
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
        assert!(amount > 0, EInvalidParameter);
        let owner_addr = signer::address_of(owner);
        assert!(exists<SwapCap>(owner_addr), EPermissionDenied);

        // if (!coin::is_account_registered<Token>(owner_addr) && (owner_addr == recipient)) {
        //     managed_coin::register<Token>(owner);
        // };

        managed_coin::mint<Token>(owner, recipient, amount);
    }

    public(friend) fun create_pool_impl<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64): address acquires SwapCap, Pool, PoolAccount {
        let owner_addr = signer::address_of(owner);

        assert!(exists<SwapCap>(owner_addr), EPermissionDenied);
        assert!(lp_fee >= 0, EWrongFee);
        assert!(admin_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee < (BPS_SCALING as u64), EWrongFee);

        let aptos_cap = borrow_global_mut<SwapCap>(owner_addr);
        let pool_index = aptos_cap.pool_create_counter;
        aptos_cap.pool_create_counter = aptos_cap.pool_create_counter + 1;

        let pool_account_addr = aptos_cap.pool_account_addr;
        let pool_account_struct = borrow_global_mut<PoolAccount>(pool_account_addr);
        let pool_account = &account::create_signer_with_capability(&pool_account_struct.cap);

        // Check whether the pool we've created
        assert!(!exists<Pool<X, Y>>(pool_account_addr), EPoolDuplicate);

        // Create pool and move
        let pool = Pool<X, Y> {
            index: pool_index,
            x: 0,
            y: 0,
            x_admin: 0,
            y_admin: 0,
            lsp_supply: 0,
            admin_fee: admin_fee,
            lp_fee: lp_fee,
            freeze: false,
            swap_token_event: account::new_event_handle<SwapTokenEvent>(pool_account),
            liquidity_event: account::new_event_handle<LiquidityEvent>(pool_account),
        };
        move_to(pool_account, pool);

        // Register coin if needed for pool account
        if (!coin::is_account_registered<X>(pool_account_addr)) {
            managed_coin::register<X>(pool_account);
        };
        if (!coin::is_account_registered<Y>(pool_account_addr)) {
            managed_coin::register<Y>(pool_account);
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
        validate_fund(pool_account_addr, pool);
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

    public(friend) fun freeze_or_unfreeze_pool_impl<X, Y>(owner: &signer, pool_account_addr: address, freeze: bool) acquires Pool {
        let owner_addr = signer::address_of(owner);
        assert!(exists<SwapCap>(owner_addr), EPermissionDenied);
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.freeze = freeze;
    }

    public(friend) fun swap_x_to_y_impl<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64, min_out_amount: u64) acquires Pool, PoolAccount {

        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        if (!coin::is_account_registered<X>(user_addr)) {
            managed_coin::register<X>(user);
        };
        if (!coin::is_account_registered<Y>(user_addr)) {
            managed_coin::register<Y>(user);
        };
        // assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        // assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(in_amount <= coin::balance<X>(user_addr), ENotEnoughBalance);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let pool_account_struct = borrow_global_mut<PoolAccount>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool_account_struct.cap);
        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        let ComputeShareStruct { 
            remain: x_remain_amt,
            admin: x_admin_amt,
            lp: x_lp
        } = compute_share(pool, in_amount);

        // Get the output amount
        let output_amount = compute_amount(
            x_remain_amt,
            x_reserve_amt,
            y_reserve_amt,
        );
        assert!(output_amount >= min_out_amount, ESlippageLimit);

        pool.x_admin = pool.x_admin + x_admin_amt;
        pool.x = pool.x + x_remain_amt + x_lp;
        pool.y = pool.y - output_amount;

        coin::transfer<X>(user, pool_account_addr, in_amount);
        coin::transfer<Y>(pool_account_signer, user_addr, output_amount);

        let k_after = compute_k(pool);  
        assert!(k_after >= k_before, EComputationError);

        validate_fund(pool_account_addr, pool);

        // Emit event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: true,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );
    }

    public(friend) fun swap_y_to_x_impl<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64, min_out_amount: u64) acquires Pool, PoolAccount {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        if (!coin::is_account_registered<X>(user_addr)) {
            managed_coin::register<X>(user);
        };
        if (!coin::is_account_registered<Y>(user_addr)) {
            managed_coin::register<Y>(user);
        };
        // assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        // assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(in_amount <= coin::balance<Y>(user_addr), ENotEnoughBalance);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(pool.freeze == false, EPoolFreeze);

        let pool_account_struct = borrow_global_mut<PoolAccount>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool_account_struct.cap);
        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        let ComputeShareStruct { 
            remain: y_remain_amt,
            admin: y_admin_amt,
            lp: y_lp
        } = compute_share(pool, in_amount);

        // Get the output amount
        let output_amount = compute_amount(
            y_remain_amt,
            y_reserve_amt,
            x_reserve_amt,
        );
        assert!(output_amount >= min_out_amount, ESlippageLimit);

        pool.y_admin = pool.y_admin + y_admin_amt;
        pool.y = pool.y + y_remain_amt + y_lp;
        pool.x = pool.x - output_amount;

        coin::transfer<Y>(user, pool_account_addr, in_amount);
        coin::transfer<X>(pool_account_signer, user_addr, output_amount);

        let k_after = compute_k(pool);  
        assert!(k_after >= k_before, EComputationError);
        validate_fund(pool_account_addr, pool);

        // Emit event
        event::emit_event(
            &mut pool.swap_token_event,
            SwapTokenEvent {
                x_to_y: false,
                in_amount: in_amount,
                out_amount: output_amount
            }
        );
    }

    public(friend) fun add_liquidity_impl<X, Y>(user: &signer, pool_account_addr: address, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {

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
        coin::transfer<X>(user, pool_account_addr, x_added);
        coin::transfer<Y>(user, pool_account_addr, y_added);

        // Depsoit the coin to user
        if (!coin::is_account_registered<LSP<X, Y>>(user_addr)) {
            managed_coin::register<LSP<X, Y>>(user);
        };
        coin::deposit<LSP<X, Y>>(
            user_addr,
            coin::mint<LSP<X, Y>>(
                share_minted,
                mint_cap
            )
        );
        pool.x = pool.x + x_added;
        pool.y = pool.y + y_added;
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

        validate_fund(pool_account_addr, pool);
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

    public(friend) fun remove_liquidity_impl<X, Y>(user: &signer, pool_account_addr: address, lsp_amount: u64) acquires Pool, LSPCapabilities, PoolAccount {

        let user_addr = signer::address_of(user);

        assert!(lsp_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<LSP<X, Y>>(user_addr), ECoinNotRegister);
        assert!(lsp_amount <= coin::balance<LSP<X, Y>>(user_addr), ENotEnoughBalance);

        // Note: We don't need freeze check, user can still burn lsp token and get original token when pool
        // is freeze
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        
        let pool_account_struct = borrow_global_mut<PoolAccount>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool_account_struct.cap);

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
        pool.x = pool.x - x_removed;
        pool.y = pool.y - y_removed;
        pool.lsp_supply = pool.lsp_supply - lsp_amount;
        if (!coin::is_account_registered<X>(user_addr)) {
            managed_coin::register<X>(user);
        };
        if (!coin::is_account_registered<Y>(user_addr)) {
            managed_coin::register<Y>(user);
        };
        coin::transfer<X>(pool_account_signer, user_addr, x_removed);
        coin::transfer<Y>(pool_account_signer, user_addr, y_removed);
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

        validate_fund(pool_account_addr, pool);
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

    public(friend) fun redeem_admin_balance_impl<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool, PoolAccount {
        let owner_addr = signer::address_of(owner);
        assert!(exists<SwapCap>(owner_addr), EPermissionDenied);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_struct = borrow_global_mut<PoolAccount>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool_account_struct.cap);

        if (pool.x_admin > 0)
        {
            if (!coin::is_account_registered<X>(owner_addr)) {
                managed_coin::register<X>(owner);
            };
            coin::transfer<X>(pool_account_signer, owner_addr, pool.x_admin);
            pool.x_admin = 0;
        };

        if (pool.y_admin > 0)
        {
            if (!coin::is_account_registered<Y>(owner_addr)) {
                managed_coin::register<Y>(owner);
            };
            coin::transfer<Y>(pool_account_signer, owner_addr, pool.y_admin);
            pool.y_admin = 0;
        };

        validate_fund(pool_account_addr, pool);
    }
    // ============================================= Implementations =============================================

    // ============================================= Helper Function =============================================

    public(friend) fun is_swap_cap_exists(addr: address): bool {
        exists<SwapCap>(addr)
    }

    public(friend) fun is_pool_freeze<X, Y>(pool_account_addr: address): bool acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.freeze
    }

    public(friend) fun get_pool_x<X, Y>(pool_account_addr: address): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.x
    }

    public(friend) fun get_pool_y<X, Y>(pool_account_addr: address): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.y
    }

    public(friend) fun get_pool_x_admin<X, Y>(pool_account_addr: address): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.x_admin
    }

    public(friend) fun get_pool_y_admin<X, Y>(pool_account_addr: address): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.y_admin
    }

    public(friend) fun get_pool_lsp_supply<X, Y>(pool_account_addr: address): u64  acquires Pool { 
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.lsp_supply
    }

    public(friend) fun get_pool_admin_fee<X, Y>(pool_account_addr: address): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.admin_fee
    }

    public(friend) fun get_pool_lp_fee<X, Y>(pool_account_addr: address): u64 acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        pool.lp_fee
    }


    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - amount of current LSP
    public(friend) fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (pool.x, pool.y, pool.lsp_supply)
    }

    /// Get current lsp supply in the pool
    public(friend) fun get_lsp_supply<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.lsp_supply
    }

    /// Get The admin X and Y token balance value
    public(friend) fun get_admin_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
        (pool.x_admin, pool.y_admin)
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

    struct ComputeShareStruct {
        remain: u64,
        admin: u64,
        lp: u64
    }

    public(friend) fun compute_share<T1,T2>(pool: &Pool<T1, T2>, x: u64): ComputeShareStruct {

        let admin_fee = (pool.admin_fee as u128);
        let lp_fee = (pool.lp_fee as u128);
        let x = (x as u128);

        // When taking fee, we use ceil operation instead of floor operation
        let x_admin = ((x * admin_fee) + (BPS_SCALING - 1)) / BPS_SCALING;
        let x_lp = ((x * lp_fee) + (BPS_SCALING - 1)) / BPS_SCALING;

        // Sometimes x_admin + x_lp will larger than remain, we just throw error on computation
        let x_remain = x - x_admin - x_lp;

        ComputeShareStruct {
            remain: (x_remain as u64),
            admin: (x_admin as u64),
            lp: (x_lp as u64),
        }
    }

    public(friend) fun compute_k<T1,T2>(pool: &Pool<T1, T2>): u128 {
        let (x_amt, y_amt, _) = get_amounts(pool);
        (x_amt as u128) * (y_amt as u128)
    }

    public(friend) fun validate_fund<X, Y>(pool_account_addr: address, pool: &Pool<X, Y>) {
        // Validate the fund in the pool account is enough
        // We use >= instead of == to ensure that someone might directly transfer coin into the pool account
        assert!(coin::balance<X>(pool_account_addr) >= pool.x + pool.x_admin, EComputationError);
        assert!(coin::balance<Y>(pool_account_addr) >= pool.y + pool.y_admin, EComputationError);
    }

    #[test_only]
    public(friend) fun validate_fund_strict<X, Y>(pool_account_addr: address) acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        assert!(coin::balance<X>(pool_account_addr) == pool.x + pool.x_admin, EComputationError);
        assert!(coin::balance<Y>(pool_account_addr) == pool.y + pool.y_admin, EComputationError);
    }

    fun validate_lsp<X, Y>(pool: &Pool<X, Y>) {
        let lsp_supply_checked = *option::borrow(&coin::supply<LSP<X, Y>>());
        assert!(lsp_supply_checked == (pool.lsp_supply as u128), EComputationError);
    }

    public(friend) fun validate_lsp_from_address<X, Y>(pool_account_addr: address) acquires Pool {
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let lsp_supply_checked = *option::borrow(&coin::supply<LSP<X, Y>>());
        assert!(lsp_supply_checked == (pool.lsp_supply as u128), EComputationError);
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
}
