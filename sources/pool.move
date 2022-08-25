module Aptoswap::pool {
    use std::string;
    use std::signer;
    use std::vector;
    use std::option;
    use aptos_std::event::{ Self, EventHandle };
    use aptos_framework::managed_coin;
    use aptos_framework::coin;
    use aptos_framework::account;

    /// For when supplied Coin is zero.
    const EInvalidParameter: u64 = 13400;
    /// For when pool fee is set incorrectly.  Allowed values are: [0-10000)
    const EWrongFee: u64 = 134001;
    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 1340;
    /// For when initial LSP amount is zero.02
    const EShareEmpty: u64 = 13400;
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

    /// The integer scaling setting for fees calculation.
    const BPS_SCALING: u128 = 10000;
    /// The maximum number of u64
    const U64_MAX: u128 = 18446744073709551615;

    struct PoolCreateEvent has drop, store {
        pool_account_addr: address
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

    struct AptoswapCap has key {
        /// Points to the next pool id that should be used
        pool_id_counter: u64,
        pool_create_event: EventHandle<PoolCreateEvent>,
    }

    struct Token { }

    struct LSP<phantom X, phantom Y> {}

    struct LSPCapabilities<phantom X, phantom Y> has key {
        mint: coin::MintCapability<LSP<X, Y>>,
        freeze: coin::FreezeCapability<LSP<X, Y>>,
        burn: coin::BurnCapability<LSP<X, Y>>,
    }

    struct Pool<phantom X, phantom Y> has key {
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
        /// Capability
        pool_cap: account::SignerCapability,
        /// Swap token events
        swap_token_event: EventHandle<SwapTokenEvent>,
        /// Add liquidity events
        liquidity_event: EventHandle<LiquidityEvent>,
    }

    // ============================================= Entry points =============================================
    public entry fun initialize(owner: &signer, demicals: u8) {
        initialize_impl(owner, demicals);
    }
    public entry fun create_pool<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64) acquires AptoswapCap, Pool {
        let _ = create_pool_impl<X, Y>(owner, admin_fee, lp_fee);
    }
    public entry fun swap_x_to_y<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64) acquires Pool {
        swap_x_to_y_impl<X, Y>(user, pool_account_addr, in_amount);
    }

    public entry fun swap_y_to_x<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64) acquires Pool {
        swap_y_to_x_impl<X, Y>(user, pool_account_addr, in_amount);
    }

    public entry fun add_liquidity<X, Y>(user: &signer, pool_account_addr: address, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {
        add_liquidity_impl<X, Y>(user, pool_account_addr, x_added, y_added);
    }

    public entry fun remove_liquidity<X, Y>(user: &signer, pool_account_addr: address, lsp_amount: u64) acquires Pool, LSPCapabilities {
        remove_liquidity_impl<X, Y>(user, pool_account_addr, lsp_amount);
    }

    public entry fun redeem_admin_balance<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool {
        redeem_admin_balance_impl<X, Y>(owner, pool_account_addr);
    }
    // ============================================= Entry points =============================================


    // ============================================= Implementations =============================================
    fun initialize_impl(owner: &signer, demicals: u8) {
        // let owner_addr = signer::address_of(owner);
        managed_coin::initialize<Token>(
            owner,
            b"Aptoswap",
            b"APTS",
            demicals,
            true
        );
        managed_coin::register<Token>(owner);

        let aptos_cap = AptoswapCap { 
            pool_id_counter: 0,
            pool_create_event: event::new_event_handle<PoolCreateEvent>(owner)
        };
        move_to(owner, aptos_cap);
    }

    fun create_pool_impl<X, Y>(owner: &signer, admin_fee: u64, lp_fee: u64): address acquires AptoswapCap, Pool {
        let owner_addr = signer::address_of(owner);

        assert!(exists<AptoswapCap>(owner_addr), EPermissionDenied);
        assert!(lp_fee >= 0, EWrongFee);
        assert!(admin_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee < (BPS_SCALING as u64), EWrongFee);

        let aptos_cap = borrow_global_mut<AptoswapCap>(owner_addr);
        let pool_id = aptos_cap.pool_id_counter;
        aptos_cap.pool_id_counter = aptos_cap.pool_id_counter + 1;

        let (pool_account_signer, pool_account_cap) = account::create_resource_account(owner, get_pool_seed_from_pool_id(pool_id));
        let pool_account_addr = signer::address_of(&pool_account_signer);

        // Create pool and move
        let pool = Pool<X, Y> {
            x: 0,
            y: 0,
            x_admin: 0,
            y_admin: 0,
            lsp_supply: 0,
            admin_fee: admin_fee,
            lp_fee: lp_fee,
            pool_cap: pool_account_cap,
            swap_token_event: event::new_event_handle<SwapTokenEvent>(&pool_account_signer),
            liquidity_event: event::new_event_handle<LiquidityEvent>(&pool_account_signer),
        };
        move_to(&pool_account_signer, pool);

        // Transfer the balance to the pool account
        managed_coin::register<X>(&pool_account_signer);
        managed_coin::register<Y>(&pool_account_signer);

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
         move_to(&pool_account_signer, lsp_cap);

         // Register the lsp token for the pool account
         managed_coin::register<LSP<X, Y>>(&pool_account_signer);

        let pool = borrow_global<Pool<X, Y>>(pool_account_addr);
        validate_fund(pool_account_addr, pool);
        validate_lsp(pool);

        // Emit event
        event::emit_event(
            &mut aptos_cap.pool_create_event,
            PoolCreateEvent {
                pool_account_addr: pool_account_addr
            }
        );

        pool_account_addr
    }

    fun swap_x_to_y_impl<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64) acquires Pool {

        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(in_amount <= coin::balance<X>(user_addr), ENotEnoughBalance);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);
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

    fun swap_y_to_x_impl<X, Y>(user: &signer, pool_account_addr: address, in_amount: u64) acquires Pool {
        let user_addr = signer::address_of(user);

        assert!(in_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(in_amount <= coin::balance<Y>(user_addr), ENotEnoughBalance);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);
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

    fun add_liquidity_impl<X, Y>(user: &signer, pool_account_addr: address, x_added: u64, y_added: u64) acquires Pool, LSPCapabilities {

        let user_addr = signer::address_of(user);

        assert!(x_added > 0 && y_added > 0, EInvalidParameter);
        assert!(exists<Pool<X, Y>>(pool_account_addr), EInvalidParameter);
        assert!(coin::is_account_registered<X>(user_addr), ECoinNotRegister);
        assert!(coin::is_account_registered<Y>(user_addr), ECoinNotRegister);
        assert!(x_added <= coin::balance<X>(user_addr), ENotEnoughBalance);
        assert!(y_added <= coin::balance<Y>(user_addr), ENotEnoughBalance);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);


        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let share_minted = if (pool.lsp_supply > 0) {
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
            let x_shared_minted: u128 = ((x_added as u128) * (pool.lsp_supply as u128)) / (x_amt as u128);
            let y_shared_minted: u128 = ((y_added as u128) * (pool.lsp_supply as u128)) / (y_amt as u128);
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

    fun remove_liquidity_impl<X, Y>(user: &signer, pool_account_addr: address, lsp_amount: u64) acquires Pool, LSPCapabilities {

        let user_addr = signer::address_of(user);

        assert!(lsp_amount > 0, EInvalidParameter);
        assert!(coin::is_account_registered<LSP<X, Y>>(user_addr), ECoinNotRegister);
        assert!(lsp_amount <= coin::balance<LSP<X, Y>>(user_addr), ENotEnoughBalance);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);

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

    fun redeem_admin_balance_impl<X, Y>(owner: &signer, pool_account_addr: address) acquires Pool {
        let owner_addr = signer::address_of(owner);
        assert!(exists<AptoswapCap>(owner_addr), EPermissionDenied);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);

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

    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - amount of current LSP
    public fun get_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (pool.x, pool.y, pool.lsp_supply)
    }

    /// Get current lsp supply in the pool
    public fun get_lsp_supply<X, Y>(pool: &Pool<X, Y>): u64 {
        pool.lsp_supply
    }

    /// Get The admin X and Y token balance value
    public fun get_admin_amounts<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
        (pool.x_admin, pool.y_admin)
    }

    /// Given dx (dx > 0), x and y. Ensure the constant product 
    /// market making (CPMM) equation fulfills after swapping:
    /// (x + dx) * (y - dy) = x * y
    /// Due to the integter operation, we change the equality into
    /// inequadity operation, i.e:
    /// (x + dx) * (y - dy) >= x * y
    public fun compute_amount(dx: u64, x: u64, y: u64): u64 {
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

    public fun compute_share<T1,T2>(pool: &Pool<T1, T2>, x: u64): ComputeShareStruct {

        let admin_fee = (pool.admin_fee as u128);
        let lp_fee = (pool.lp_fee as u128);
        let x = (x as u128);

        // When taking fee, we use ceil operation instead of floor operation
        let x_admin = ((x * admin_fee) + (BPS_SCALING - 1)) / BPS_SCALING;
        let x_lp = ((x * lp_fee) + (BPS_SCALING - 1)) / BPS_SCALING;
        let x_remain = x - x_admin - x_lp;

        ComputeShareStruct {
            remain: (x_remain as u64),
            admin: (x_admin as u64),
            lp: (x_lp as u64),
        }
    }

    public fun compute_k<T1,T2>(pool: &Pool<T1, T2>): u128 {
        let (x_amt, y_amt, _) = get_amounts(pool);
        (x_amt as u128) * (y_amt as u128)
    }

    fun validate_fund<X, Y>(pool_account_addr: address, pool: &Pool<X, Y>) {
        // Validate the fund in the pool account is enough
        // We use >= instead of == to ensure that someone might directly transfer coin into the pool account
        assert!(coin::balance<X>(pool_account_addr) >= pool.x + pool.x_admin, EComputationError);
        assert!(coin::balance<Y>(pool_account_addr) >= pool.y + pool.y_admin, EComputationError);
    }

    #[test_only]
    fun validate_fund_strict<X, Y>(pool_account_addr: address, pool: &Pool<X, Y>) {
        assert!(coin::balance<X>(pool_account_addr) == pool.x + pool.x_admin, EComputationError);
        assert!(coin::balance<Y>(pool_account_addr) == pool.y + pool.y_admin, EComputationError);
    }

    fun validate_lsp<X, Y>(pool: &Pool<X, Y>) {
        let lsp_supply_checked = *option::borrow(&coin::supply<LSP<X, Y>>());
        assert!(lsp_supply_checked == (pool.lsp_supply as u128), EComputationError);
    }

    // ============================================= Helper Function =============================================


    // ============================================= Utilities =============================================
    fun sqrt(x: u64): u64 {
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

    fun get_pool_seed_from_pool_id(pool_id: u64): vector<u8> {
        let seed = b"Aptoswap::Pool_";
        vector::push_back(&mut seed, (((pool_id & 0xff00000000000000u64) >> 56) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x00ff000000000000u64) >> 48) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x0000ff0000000000u64) >> 40) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x000000ff00000000u64) >> 32) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x00000000ff000000u64) >> 24) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x0000000000ff0000u64) >> 16) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x000000000000ff00u64) >> 8) as u8));
        vector::push_back(&mut seed, (((pool_id & 0x00000000000000ffu64)) as u8));
        seed
    }

    // ============================================= Utilities =============================================


    // ============================================= Test Case =============================================
    #[test(admin = @Aptoswap)]
    fun test_create_pool(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_create_pool_impl(&admin); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134007)] // EPermissionDenied
    fun test_create_pool_with_non_admin(admin: signer, guy: signer) acquires AptoswapCap, Pool {
        test_create_pool_with_non_admin_impl(&admin, &guy);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_swap_x_to_y(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        // test_swap_x_to_y_impl(&admin, &guy, false);
        test_swap_x_to_y_default_impl(&admin, &guy);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134007)] // EPermissionDenied
    fun test_swap_x_to_y_account_no_permission(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: true,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_swap_x_to_y_balance_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: true,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_swap_x_to_y_balance_dst_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: true,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_swap_x_to_y_balance_empty(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: true,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_swap_x_to_y_balance_not_enough(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: true,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_swap_y_to_x(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        // test_swap_x_to_y_impl(&admin, &guy, false);
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134007)] // EPermissionDenied
    fun test_swap_y_to_x_account_no_permission(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: true,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_swap_y_to_x_balance_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: true,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_swap_y_to_x_balance_dst_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: true,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_swap_y_to_x_balance_empty(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: true,
                check_balance_not_enough: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_swap_y_to_x_balance_not_enough(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_y_to_x_impl(
            &admin, 
            &guy, 
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: true,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_add_liquidity_check_x_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_impl(
            &admin, &guy, TEST_X_AMT, TEST_Y_AMT, TEST_LSP_AMT,
            TestAddLiqudityConfig {
                check_x_not_register: true,
                check_y_not_register: false,
                check_x_zero: false,
                check_y_zero: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_add_liquidity_check_y_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_impl(
            &admin, &guy, TEST_X_AMT, TEST_Y_AMT, TEST_LSP_AMT,
            TestAddLiqudityConfig {
                check_x_not_register: false,
                check_y_not_register: true,
                check_x_zero: false,
                check_y_zero: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_add_liquidity_check_x_zero(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_impl(
            &admin, &guy, TEST_X_AMT, TEST_Y_AMT, TEST_LSP_AMT,
            TestAddLiqudityConfig {
                check_x_not_register: false,
                check_y_not_register: false,
                check_x_zero: true,
                check_y_zero: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_add_liquidity_check_y_zero(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_impl(
            &admin, &guy, TEST_X_AMT, TEST_Y_AMT, TEST_LSP_AMT,
            TestAddLiqudityConfig {
                check_x_not_register: false,
                check_y_not_register: false,
                check_x_zero: false,
                check_y_zero: true,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_1(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT, TEST_Y_AMT, TEST_LSP_AMT);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_2(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT, TEST_Y_AMT + TEST_Y_AMT / 3, TEST_LSP_AMT);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_3(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT, 2 * TEST_Y_AMT, TEST_LSP_AMT);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_4(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT, 1, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_5(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, 1, TEST_Y_AMT, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_6(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT / 2, TEST_Y_AMT / 3, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_7(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT / 3, TEST_Y_AMT / 2, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_8(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT * 2, TEST_Y_AMT * 3, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_add_liquidity_case_9(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_default_impl(&admin, &guy, TEST_X_AMT * 3, TEST_Y_AMT * 2, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134009)] // ECoinNotRegister
    fun test_withdraw_case_check_lsp_not_register(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_impl(
            &admin, 
            &guy,
            0,
            WithdrawLiqudityConfig {
                check_lsp_not_register: true,
                check_lsp_zero: false,
                check_lsp_amount_larger: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_withdraw_case_check_lsp_zero(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_impl(
            &admin, 
            &guy,
            0,
            WithdrawLiqudityConfig {
                check_lsp_not_register: false,
                check_lsp_zero: true,
                check_lsp_amount_larger: false,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)] 
    #[expected_failure(abort_code = 134008)] // ENotEnoughBalance
    fun test_withdraw_case_check_lsp_amount_larger(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_impl(
            &admin, 
            &guy,
            0,
            WithdrawLiqudityConfig {
                check_lsp_not_register: false,
                check_lsp_zero: false,
                check_lsp_amount_larger: true,
            }
        );
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_1(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_withdraw_liquidity_default_impl(&admin, &guy, 0);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_2(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, 1); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_3(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, 10); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_4(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, 100); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_5(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, 1000); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_6(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, 10000); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_7(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, TEST_LSP_AMT / 6); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_8(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, TEST_LSP_AMT / 3); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_9(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, TEST_LSP_AMT / 2); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_10(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, TEST_LSP_AMT * 2 / 3); 
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_withdraw_case_11(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool { 
        test_withdraw_liquidity_default_impl(&admin, &guy, TEST_LSP_AMT - 1); 
    }

    #[test(admin = @Aptoswap)] 
    fun test_amm_simulate_1000(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_amm_simulate_1000_impl(&admin);
    }

    #[test(admin = @Aptoswap)] 
    fun test_amm_simulate_3000(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_amm_simulate_3000_impl(&admin);
    }

    #[test(admin = @Aptoswap)] 
    fun test_amm_simulate_5000(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_amm_simulate_5000_impl(&admin);
    }

    #[test(admin = @Aptoswap)] 
    fun test_amm_simulate_10000(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_amm_simulate_10000_impl(&admin);
    }

    // ============================================= Test Case =============================================

    struct TX { }
    struct TY { }
    struct TZ { }
    struct TW { }

    const TEST_Y_AMT: u64 = 1000000000;
    const TEST_X_AMT: u64 = 1000000;
    const TEST_LSP_AMT: u64 = 31622000;

    fun test_create_pool_impl(admin: &signer) acquires AptoswapCap, LSPCapabilities, Pool {
        account::create_account(signer::address_of(admin));
        let admin_addr = signer::address_of(admin);
        test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);

        assert!(coin::balance<LSP<TX, TY>>(admin_addr) == TEST_LSP_AMT, 0);
    }

    fun test_create_pool_with_non_admin_impl(admin: &signer, guy: &signer) acquires AptoswapCap, Pool {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);
        let _ = create_pool_impl<TZ, TW>(guy, 5, 25);
    }

    struct TestSwapConfigStruct has copy, drop {
        check_account_no_permision: bool,
        check_balance_not_register: bool,
        check_balance_dst_not_register: bool,
        check_balance_empty: bool,
        check_balance_not_enough: bool,
    }

    fun test_swap_x_to_y_default_impl(admin: &signer, guy: &signer): address acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(
            admin, guy,
            TestSwapConfigStruct {
                check_account_no_permision: false,
                check_balance_not_register: false,
                check_balance_dst_not_register: false,
                check_balance_empty: false,
                check_balance_not_enough: false,
            }
        )
    }

    fun test_swap_x_to_y_impl(admin: &signer, guy: &signer, config: TestSwapConfigStruct): address acquires AptoswapCap, LSPCapabilities, Pool {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);

        // Create pool
        let pool_account_addr = test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);

        if (!config.check_balance_not_register) {
            managed_coin::register<TX>(guy);

            if (!config.check_balance_empty) {
                if (!config.check_balance_not_enough) {
                    managed_coin::mint<TX>(admin, guy_addr, 5000);
                }
                else {
                    managed_coin::mint<TX>(admin, guy_addr, 4999);
                };
            };
        };
        if (!config.check_balance_dst_not_register) {
            managed_coin::register<TY>(guy);
        };

        swap_x_to_y_impl<TX, TY>(guy, pool_account_addr, 5000);

        // Check pool balance and guy balance
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        validate_fund_strict(pool_account_addr, pool);
        validate_lsp(pool);
        assert!(coin::balance<TY>(guy_addr) == 4959282, 0);
        assert!(pool.x == 1004997, 1);
        assert!(pool.y == 995040718, 2);
        assert!(pool.x_admin == 3, 3);
        assert!(pool.y_admin == 0, 4);

        // Redeem the profit
        let (check_user, check_user_addr) = if (config.check_account_no_permision) { (guy, guy_addr) } else { (admin,admin_addr) };
        let old_balance_tx = coin::balance<TX>(admin_addr);
        let old_balance_ty = coin::balance<TY>(admin_addr);
        
        redeem_admin_balance_impl<TX, TY>(check_user, pool_account_addr);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        assert!(coin::balance<TX>(check_user_addr) == old_balance_tx + 3, 0);
        assert!(coin::balance<TY>(check_user_addr) == old_balance_ty, 0);
        assert!(pool.x_admin == 0, 0);
        assert!(pool.y_admin == 0, 0);
        validate_fund_strict(pool_account_addr, pool);
        validate_lsp(pool);

        pool_account_addr
    }

    fun test_swap_y_to_x_impl(admin: &signer, guy: &signer, config: TestSwapConfigStruct): address acquires AptoswapCap, LSPCapabilities, Pool {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);

        // Create pool
        let pool_account_addr = test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);

        if (!config.check_balance_not_register) {
            managed_coin::register<TY>(guy);

            if (!config.check_balance_empty) {
                if (!config.check_balance_not_enough) {
                    managed_coin::mint<TY>(admin, guy_addr, 5000000);
                }
                else {
                    managed_coin::mint<TY>(admin, guy_addr, 5000000 - 1);
                };
            };
        };
        if (!config.check_balance_dst_not_register) {
            managed_coin::register<TX>(guy);
        };

        swap_y_to_x_impl<TX, TY>(guy, pool_account_addr, 5000000);

        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        validate_fund_strict(pool_account_addr, pool);
        validate_lsp(pool);
        assert!(coin::balance<TX>(guy_addr) == 4960, 0);
        assert!(pool.x == 995040, 1);
        assert!(pool.y == 1004997500, 2);
        assert!(pool.x_admin == 0, 3);
        assert!(pool.y_admin == 2500, 4);

        // Redeem the profit
        let (check_user, check_user_addr) = if (config.check_account_no_permision) { (guy, guy_addr) } else { (admin,admin_addr) };
        let old_balance_tx = coin::balance<TX>(admin_addr);
        let old_balance_ty = coin::balance<TY>(admin_addr);
        
        redeem_admin_balance_impl<TX, TY>(check_user, pool_account_addr);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        assert!(coin::balance<TX>(check_user_addr) == old_balance_tx, 0);
        assert!(coin::balance<TY>(check_user_addr) == old_balance_ty + 2500, 0);
        assert!(pool.x_admin == 0, 0);
        assert!(pool.y_admin == 0, 0);
        validate_fund_strict(pool_account_addr, pool);
        validate_lsp(pool);

        pool_account_addr
    }

    struct TestAddLiqudityConfig has copy, drop {
        check_x_not_register: bool,
        check_y_not_register: bool,
        check_x_zero: bool,
        check_y_zero: bool
    }

    fun test_add_liquidity_default_impl(admin: &signer, guy: &signer, x_added: u64, y_added: u64, checked: u64) acquires AptoswapCap, LSPCapabilities, Pool {
        test_add_liquidity_impl(admin, guy, x_added, y_added, checked, TestAddLiqudityConfig {
            check_x_not_register: false,
            check_y_not_register: false,
            check_x_zero: false,
            check_y_zero: false,
        });
    }

    fun test_add_liquidity_impl(admin: &signer, guy: &signer, x_added: u64, y_added: u64, checked: u64, config: TestAddLiqudityConfig) acquires AptoswapCap, LSPCapabilities, Pool {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);

        let pool_account_addr = test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        let x_pool = pool.x;
        let y_pool = pool.y;
        let lsp_pool = pool.lsp_supply;

        if (!config.check_x_not_register) {
            managed_coin::register<TX>(guy);
            if (!config.check_x_zero) {
                managed_coin::mint<TX>(admin, guy_addr, x_added);
            };
        };
        if (!config.check_y_not_register) {
            managed_coin::register<TY>(guy);
            if (!config.check_y_zero) {
                managed_coin::mint<TY>(admin, guy_addr, y_added);
            };
        };

        add_liquidity_impl<TX, TY>(guy, pool_account_addr, x_added, y_added);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        validate_fund_strict(pool_account_addr, pool);
        validate_lsp(pool);

        let lsp_checked_x = (x_added as u128) * (lsp_pool as u128) / (x_pool as u128);
        let lsp_checked_y = (y_added as u128) * (lsp_pool as u128) / (y_pool as u128);
        let lsp_checked = if (lsp_checked_x < lsp_checked_y) { lsp_checked_x } else { lsp_checked_y };
        let checked = (if (checked > 0) { checked } else { (lsp_checked as u64) });

        assert!(coin::is_account_registered<LSP<TX, TY>>(guy_addr), 0);
        assert!(coin::balance<LSP<TX, TY>>(guy_addr) == checked, 0);
    }

    struct WithdrawLiqudityConfig has copy, drop {
        check_lsp_not_register: bool,
        check_lsp_zero: bool,
        check_lsp_amount_larger: bool
    }

    fun test_withdraw_liquidity_default_impl(admin: &signer, guy: &signer, lsp_left: u64) acquires AptoswapCap, LSPCapabilities, Pool {
        test_withdraw_liquidity_impl(admin, guy, lsp_left, WithdrawLiqudityConfig {
            check_lsp_not_register: false,
            check_lsp_zero: false,
            check_lsp_amount_larger: false
        })
    }

    fun test_withdraw_liquidity_impl(admin: &signer, guy: &signer, lsp_left: u64, config: WithdrawLiqudityConfig) acquires AptoswapCap, LSPCapabilities, Pool {
        let pool_account_addr = test_swap_x_to_y_default_impl(admin, guy);
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);

        // Transfer the lsp token to the guy
        if (!config.check_lsp_not_register) {
            if (!coin::is_account_registered<LSP<TX, TY>>(guy_addr)) {
                managed_coin::register<LSP<TX, TY>>(guy);
            };
            if (!config.check_lsp_zero) {
                coin::transfer<LSP<TX, TY>>(admin, guy_addr, coin::balance<LSP<TX, TY>>(admin_addr));
            };
        };

        let lsp_take = TEST_LSP_AMT - lsp_left;
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        let (x_pool_ori_amt, y_pool_ori_amt, _) = get_amounts(pool);
        let old_balance_tx = coin::balance<TX>(guy_addr);
        let old_balance_ty = coin::balance<TY>(guy_addr);
        
        if (!config.check_lsp_amount_larger) {
            remove_liquidity_impl<TX, TY>(guy, pool_account_addr, lsp_take);
        } else {
            remove_liquidity_impl<TX, TY>(guy, pool_account_addr, lsp_take + 1);
        };

        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        validate_fund_strict<TX, TY>(pool_account_addr, pool);
        validate_lsp<TX, TY>(pool);

        let (x_pool_amt, y_pool_amt, lsp_supply) = get_amounts(pool);
        let x_guy_amt_chekced = (((1004997 as u128) * (lsp_take as u128) / (TEST_LSP_AMT as u128)) as u64);
        let y_guy_amt_checked = (((995040718 as u128) * (lsp_take as u128) / (TEST_LSP_AMT as u128)) as u64);

        let new_balance_tx = coin::balance<TX>(guy_addr);
        let new_balance_ty = coin::balance<TY>(guy_addr);

        assert!(new_balance_tx - old_balance_tx == x_guy_amt_chekced , 0);
        assert!(new_balance_ty - old_balance_ty == y_guy_amt_checked, 1);
        assert!(lsp_supply == lsp_left, 2);
        assert!(x_pool_amt + x_guy_amt_chekced == x_pool_ori_amt, 3);
        assert!(y_pool_amt + y_guy_amt_checked == y_pool_ori_amt, 4);
    }

    #[test_only]
    fun test_utils_create_pool(admin: &signer, init_x_amt: u64, init_y_amt: u64): address acquires AptoswapCap, LSPCapabilities, Pool {
        let admin_addr = signer::address_of(admin);

        initialize_impl(admin, 8);

        // Check registe token and borrow capability
        assert!(coin::is_coin_initialized<Token>(), 0);
        assert!(exists<AptoswapCap>(admin_addr), 0);

        managed_coin::initialize<TX>(admin, b"TX", b"TX", 10, true);
        managed_coin::initialize<TY>(admin, b"TY", b"TY", 10, true);
        assert!(coin::is_coin_initialized<TX>(), 1);
        assert!(coin::is_coin_initialized<TY>(), 2);

        // Creat the pool
        let pool_account_addr = create_pool_impl<TX, TY>(admin, 5, 25);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        assert!(coin::is_coin_initialized<LSP<TX, TY>>(), 6);
        assert!(coin::is_account_registered<LSP<TX, TY>>(pool_account_addr), 7);
        assert!(coin::balance<TX>(pool_account_addr) == 0, 0);
        assert!(coin::balance<TY>(pool_account_addr) == 0, 0);
        assert!(coin::balance<LSP<TX, TY>>(pool_account_addr) == 0, 0);
        assert!(pool.x == 0, 0);
        assert!(pool.y == 0, 0);
        assert!(pool.x_admin == 0, 0);
        assert!(pool.y_admin == 0, 0);
        assert!(pool.lsp_supply == 0, 0);
        assert!(pool.admin_fee == 5, 0);
        assert!(pool.lp_fee == 25, 0);

        validate_fund_strict<TX, TY>(pool_account_addr, pool);
        validate_lsp<TX, TY>(pool);

        // Register & mint some coin
        managed_coin::register<TX>(admin);
        managed_coin::register<TY>(admin);
        assert!(coin::is_account_registered<TX>(admin_addr), 3);
        assert!(coin::is_account_registered<TY>(admin_addr), 4);
        managed_coin::mint<TX>(admin, admin_addr, init_x_amt);
        managed_coin::mint<TY>(admin, admin_addr, init_y_amt);
        assert!(coin::balance<TX>(admin_addr) == init_x_amt, 5);
        assert!(coin::balance<TY>(admin_addr) == init_y_amt, 5);
        add_liquidity_impl<TX, TY>(admin, pool_account_addr, init_x_amt, init_y_amt);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        validate_fund_strict<TX, TY>(pool_account_addr, pool);
        validate_lsp<TX, TY>(pool);
        
        let _ = borrow_global<LSPCapabilities<TX, TY>>(pool_account_addr);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        assert!(coin::balance<LSP<TX, TY>>(admin_addr) > 0, 8);
        assert!(coin::balance<LSP<TX, TY>>(admin_addr) == get_lsp_supply(pool), 8);

        // Use == for testing
        assert!(pool.x_admin == 0 && pool.y_admin == 0, 9);
        assert!(coin::balance<TX>(pool_account_addr) == pool.x, 9);
        assert!(coin::balance<TY>(pool_account_addr) == pool.y, 9);
        assert!(pool.x == init_x_amt, 9);
        assert!(pool.y == init_y_amt, 10);

        pool_account_addr
    }

    struct AmmSimulationStepData has copy, drop {
        /// The number of X token added in current step
        x_added: u64,
        /// The number of Y token added in current step
        y_added: u64,
        /// The number of X token that should currently in the pool
        x_checked: u64,
        /// The number of Y token that should currently in the pool
        y_checked: u64 
    }

    struct AmmSimulationData has copy, drop {
        /// The initial X token for the pool
        x_init: u64,
        /// The initial Y token for the pool
        y_init: u64,
        /// The simulation step data
        data: vector<AmmSimulationStepData>
    }

    #[test_only]
    /// Getting a series of simulation data and check whether the simulation in the pool is right
    fun test_utils_amm_simulate(admin: &signer, s: &AmmSimulationData) acquires AptoswapCap, LSPCapabilities, Pool {
        let admin_addr = signer::address_of(admin);
        account::create_account(admin_addr);

        let pool_account_addr = test_utils_create_pool(admin, s.x_init, s.y_init);

        let i: u64 = 0;
        let data_legnth: u64 = vector::length(&s.data);

        while (i < data_legnth) 
        {
            let info = vector::borrow(&s.data, i);
            // Do the simulatio

            // let (x_amt_ori, y_amt_ori, _) = pool::get_amounts(pool_mut);
            if (info.x_added > 0) 
            {
                managed_coin::mint<TX>(admin, admin_addr, info.x_added);
                swap_x_to_y_impl<TX, TY>(admin, pool_account_addr, info.x_added);
            }
            else if (info.y_added > 0) 
            {
                managed_coin::mint<TY>(admin, admin_addr, info.y_added);
                swap_y_to_x_impl<TX, TY>(admin, pool_account_addr, info.y_added);
            };

            // Check the data matches the simulate data
            let pool_mut = borrow_global_mut<Pool<TX, TY>>(pool_account_addr);
            let (x_amt, y_amt, _) = get_amounts(pool_mut);
            assert!(x_amt == info.x_checked, i);
            assert!(y_amt == info.y_checked, i);
            
            i = i + 1;
        }
    }

    fun test_amm_simulate_1000_impl(admin: &signer) acquires AptoswapCap, LSPCapabilities, Pool {
        let s = AmmSimulationData {
            x_init: 100000,
            y_init: 2245300000,
            data: vector [
                AmmSimulationStepData { x_added: 821, y_added: 0, x_checked: 100820, y_checked: 2227104556 },
                AmmSimulationStepData { x_added: 0, y_added: 24524431, x_checked: 99726, y_checked: 2251616724 },
                AmmSimulationStepData { x_added: 828, y_added: 0, x_checked: 100553, y_checked: 2233164888 },
                AmmSimulationStepData { x_added: 0, y_added: 30435459, x_checked: 99206, y_checked: 2263585129 },
                AmmSimulationStepData { x_added: 2428, y_added: 0, x_checked: 101632, y_checked: 2209704564 },
                AmmSimulationStepData { x_added: 0, y_added: 29438633, x_checked: 100300, y_checked: 2239128477 },
                AmmSimulationStepData { x_added: 0, y_added: 35931840, x_checked: 98721, y_checked: 2275042351 },
                AmmSimulationStepData { x_added: 1725, y_added: 0, x_checked: 100445, y_checked: 2236105695 },
                AmmSimulationStepData { x_added: 775, y_added: 0, x_checked: 101219, y_checked: 2219050521 },
                AmmSimulationStepData { x_added: 1353, y_added: 0, x_checked: 102571, y_checked: 2189886364 },
                AmmSimulationStepData { x_added: 0, y_added: 36601551, x_checked: 100890, y_checked: 2226469614 },
                AmmSimulationStepData { x_added: 900, y_added: 0, x_checked: 101789, y_checked: 2206870487 },
                AmmSimulationStepData { x_added: 0, y_added: 19832866, x_checked: 100886, y_checked: 2226693436 },
                AmmSimulationStepData { x_added: 1875, y_added: 0, x_checked: 102760, y_checked: 2186192341 },
                AmmSimulationStepData { x_added: 0, y_added: 32068171, x_checked: 101279, y_checked: 2218244477 },
                AmmSimulationStepData { x_added: 0, y_added: 39172645, x_checked: 99527, y_checked: 2257397535 },
                AmmSimulationStepData { x_added: 1502, y_added: 0, x_checked: 101028, y_checked: 2223946830 },
                AmmSimulationStepData { x_added: 0, y_added: 34275084, x_checked: 99500, y_checked: 2258204776 },
                AmmSimulationStepData { x_added: 0, y_added: 24777356, x_checked: 98424, y_checked: 2282969743 },
                AmmSimulationStepData { x_added: 1015, y_added: 0, x_checked: 99438, y_checked: 2259757772 },
                AmmSimulationStepData { x_added: 2061, y_added: 0, x_checked: 101497, y_checked: 2214046501 },
                AmmSimulationStepData { x_added: 795, y_added: 0, x_checked: 102291, y_checked: 2196903653 },
                AmmSimulationStepData { x_added: 0, y_added: 27995773, x_checked: 101008, y_checked: 2224885428 },
                AmmSimulationStepData { x_added: 2683, y_added: 0, x_checked: 103689, y_checked: 2167504749 },
                AmmSimulationStepData { x_added: 1310, y_added: 0, x_checked: 104998, y_checked: 2140564222 },
                AmmSimulationStepData { x_added: 0, y_added: 83266955, x_checked: 101078, y_checked: 2223789543 },
                AmmSimulationStepData { x_added: 2193, y_added: 0, x_checked: 103269, y_checked: 2176735128 },
                AmmSimulationStepData { x_added: 0, y_added: 25807032, x_checked: 102063, y_checked: 2202529256 },
                AmmSimulationStepData { x_added: 827, y_added: 0, x_checked: 102889, y_checked: 2184910906 },
                AmmSimulationStepData { x_added: 0, y_added: 113260085, x_checked: 97833, y_checked: 2298114360 },
                AmmSimulationStepData { x_added: 857, y_added: 0, x_checked: 98689, y_checked: 2278250433 },
                AmmSimulationStepData { x_added: 863, y_added: 0, x_checked: 99551, y_checked: 2258591403 },
                AmmSimulationStepData { x_added: 1049, y_added: 0, x_checked: 100599, y_checked: 2235128960 },
                AmmSimulationStepData { x_added: 0, y_added: 26906160, x_checked: 99406, y_checked: 2262021666 },
                AmmSimulationStepData { x_added: 0, y_added: 64731416, x_checked: 96649, y_checked: 2326720716 },
                AmmSimulationStepData { x_added: 733, y_added: 0, x_checked: 97381, y_checked: 2309278495 },
                AmmSimulationStepData { x_added: 1233, y_added: 0, x_checked: 98613, y_checked: 2280520532 },
                AmmSimulationStepData { x_added: 0, y_added: 29841743, x_checked: 97344, y_checked: 2310347354 },
                AmmSimulationStepData { x_added: 0, y_added: 34135473, x_checked: 95931, y_checked: 2344465759 },
                AmmSimulationStepData { x_added: 0, y_added: 37293200, x_checked: 94434, y_checked: 2381740312 },
                AmmSimulationStepData { x_added: 0, y_added: 31386886, x_checked: 93210, y_checked: 2413111504 },
                AmmSimulationStepData { x_added: 812, y_added: 0, x_checked: 94021, y_checked: 2392372985 },
                AmmSimulationStepData { x_added: 0, y_added: 43728166, x_checked: 92339, y_checked: 2436079286 },
                AmmSimulationStepData { x_added: 1280, y_added: 0, x_checked: 93618, y_checked: 2402900477 },
                AmmSimulationStepData { x_added: 0, y_added: 24364544, x_checked: 92682, y_checked: 2427252838 },
                AmmSimulationStepData { x_added: 0, y_added: 48643763, x_checked: 90867, y_checked: 2475872279 },
                AmmSimulationStepData { x_added: 866, y_added: 0, x_checked: 91732, y_checked: 2452605898 },
                AmmSimulationStepData { x_added: 0, y_added: 27626133, x_checked: 90714, y_checked: 2480218217 },
                AmmSimulationStepData { x_added: 0, y_added: 25742250, x_checked: 89785, y_checked: 2505947595 },
                AmmSimulationStepData { x_added: 3455, y_added: 0, x_checked: 93238, y_checked: 2413374646 },
                AmmSimulationStepData { x_added: 896, y_added: 0, x_checked: 94133, y_checked: 2390504890 },
                AmmSimulationStepData { x_added: 0, y_added: 43225718, x_checked: 92467, y_checked: 2433708995 },
                AmmSimulationStepData { x_added: 0, y_added: 37200187, x_checked: 91079, y_checked: 2470890581 },
                AmmSimulationStepData { x_added: 891, y_added: 0, x_checked: 91969, y_checked: 2447059166 },
                AmmSimulationStepData { x_added: 1633, y_added: 0, x_checked: 93601, y_checked: 2404521395 },
                AmmSimulationStepData { x_added: 1935, y_added: 0, x_checked: 95535, y_checked: 2355967834 },
                AmmSimulationStepData { x_added: 798, y_added: 0, x_checked: 96332, y_checked: 2336524313 },
                AmmSimulationStepData { x_added: 0, y_added: 22553022, x_checked: 95414, y_checked: 2359066058 },
                AmmSimulationStepData { x_added: 941, y_added: 0, x_checked: 96354, y_checked: 2336124471 },
                AmmSimulationStepData { x_added: 0, y_added: 29213045, x_checked: 95168, y_checked: 2365322909 },
                AmmSimulationStepData { x_added: 0, y_added: 26236007, x_checked: 94128, y_checked: 2391545797 },
                AmmSimulationStepData { x_added: 2176, y_added: 0, x_checked: 96302, y_checked: 2337702738 },
                AmmSimulationStepData { x_added: 798, y_added: 0, x_checked: 97099, y_checked: 2318562356 },
                AmmSimulationStepData { x_added: 0, y_added: 23876161, x_checked: 96113, y_checked: 2342426578 },
                AmmSimulationStepData { x_added: 0, y_added: 18098013, x_checked: 95379, y_checked: 2360515541 },
                AmmSimulationStepData { x_added: 1479, y_added: 0, x_checked: 96857, y_checked: 2324590997 },
                AmmSimulationStepData { x_added: 2046, y_added: 0, x_checked: 98901, y_checked: 2276686488 },
                AmmSimulationStepData { x_added: 0, y_added: 49751163, x_checked: 96793, y_checked: 2326412775 },
                AmmSimulationStepData { x_added: 0, y_added: 18272596, x_checked: 96041, y_checked: 2344676234 },
                AmmSimulationStepData { x_added: 0, y_added: 29464505, x_checked: 94853, y_checked: 2374126006 },
                AmmSimulationStepData { x_added: 0, y_added: 18915450, x_checked: 94106, y_checked: 2393031998 },
                AmmSimulationStepData { x_added: 0, y_added: 41129872, x_checked: 92521, y_checked: 2434141305 },
                AmmSimulationStepData { x_added: 837, y_added: 0, x_checked: 93357, y_checked: 2412421404 },
                AmmSimulationStepData { x_added: 0, y_added: 65566145, x_checked: 90895, y_checked: 2477954765 },
                AmmSimulationStepData { x_added: 0, y_added: 27105710, x_checked: 89915, y_checked: 2505046922 },
                AmmSimulationStepData { x_added: 774, y_added: 0, x_checked: 90688, y_checked: 2483749355 },
                AmmSimulationStepData { x_added: 1115, y_added: 0, x_checked: 91802, y_checked: 2453689709 },
                AmmSimulationStepData { x_added: 0, y_added: 22083717, x_checked: 90986, y_checked: 2475762384 },
                AmmSimulationStepData { x_added: 927, y_added: 0, x_checked: 91912, y_checked: 2450899437 },
                AmmSimulationStepData { x_added: 794, y_added: 0, x_checked: 92705, y_checked: 2429986830 },
                AmmSimulationStepData { x_added: 2090, y_added: 0, x_checked: 94793, y_checked: 2376612079 },
                AmmSimulationStepData { x_added: 0, y_added: 35258959, x_checked: 93412, y_checked: 2411853408 },
                AmmSimulationStepData { x_added: 1202, y_added: 0, x_checked: 94613, y_checked: 2381338462 },
                AmmSimulationStepData { x_added: 0, y_added: 21661598, x_checked: 93763, y_checked: 2402989229 },
                AmmSimulationStepData { x_added: 2748, y_added: 0, x_checked: 96509, y_checked: 2334785591 },
                AmmSimulationStepData { x_added: 0, y_added: 32008140, x_checked: 95208, y_checked: 2366777726 },
                AmmSimulationStepData { x_added: 869, y_added: 0, x_checked: 96076, y_checked: 2345468277 },
                AmmSimulationStepData { x_added: 858, y_added: 0, x_checked: 96933, y_checked: 2324803572 },
                AmmSimulationStepData { x_added: 774, y_added: 0, x_checked: 97706, y_checked: 2306458125 },
                AmmSimulationStepData { x_added: 833, y_added: 0, x_checked: 98538, y_checked: 2287053307 },
                AmmSimulationStepData { x_added: 0, y_added: 30999715, x_checked: 97225, y_checked: 2318037522 },
                AmmSimulationStepData { x_added: 0, y_added: 46663968, x_checked: 95313, y_checked: 2364678158 },
                AmmSimulationStepData { x_added: 0, y_added: 36598167, x_checked: 93865, y_checked: 2401258025 },
                AmmSimulationStepData { x_added: 946, y_added: 0, x_checked: 94810, y_checked: 2377399185 },
                AmmSimulationStepData { x_added: 0, y_added: 21972178, x_checked: 93945, y_checked: 2399360376 },
                AmmSimulationStepData { x_added: 859, y_added: 0, x_checked: 94803, y_checked: 2377720576 },
                AmmSimulationStepData { x_added: 1162, y_added: 0, x_checked: 95964, y_checked: 2349027666 },
                AmmSimulationStepData { x_added: 0, y_added: 23377405, x_checked: 95022, y_checked: 2372393382 },
                AmmSimulationStepData { x_added: 1388, y_added: 0, x_checked: 96409, y_checked: 2338359670 },
                AmmSimulationStepData { x_added: 0, y_added: 41749273, x_checked: 94723, y_checked: 2380088068 },
                AmmSimulationStepData { x_added: 1043, y_added: 0, x_checked: 95765, y_checked: 2354264553 },
                AmmSimulationStepData { x_added: 0, y_added: 22317444, x_checked: 94869, y_checked: 2376570838 },
                AmmSimulationStepData { x_added: 0, y_added: 23878004, x_checked: 93929, y_checked: 2400436902 },
                AmmSimulationStepData { x_added: 745, y_added: 0, x_checked: 94673, y_checked: 2381623072 },
                AmmSimulationStepData { x_added: 0, y_added: 19418814, x_checked: 93910, y_checked: 2401032176 },
                AmmSimulationStepData { x_added: 1271, y_added: 0, x_checked: 95180, y_checked: 2369094432 },
                AmmSimulationStepData { x_added: 2552, y_added: 0, x_checked: 97730, y_checked: 2307444594 },
                AmmSimulationStepData { x_added: 0, y_added: 44991478, x_checked: 95867, y_checked: 2352413576 },
                AmmSimulationStepData { x_added: 1100, y_added: 0, x_checked: 96966, y_checked: 2325823586 },
                AmmSimulationStepData { x_added: 0, y_added: 30963491, x_checked: 95696, y_checked: 2356771595 },
                AmmSimulationStepData { x_added: 0, y_added: 27659318, x_checked: 94590, y_checked: 2384417083 },
                AmmSimulationStepData { x_added: 0, y_added: 36626950, x_checked: 93164, y_checked: 2421025719 },
                AmmSimulationStepData { x_added: 0, y_added: 37815654, x_checked: 91736, y_checked: 2458822465 },
                AmmSimulationStepData { x_added: 0, y_added: 29828068, x_checked: 90640, y_checked: 2488635618 },
                AmmSimulationStepData { x_added: 0, y_added: 24063487, x_checked: 89775, y_checked: 2512687073 },
                AmmSimulationStepData { x_added: 2842, y_added: 0, x_checked: 92615, y_checked: 2435846988 },
                AmmSimulationStepData { x_added: 1399, y_added: 0, x_checked: 94013, y_checked: 2399727354 },
                AmmSimulationStepData { x_added: 0, y_added: 45975959, x_checked: 92251, y_checked: 2445680325 },
                AmmSimulationStepData { x_added: 925, y_added: 0, x_checked: 93175, y_checked: 2421504913 },
                AmmSimulationStepData { x_added: 1382, y_added: 0, x_checked: 94556, y_checked: 2386239533 },
                AmmSimulationStepData { x_added: 1473, y_added: 0, x_checked: 96028, y_checked: 2349759074 },
                AmmSimulationStepData { x_added: 1786, y_added: 0, x_checked: 97813, y_checked: 2306995996 },
                AmmSimulationStepData { x_added: 0, y_added: 45344462, x_checked: 95934, y_checked: 2352317785 },
                AmmSimulationStepData { x_added: 0, y_added: 19859459, x_checked: 95134, y_checked: 2372167314 },
                AmmSimulationStepData { x_added: 0, y_added: 30332270, x_checked: 93937, y_checked: 2402484417 },
                AmmSimulationStepData { x_added: 0, y_added: 52203763, x_checked: 91946, y_checked: 2454662078 },
                AmmSimulationStepData { x_added: 0, y_added: 34036768, x_checked: 90693, y_checked: 2488681827 },
                AmmSimulationStepData { x_added: 6793, y_added: 0, x_checked: 97482, y_checked: 2315764849 },
                AmmSimulationStepData { x_added: 2073, y_added: 0, x_checked: 99553, y_checked: 2267726693 },
                AmmSimulationStepData { x_added: 0, y_added: 20681112, x_checked: 98656, y_checked: 2288397464 },
                AmmSimulationStepData { x_added: 0, y_added: 41820831, x_checked: 96891, y_checked: 2330197384 },
                AmmSimulationStepData { x_added: 0, y_added: 22530650, x_checked: 95966, y_checked: 2352716768 },
                AmmSimulationStepData { x_added: 1278, y_added: 0, x_checked: 97243, y_checked: 2321916283 },
                AmmSimulationStepData { x_added: 900, y_added: 0, x_checked: 98142, y_checked: 2300717402 },
                AmmSimulationStepData { x_added: 0, y_added: 36563738, x_checked: 96612, y_checked: 2337262858 },
                AmmSimulationStepData { x_added: 1307, y_added: 0, x_checked: 97918, y_checked: 2306183378 },
                AmmSimulationStepData { x_added: 1743, y_added: 0, x_checked: 99660, y_checked: 2265986293 },
                AmmSimulationStepData { x_added: 0, y_added: 45935871, x_checked: 97686, y_checked: 2311899196 },
                AmmSimulationStepData { x_added: 3469, y_added: 0, x_checked: 101153, y_checked: 2232857954 },
                AmmSimulationStepData { x_added: 2235, y_added: 0, x_checked: 103386, y_checked: 2184757987 },
                AmmSimulationStepData { x_added: 0, y_added: 20740408, x_checked: 102417, y_checked: 2205488024 },
                AmmSimulationStepData { x_added: 0, y_added: 25588088, x_checked: 101246, y_checked: 2231063317 },
                AmmSimulationStepData { x_added: 0, y_added: 25515630, x_checked: 100105, y_checked: 2256566189 },
                AmmSimulationStepData { x_added: 3357, y_added: 0, x_checked: 103460, y_checked: 2183580230 },
                AmmSimulationStepData { x_added: 1851, y_added: 0, x_checked: 105310, y_checked: 2145322735 },
                AmmSimulationStepData { x_added: 0, y_added: 16530985, x_checked: 104508, y_checked: 2161845454 },
                AmmSimulationStepData { x_added: 0, y_added: 20457467, x_checked: 103532, y_checked: 2182292692 },
                AmmSimulationStepData { x_added: 3779, y_added: 0, x_checked: 107309, y_checked: 2105677845 },
                AmmSimulationStepData { x_added: 0, y_added: 41947032, x_checked: 105220, y_checked: 2147603903 },
                AmmSimulationStepData { x_added: 1434, y_added: 0, x_checked: 106653, y_checked: 2118827956 },
                AmmSimulationStepData { x_added: 0, y_added: 51686747, x_checked: 104121, y_checked: 2170488859 },
                AmmSimulationStepData { x_added: 0, y_added: 55604163, x_checked: 101528, y_checked: 2226065219 },
                AmmSimulationStepData { x_added: 0, y_added: 23136299, x_checked: 100487, y_checked: 2249189949 },
                AmmSimulationStepData { x_added: 993, y_added: 0, x_checked: 101479, y_checked: 2227269014 },
                AmmSimulationStepData { x_added: 0, y_added: 35973967, x_checked: 99871, y_checked: 2263224994 },
                AmmSimulationStepData { x_added: 816, y_added: 0, x_checked: 100686, y_checked: 2244972274 },
                AmmSimulationStepData { x_added: 776, y_added: 0, x_checked: 101461, y_checked: 2227868187 },
                AmmSimulationStepData { x_added: 0, y_added: 43753273, x_checked: 99513, y_checked: 2271599583 },
                AmmSimulationStepData { x_added: 0, y_added: 103965611, x_checked: 95171, y_checked: 2375513211 },
                AmmSimulationStepData { x_added: 0, y_added: 43070873, x_checked: 93482, y_checked: 2418562548 },
                AmmSimulationStepData { x_added: 0, y_added: 27175583, x_checked: 92447, y_checked: 2445724543 },
                AmmSimulationStepData { x_added: 811, y_added: 0, x_checked: 93257, y_checked: 2424559771 },
                AmmSimulationStepData { x_added: 0, y_added: 25566758, x_checked: 92287, y_checked: 2450113745 },
                AmmSimulationStepData { x_added: 0, y_added: 56840679, x_checked: 90201, y_checked: 2506926003 },
                AmmSimulationStepData { x_added: 0, y_added: 143575981, x_checked: 85329, y_checked: 2650430196 },
                AmmSimulationStepData { x_added: 1128, y_added: 0, x_checked: 86456, y_checked: 2615971201 },
                AmmSimulationStepData { x_added: 0, y_added: 33313451, x_checked: 85373, y_checked: 2649267995 },
                AmmSimulationStepData { x_added: 0, y_added: 30484058, x_checked: 84405, y_checked: 2679736810 },
                AmmSimulationStepData { x_added: 759, y_added: 0, x_checked: 85163, y_checked: 2655947975 },
                AmmSimulationStepData { x_added: 732, y_added: 0, x_checked: 85894, y_checked: 2633405875 },
                AmmSimulationStepData { x_added: 0, y_added: 22127962, x_checked: 85181, y_checked: 2655522773 },
                AmmSimulationStepData { x_added: 2470, y_added: 0, x_checked: 87649, y_checked: 2580955311 },
                AmmSimulationStepData { x_added: 0, y_added: 28515931, x_checked: 86695, y_checked: 2609456984 },
                AmmSimulationStepData { x_added: 0, y_added: 42386996, x_checked: 85314, y_checked: 2651822786 },
                AmmSimulationStepData { x_added: 0, y_added: 86624318, x_checked: 82624, y_checked: 2738403791 },
                AmmSimulationStepData { x_added: 0, y_added: 22553977, x_checked: 81952, y_checked: 2760946491 },
                AmmSimulationStepData { x_added: 0, y_added: 29932046, x_checked: 81076, y_checked: 2790863570 },
                AmmSimulationStepData { x_added: 0, y_added: 44036946, x_checked: 79821, y_checked: 2834878497 },
                AmmSimulationStepData { x_added: 990, y_added: 0, x_checked: 80810, y_checked: 2800287556 },
                AmmSimulationStepData { x_added: 0, y_added: 51106921, x_checked: 79366, y_checked: 2851368923 },
                AmmSimulationStepData { x_added: 4397, y_added: 0, x_checked: 83760, y_checked: 2702142664 },
                AmmSimulationStepData { x_added: 1101, y_added: 0, x_checked: 84860, y_checked: 2667210361 },
                AmmSimulationStepData { x_added: 0, y_added: 44936882, x_checked: 83459, y_checked: 2712124774 },
                AmmSimulationStepData { x_added: 0, y_added: 22787312, x_checked: 82766, y_checked: 2734900692 },
                AmmSimulationStepData { x_added: 819, y_added: 0, x_checked: 83584, y_checked: 2708232621 },
                AmmSimulationStepData { x_added: 847, y_added: 0, x_checked: 84430, y_checked: 2681191034 },
                AmmSimulationStepData { x_added: 1097, y_added: 0, x_checked: 85526, y_checked: 2646924910 },
                AmmSimulationStepData { x_added: 0, y_added: 28074365, x_checked: 84632, y_checked: 2674985237 },
                AmmSimulationStepData { x_added: 0, y_added: 93686981, x_checked: 81777, y_checked: 2768625374 },
                AmmSimulationStepData { x_added: 0, y_added: 34167031, x_checked: 80784, y_checked: 2802775321 },
                AmmSimulationStepData { x_added: 1128, y_added: 0, x_checked: 81911, y_checked: 2764313639 },
                AmmSimulationStepData { x_added: 628, y_added: 0, x_checked: 82538, y_checked: 2743381004 },
                AmmSimulationStepData { x_added: 3167, y_added: 0, x_checked: 85703, y_checked: 2642314970 },
                AmmSimulationStepData { x_added: 0, y_added: 39364046, x_checked: 84449, y_checked: 2681659333 },
                AmmSimulationStepData { x_added: 0, y_added: 27833380, x_checked: 83585, y_checked: 2709478796 },
                AmmSimulationStepData { x_added: 0, y_added: 132649459, x_checked: 79696, y_checked: 2842061930 },
                AmmSimulationStepData { x_added: 1085, y_added: 0, x_checked: 80780, y_checked: 2804027973 },
                AmmSimulationStepData { x_added: 0, y_added: 44891940, x_checked: 79511, y_checked: 2848897467 },
                AmmSimulationStepData { x_added: 0, y_added: 23883653, x_checked: 78852, y_checked: 2872769178 },
                AmmSimulationStepData { x_added: 0, y_added: 35394999, x_checked: 77896, y_checked: 2908146479 },
                AmmSimulationStepData { x_added: 0, y_added: 23461348, x_checked: 77275, y_checked: 2931596096 },
                AmmSimulationStepData { x_added: 0, y_added: 28091238, x_checked: 76544, y_checked: 2959673288 },
                AmmSimulationStepData { x_added: 703, y_added: 0, x_checked: 77246, y_checked: 2932852159 },
                AmmSimulationStepData { x_added: 761, y_added: 0, x_checked: 78006, y_checked: 2904352314 },
                AmmSimulationStepData { x_added: 0, y_added: 52869801, x_checked: 76616, y_checked: 2957195680 },
                AmmSimulationStepData { x_added: 1730, y_added: 0, x_checked: 78345, y_checked: 2892117746 },
                AmmSimulationStepData { x_added: 0, y_added: 54658072, x_checked: 76897, y_checked: 2946748488 },
                AmmSimulationStepData { x_added: 0, y_added: 63702362, x_checked: 75275, y_checked: 3010418998 },
                AmmSimulationStepData { x_added: 1160, y_added: 0, x_checked: 76434, y_checked: 2964887155 },
                AmmSimulationStepData { x_added: 608, y_added: 0, x_checked: 77041, y_checked: 2941603407 },
                AmmSimulationStepData { x_added: 2401, y_added: 0, x_checked: 79440, y_checked: 2853021642 },
                AmmSimulationStepData { x_added: 1130, y_added: 0, x_checked: 80569, y_checked: 2813147473 },
                AmmSimulationStepData { x_added: 955, y_added: 0, x_checked: 81523, y_checked: 2780329720 },
                AmmSimulationStepData { x_added: 0, y_added: 26499814, x_checked: 80756, y_checked: 2806816284 },
                AmmSimulationStepData { x_added: 0, y_added: 24988418, x_checked: 80046, y_checked: 2831792207 },
                AmmSimulationStepData { x_added: 0, y_added: 33324870, x_checked: 79118, y_checked: 2865100414 },
                AmmSimulationStepData { x_added: 629, y_added: 0, x_checked: 79746, y_checked: 2842609031 },
                AmmSimulationStepData { x_added: 0, y_added: 22730686, x_checked: 79116, y_checked: 2865328351 },
                AmmSimulationStepData { x_added: 1204, y_added: 0, x_checked: 80319, y_checked: 2822552672 },
                AmmSimulationStepData { x_added: 781, y_added: 0, x_checked: 81099, y_checked: 2795474655 },
                AmmSimulationStepData { x_added: 0, y_added: 25707506, x_checked: 80363, y_checked: 2821169307 },
                AmmSimulationStepData { x_added: 868, y_added: 0, x_checked: 81230, y_checked: 2791160932 },
                AmmSimulationStepData { x_added: 1038, y_added: 0, x_checked: 82267, y_checked: 2756078024 },
                AmmSimulationStepData { x_added: 0, y_added: 27310597, x_checked: 81463, y_checked: 2783374965 },
                AmmSimulationStepData { x_added: 0, y_added: 21174891, x_checked: 80850, y_checked: 2804539268 },
                AmmSimulationStepData { x_added: 0, y_added: 37468122, x_checked: 79788, y_checked: 2841988655 },
                AmmSimulationStepData { x_added: 1641, y_added: 0, x_checked: 81428, y_checked: 2784920610 },
                AmmSimulationStepData { x_added: 0, y_added: 51404293, x_checked: 79957, y_checked: 2836299200 },
                AmmSimulationStepData { x_added: 786, y_added: 0, x_checked: 80742, y_checked: 2808793351 },
                AmmSimulationStepData { x_added: 1752, y_added: 0, x_checked: 82493, y_checked: 2749340423 },
                AmmSimulationStepData { x_added: 0, y_added: 47207093, x_checked: 81105, y_checked: 2796523912 },
                AmmSimulationStepData { x_added: 1153, y_added: 0, x_checked: 82257, y_checked: 2757459478 },
                AmmSimulationStepData { x_added: 2999, y_added: 0, x_checked: 85254, y_checked: 2660774046 },
                AmmSimulationStepData { x_added: 0, y_added: 20439162, x_checked: 84607, y_checked: 2681202988 },
                AmmSimulationStepData { x_added: 0, y_added: 27825093, x_checked: 83741, y_checked: 2709014168 },
                AmmSimulationStepData { x_added: 0, y_added: 27148870, x_checked: 82913, y_checked: 2736149463 },
                AmmSimulationStepData { x_added: 1845, y_added: 0, x_checked: 84757, y_checked: 2676778843 },
                AmmSimulationStepData { x_added: 0, y_added: 22292788, x_checked: 84060, y_checked: 2699060484 },
                AmmSimulationStepData { x_added: 1657, y_added: 0, x_checked: 85716, y_checked: 2647070088 },
                AmmSimulationStepData { x_added: 0, y_added: 44825200, x_checked: 84293, y_checked: 2691872875 },
                AmmSimulationStepData { x_added: 0, y_added: 34757909, x_checked: 83222, y_checked: 2726613405 },
                AmmSimulationStepData { x_added: 1129, y_added: 0, x_checked: 84350, y_checked: 2690246492 },
                AmmSimulationStepData { x_added: 0, y_added: 22628844, x_checked: 83649, y_checked: 2712864021 },
                AmmSimulationStepData { x_added: 0, y_added: 22625197, x_checked: 82960, y_checked: 2735477905 },
                AmmSimulationStepData { x_added: 944, y_added: 0, x_checked: 83903, y_checked: 2704830120 },
                AmmSimulationStepData { x_added: 0, y_added: 32599213, x_checked: 82907, y_checked: 2737413033 },
                AmmSimulationStepData { x_added: 0, y_added: 31203267, x_checked: 81976, y_checked: 2768600698 },
                AmmSimulationStepData { x_added: 1476, y_added: 0, x_checked: 83451, y_checked: 2719795929 },
                AmmSimulationStepData { x_added: 776, y_added: 0, x_checked: 84226, y_checked: 2694833897 },
                AmmSimulationStepData { x_added: 0, y_added: 43222350, x_checked: 82901, y_checked: 2738034635 },
                AmmSimulationStepData { x_added: 1316, y_added: 0, x_checked: 84216, y_checked: 2695409316 },
                AmmSimulationStepData { x_added: 1308, y_added: 0, x_checked: 85523, y_checked: 2654341035 },
                AmmSimulationStepData { x_added: 683, y_added: 0, x_checked: 86205, y_checked: 2633402647 },
                AmmSimulationStepData { x_added: 1655, y_added: 0, x_checked: 87859, y_checked: 2583974267 },
                AmmSimulationStepData { x_added: 0, y_added: 45946673, x_checked: 86329, y_checked: 2629897966 },
                AmmSimulationStepData { x_added: 1038, y_added: 0, x_checked: 87366, y_checked: 2598771351 },
                AmmSimulationStepData { x_added: 1396, y_added: 0, x_checked: 88761, y_checked: 2558043398 },
                AmmSimulationStepData { x_added: 740, y_added: 0, x_checked: 89500, y_checked: 2536978369 },
                AmmSimulationStepData { x_added: 0, y_added: 34775905, x_checked: 88294, y_checked: 2571736886 },
                AmmSimulationStepData { x_added: 1556, y_added: 0, x_checked: 89849, y_checked: 2527340828 },
                AmmSimulationStepData { x_added: 1369, y_added: 0, x_checked: 91217, y_checked: 2489546952 },
                AmmSimulationStepData { x_added: 0, y_added: 54180484, x_checked: 89280, y_checked: 2543700345 },
                AmmSimulationStepData { x_added: 1166, y_added: 0, x_checked: 90445, y_checked: 2511018850 },
                AmmSimulationStepData { x_added: 1081, y_added: 0, x_checked: 91525, y_checked: 2481470028 },
                AmmSimulationStepData { x_added: 0, y_added: 91378317, x_checked: 88284, y_checked: 2572802655 },
                AmmSimulationStepData { x_added: 1250, y_added: 0, x_checked: 89533, y_checked: 2537024982 },
                AmmSimulationStepData { x_added: 1357, y_added: 0, x_checked: 90889, y_checked: 2499284346 },
                AmmSimulationStepData { x_added: 0, y_added: 28902561, x_checked: 89854, y_checked: 2528172455 },
                AmmSimulationStepData { x_added: 0, y_added: 183951635, x_checked: 83777, y_checked: 2712032114 },
                AmmSimulationStepData { x_added: 0, y_added: 26784111, x_checked: 82961, y_checked: 2738802832 },
                AmmSimulationStepData { x_added: 869, y_added: 0, x_checked: 83829, y_checked: 2710541142 },
                AmmSimulationStepData { x_added: 735, y_added: 0, x_checked: 84563, y_checked: 2687077417 },
                AmmSimulationStepData { x_added: 1260, y_added: 0, x_checked: 85822, y_checked: 2647781674 },
                AmmSimulationStepData { x_added: 996, y_added: 0, x_checked: 86817, y_checked: 2617526192 },
                AmmSimulationStepData { x_added: 0, y_added: 31852253, x_checked: 85777, y_checked: 2649362518 },
                AmmSimulationStepData { x_added: 1095, y_added: 0, x_checked: 86871, y_checked: 2616088419 },
                AmmSimulationStepData { x_added: 697, y_added: 0, x_checked: 87567, y_checked: 2595354503 },
                AmmSimulationStepData { x_added: 1042, y_added: 0, x_checked: 88608, y_checked: 2564950147 },
                AmmSimulationStepData { x_added: 0, y_added: 25156980, x_checked: 87750, y_checked: 2590094548 },
                AmmSimulationStepData { x_added: 735, y_added: 0, x_checked: 88484, y_checked: 2568667035 },
                AmmSimulationStepData { x_added: 666, y_added: 0, x_checked: 89149, y_checked: 2549563462 },
                AmmSimulationStepData { x_added: 0, y_added: 37310871, x_checked: 87867, y_checked: 2586855677 },
                AmmSimulationStepData { x_added: 0, y_added: 21925529, x_checked: 87131, y_checked: 2608770243 },
                AmmSimulationStepData { x_added: 0, y_added: 30576839, x_checked: 86125, y_checked: 2639331793 },
                AmmSimulationStepData { x_added: 828, y_added: 0, x_checked: 86952, y_checked: 2614319322 },
                AmmSimulationStepData { x_added: 1219, y_added: 0, x_checked: 88170, y_checked: 2578321504 },
                AmmSimulationStepData { x_added: 0, y_added: 46865485, x_checked: 86601, y_checked: 2625163556 },
                AmmSimulationStepData { x_added: 1964, y_added: 0, x_checked: 88564, y_checked: 2567122361 },
                AmmSimulationStepData { x_added: 822, y_added: 0, x_checked: 89385, y_checked: 2543628749 },
                AmmSimulationStepData { x_added: 0, y_added: 33865660, x_checked: 88215, y_checked: 2577477476 },
                AmmSimulationStepData { x_added: 0, y_added: 25202537, x_checked: 87364, y_checked: 2602667411 },
                AmmSimulationStepData { x_added: 1279, y_added: 0, x_checked: 88642, y_checked: 2565259096 },
                AmmSimulationStepData { x_added: 0, y_added: 31023723, x_checked: 87586, y_checked: 2596267307 },
                AmmSimulationStepData { x_added: 0, y_added: 46729435, x_checked: 86043, y_checked: 2642973377 },
                AmmSimulationStepData { x_added: 0, y_added: 37693746, x_checked: 84837, y_checked: 2680648276 },
                AmmSimulationStepData { x_added: 0, y_added: 36043571, x_checked: 83715, y_checked: 2716673825 },
                AmmSimulationStepData { x_added: 0, y_added: 55861624, x_checked: 82034, y_checked: 2772507518 },
                AmmSimulationStepData { x_added: 1556, y_added: 0, x_checked: 83589, y_checked: 2721060977 },
                AmmSimulationStepData { x_added: 774, y_added: 0, x_checked: 84362, y_checked: 2696192106 },
                AmmSimulationStepData { x_added: 743, y_added: 0, x_checked: 85104, y_checked: 2672747509 },
                AmmSimulationStepData { x_added: 845, y_added: 0, x_checked: 85948, y_checked: 2646593799 },
                AmmSimulationStepData { x_added: 1215, y_added: 0, x_checked: 87162, y_checked: 2609851579 },
                AmmSimulationStepData { x_added: 896, y_added: 0, x_checked: 88057, y_checked: 2583413398 },
                AmmSimulationStepData { x_added: 1208, y_added: 0, x_checked: 89264, y_checked: 2548595492 },
                AmmSimulationStepData { x_added: 2381, y_added: 0, x_checked: 91643, y_checked: 2482597947 },
                AmmSimulationStepData { x_added: 1707, y_added: 0, x_checked: 93349, y_checked: 2437357770 },
                AmmSimulationStepData { x_added: 1311, y_added: 0, x_checked: 94659, y_checked: 2403728388 },
                AmmSimulationStepData { x_added: 0, y_added: 38973159, x_checked: 93154, y_checked: 2442682060 },
                AmmSimulationStepData { x_added: 1439, y_added: 0, x_checked: 94592, y_checked: 2405649815 },
                AmmSimulationStepData { x_added: 0, y_added: 79096005, x_checked: 91590, y_checked: 2484706271 },
                AmmSimulationStepData { x_added: 1355, y_added: 0, x_checked: 92944, y_checked: 2448614670 },
                AmmSimulationStepData { x_added: 1347, y_added: 0, x_checked: 94290, y_checked: 2413762827 },
                AmmSimulationStepData { x_added: 2578, y_added: 0, x_checked: 96866, y_checked: 2349742378 },
                AmmSimulationStepData { x_added: 0, y_added: 25614821, x_checked: 95825, y_checked: 2375344391 },
                AmmSimulationStepData { x_added: 977, y_added: 0, x_checked: 96801, y_checked: 2351467761 },
                AmmSimulationStepData { x_added: 0, y_added: 25308410, x_checked: 95774, y_checked: 2376763516 },
                AmmSimulationStepData { x_added: 2044, y_added: 0, x_checked: 97816, y_checked: 2327289122 },
                AmmSimulationStepData { x_added: 0, y_added: 86802213, x_checked: 94310, y_checked: 2414047933 },
                AmmSimulationStepData { x_added: 0, y_added: 18093624, x_checked: 93611, y_checked: 2432132510 },
                AmmSimulationStepData { x_added: 0, y_added: 37417659, x_checked: 92197, y_checked: 2469531460 },
                AmmSimulationStepData { x_added: 733, y_added: 0, x_checked: 92929, y_checked: 2450131739 },
                AmmSimulationStepData { x_added: 0, y_added: 21372952, x_checked: 92128, y_checked: 2471494004 },
                AmmSimulationStepData { x_added: 959, y_added: 0, x_checked: 93086, y_checked: 2446137315 },
                AmmSimulationStepData { x_added: 0, y_added: 32466611, x_checked: 91871, y_checked: 2478587692 },
                AmmSimulationStepData { x_added: 0, y_added: 45780604, x_checked: 90210, y_checked: 2524345405 },
                AmmSimulationStepData { x_added: 0, y_added: 39556218, x_checked: 88823, y_checked: 2563881844 },
                AmmSimulationStepData { x_added: 928, y_added: 0, x_checked: 89750, y_checked: 2537485120 },
                AmmSimulationStepData { x_added: 720, y_added: 0, x_checked: 90469, y_checked: 2517374176 },
                AmmSimulationStepData { x_added: 0, y_added: 22279614, x_checked: 89678, y_checked: 2539642650 },
                AmmSimulationStepData { x_added: 1422, y_added: 0, x_checked: 91099, y_checked: 2500138027 },
                AmmSimulationStepData { x_added: 0, y_added: 22111570, x_checked: 90303, y_checked: 2522238541 },
                AmmSimulationStepData { x_added: 0, y_added: 56037383, x_checked: 88347, y_checked: 2578247905 },
                AmmSimulationStepData { x_added: 767, y_added: 0, x_checked: 89113, y_checked: 2556143099 },
                AmmSimulationStepData { x_added: 0, y_added: 40403107, x_checked: 87731, y_checked: 2596526004 },
                AmmSimulationStepData { x_added: 0, y_added: 27863863, x_checked: 86803, y_checked: 2624375935 },
                AmmSimulationStepData { x_added: 0, y_added: 29505064, x_checked: 85841, y_checked: 2653866246 },
                AmmSimulationStepData { x_added: 0, y_added: 25910556, x_checked: 85014, y_checked: 2679763846 },
                AmmSimulationStepData { x_added: 0, y_added: 20767998, x_checked: 84363, y_checked: 2700521460 },
                AmmSimulationStepData { x_added: 649, y_added: 0, x_checked: 85011, y_checked: 2679999670 },
                AmmSimulationStepData { x_added: 1131, y_added: 0, x_checked: 86141, y_checked: 2644935476 },
                AmmSimulationStepData { x_added: 649, y_added: 0, x_checked: 86789, y_checked: 2625247870 },
                AmmSimulationStepData { x_added: 1058, y_added: 0, x_checked: 87846, y_checked: 2593748363 },
                AmmSimulationStepData { x_added: 888, y_added: 0, x_checked: 88733, y_checked: 2567907345 },
                AmmSimulationStepData { x_added: 980, y_added: 0, x_checked: 89712, y_checked: 2539969485 },
                AmmSimulationStepData { x_added: 1121, y_added: 0, x_checked: 90832, y_checked: 2508733361 },
                AmmSimulationStepData { x_added: 1743, y_added: 0, x_checked: 92574, y_checked: 2461658532 },
                AmmSimulationStepData { x_added: 0, y_added: 20779444, x_checked: 91802, y_checked: 2482427586 },
                AmmSimulationStepData { x_added: 0, y_added: 19516819, x_checked: 91089, y_checked: 2501934646 },
                AmmSimulationStepData { x_added: 1614, y_added: 0, x_checked: 92702, y_checked: 2458533987 },
                AmmSimulationStepData { x_added: 755, y_added: 0, x_checked: 93456, y_checked: 2438750805 },
                AmmSimulationStepData { x_added: 0, y_added: 37463677, x_checked: 92047, y_checked: 2476195750 },
                AmmSimulationStepData { x_added: 0, y_added: 23875217, x_checked: 91171, y_checked: 2500059029 },
                AmmSimulationStepData { x_added: 11924, y_added: 0, x_checked: 103089, y_checked: 2211673719 },
                AmmSimulationStepData { x_added: 2765, y_added: 0, x_checked: 105852, y_checked: 2154085994 },
                AmmSimulationStepData { x_added: 0, y_added: 25603420, x_checked: 104613, y_checked: 2179676612 },
                AmmSimulationStepData { x_added: 0, y_added: 23824295, x_checked: 103486, y_checked: 2203488994 },
                AmmSimulationStepData { x_added: 1645, y_added: 0, x_checked: 105130, y_checked: 2169134479 },
                AmmSimulationStepData { x_added: 0, y_added: 21305161, x_checked: 104111, y_checked: 2190428987 },
                AmmSimulationStepData { x_added: 0, y_added: 20189312, x_checked: 103163, y_checked: 2210608204 },
                AmmSimulationStepData { x_added: 849, y_added: 0, x_checked: 104011, y_checked: 2192648394 },
                AmmSimulationStepData { x_added: 1662, y_added: 0, x_checked: 105672, y_checked: 2158285483 },
                AmmSimulationStepData { x_added: 0, y_added: 22202621, x_checked: 104600, y_checked: 2180477002 },
                AmmSimulationStepData { x_added: 0, y_added: 23499539, x_checked: 103489, y_checked: 2203964791 },
                AmmSimulationStepData { x_added: 0, y_added: 18031439, x_checked: 102652, y_checked: 2221987214 },
                AmmSimulationStepData { x_added: 1444, y_added: 0, x_checked: 104095, y_checked: 2191269481 },
                AmmSimulationStepData { x_added: 0, y_added: 75535685, x_checked: 100637, y_checked: 2266767398 },
                AmmSimulationStepData { x_added: 824, y_added: 0, x_checked: 101460, y_checked: 2248446836 },
                AmmSimulationStepData { x_added: 1420, y_added: 0, x_checked: 102879, y_checked: 2217520447 },
                AmmSimulationStepData { x_added: 0, y_added: 32597721, x_checked: 101393, y_checked: 2250101869 },
                AmmSimulationStepData { x_added: 0, y_added: 20811281, x_checked: 100467, y_checked: 2270902744 },
                AmmSimulationStepData { x_added: 0, y_added: 19439749, x_checked: 99617, y_checked: 2290332773 },
                AmmSimulationStepData { x_added: 2030, y_added: 0, x_checked: 101645, y_checked: 2244769035 },
                AmmSimulationStepData { x_added: 0, y_added: 48552088, x_checked: 99500, y_checked: 2293296846 },
                AmmSimulationStepData { x_added: 0, y_added: 18422650, x_checked: 98710, y_checked: 2311710284 },
                AmmSimulationStepData { x_added: 1109, y_added: 0, x_checked: 99818, y_checked: 2286118541 },
                AmmSimulationStepData { x_added: 767, y_added: 0, x_checked: 100584, y_checked: 2268753659 },
                AmmSimulationStepData { x_added: 0, y_added: 65107912, x_checked: 97787, y_checked: 2333829017 },
                AmmSimulationStepData { x_added: 837, y_added: 0, x_checked: 98623, y_checked: 2314116185 },
                AmmSimulationStepData { x_added: 0, y_added: 78385280, x_checked: 95402, y_checked: 2392462272 },
                AmmSimulationStepData { x_added: 1070, y_added: 0, x_checked: 96471, y_checked: 2366024855 },
                AmmSimulationStepData { x_added: 0, y_added: 25484734, x_checked: 95447, y_checked: 2391496846 },
                AmmSimulationStepData { x_added: 960, y_added: 0, x_checked: 96406, y_checked: 2367781081 },
                AmmSimulationStepData { x_added: 0, y_added: 20661413, x_checked: 95575, y_checked: 2388432163 },
                AmmSimulationStepData { x_added: 1040, y_added: 0, x_checked: 96614, y_checked: 2362820010 },
                AmmSimulationStepData { x_added: 2033, y_added: 0, x_checked: 98645, y_checked: 2314312721 },
                AmmSimulationStepData { x_added: 0, y_added: 33338365, x_checked: 97249, y_checked: 2347634416 },
                AmmSimulationStepData { x_added: 0, y_added: 24222853, x_checked: 96259, y_checked: 2371845157 },
                AmmSimulationStepData { x_added: 3649, y_added: 0, x_checked: 99906, y_checked: 2285491341 },
                AmmSimulationStepData { x_added: 0, y_added: 23667043, x_checked: 98886, y_checked: 2309146550 },
                AmmSimulationStepData { x_added: 867, y_added: 0, x_checked: 99752, y_checked: 2289168471 },
                AmmSimulationStepData { x_added: 0, y_added: 27821425, x_checked: 98558, y_checked: 2316975985 },
                AmmSimulationStepData { x_added: 1150, y_added: 0, x_checked: 99707, y_checked: 2290344612 },
                AmmSimulationStepData { x_added: 0, y_added: 49326232, x_checked: 97612, y_checked: 2339646180 },
                AmmSimulationStepData { x_added: 0, y_added: 18231287, x_checked: 96860, y_checked: 2357868351 },
                AmmSimulationStepData { x_added: 1542, y_added: 0, x_checked: 98401, y_checked: 2321037517 },
                AmmSimulationStepData { x_added: 0, y_added: 17671390, x_checked: 97660, y_checked: 2338700071 },
                AmmSimulationStepData { x_added: 770, y_added: 0, x_checked: 98429, y_checked: 2320475571 },
                AmmSimulationStepData { x_added: 1735, y_added: 0, x_checked: 100163, y_checked: 2280417840 },
                AmmSimulationStepData { x_added: 1307, y_added: 0, x_checked: 101469, y_checked: 2251155494 },
                AmmSimulationStepData { x_added: 0, y_added: 21943820, x_checked: 100493, y_checked: 2273088342 },
                AmmSimulationStepData { x_added: 0, y_added: 19999314, x_checked: 99620, y_checked: 2293077656 },
                AmmSimulationStepData { x_added: 2078, y_added: 0, x_checked: 101696, y_checked: 2246399805 },
                AmmSimulationStepData { x_added: 0, y_added: 23154982, x_checked: 100662, y_checked: 2269543209 },
                AmmSimulationStepData { x_added: 0, y_added: 35052373, x_checked: 99136, y_checked: 2304578055 },
                AmmSimulationStepData { x_added: 0, y_added: 21401491, x_checked: 98227, y_checked: 2325968845 },
                AmmSimulationStepData { x_added: 1009, y_added: 0, x_checked: 99235, y_checked: 2302411942 },
                AmmSimulationStepData { x_added: 2707, y_added: 0, x_checked: 101940, y_checked: 2241470859 },
                AmmSimulationStepData { x_added: 1465, y_added: 0, x_checked: 103404, y_checked: 2209821464 },
                AmmSimulationStepData { x_added: 0, y_added: 19042464, x_checked: 102524, y_checked: 2228854406 },
                AmmSimulationStepData { x_added: 1236, y_added: 0, x_checked: 103759, y_checked: 2202410189 },
                AmmSimulationStepData { x_added: 904, y_added: 0, x_checked: 104662, y_checked: 2183470880 },
                AmmSimulationStepData { x_added: 831, y_added: 0, x_checked: 105492, y_checked: 2166353168 },
                AmmSimulationStepData { x_added: 0, y_added: 20906540, x_checked: 104487, y_checked: 2187249254 },
                AmmSimulationStepData { x_added: 1311, y_added: 0, x_checked: 105797, y_checked: 2160247964 },
                AmmSimulationStepData { x_added: 1559, y_added: 0, x_checked: 107355, y_checked: 2128976478 },
                AmmSimulationStepData { x_added: 2740, y_added: 0, x_checked: 110093, y_checked: 2076161091 },
                AmmSimulationStepData { x_added: 2775, y_added: 0, x_checked: 112866, y_checked: 2025277586 },
                AmmSimulationStepData { x_added: 1881, y_added: 0, x_checked: 114746, y_checked: 1992182220 },
                AmmSimulationStepData { x_added: 1136, y_added: 0, x_checked: 115881, y_checked: 1972720802 },
                AmmSimulationStepData { x_added: 6298, y_added: 0, x_checked: 122175, y_checked: 1871338660 },
                AmmSimulationStepData { x_added: 3838, y_added: 0, x_checked: 126011, y_checked: 1814515765 },
                AmmSimulationStepData { x_added: 2202, y_added: 0, x_checked: 128211, y_checked: 1783463563 },
                AmmSimulationStepData { x_added: 0, y_added: 41654674, x_checked: 125294, y_checked: 1825097409 },
                AmmSimulationStepData { x_added: 1837, y_added: 0, x_checked: 127130, y_checked: 1798810264 },
                AmmSimulationStepData { x_added: 8817, y_added: 0, x_checked: 135942, y_checked: 1682492874 },
                AmmSimulationStepData { x_added: 0, y_added: 40641113, x_checked: 132746, y_checked: 1723113666 },
                AmmSimulationStepData { x_added: 0, y_added: 19494593, x_checked: 131266, y_checked: 1742598511 },
                AmmSimulationStepData { x_added: 2199, y_added: 0, x_checked: 133463, y_checked: 1713989796 },
                AmmSimulationStepData { x_added: 0, y_added: 87845211, x_checked: 126975, y_checked: 1801791084 },
                AmmSimulationStepData { x_added: 0, y_added: 69643034, x_checked: 122264, y_checked: 1871399296 },
                AmmSimulationStepData { x_added: 0, y_added: 32263990, x_checked: 120198, y_checked: 1903647154 },
                AmmSimulationStepData { x_added: 918, y_added: 0, x_checked: 121115, y_checked: 1889280837 },
                AmmSimulationStepData { x_added: 0, y_added: 43171960, x_checked: 118418, y_checked: 1932431211 },
                AmmSimulationStepData { x_added: 0, y_added: 25577053, x_checked: 116876, y_checked: 1957995475 },
                AmmSimulationStepData { x_added: 0, y_added: 26795904, x_checked: 115303, y_checked: 1984777981 },
                AmmSimulationStepData { x_added: 3696, y_added: 0, x_checked: 118997, y_checked: 1923326545 },
                AmmSimulationStepData { x_added: 1528, y_added: 0, x_checked: 120524, y_checked: 1899021647 },
                AmmSimulationStepData { x_added: 3949, y_added: 0, x_checked: 124471, y_checked: 1838951037 },
                AmmSimulationStepData { x_added: 1992, y_added: 0, x_checked: 126462, y_checked: 1810070416 },
                AmmSimulationStepData { x_added: 0, y_added: 20272712, x_checked: 125066, y_checked: 1830332991 },
                AmmSimulationStepData { x_added: 2193, y_added: 0, x_checked: 127257, y_checked: 1798904731 },
                AmmSimulationStepData { x_added: 2133, y_added: 0, x_checked: 129388, y_checked: 1769359103 },
                AmmSimulationStepData { x_added: 3054, y_added: 0, x_checked: 132440, y_checked: 1728689710 },
                AmmSimulationStepData { x_added: 0, y_added: 14141446, x_checked: 131369, y_checked: 1742824085 },
                AmmSimulationStepData { x_added: 1900, y_added: 0, x_checked: 133268, y_checked: 1718054203 },
                AmmSimulationStepData { x_added: 1350, y_added: 0, x_checked: 134617, y_checked: 1700888084 },
                AmmSimulationStepData { x_added: 0, y_added: 132863711, x_checked: 124891, y_checked: 1833685363 },
                AmmSimulationStepData { x_added: 1061, y_added: 0, x_checked: 125951, y_checked: 1818296430 },
                AmmSimulationStepData { x_added: 2489, y_added: 0, x_checked: 128438, y_checked: 1783185163 },
                AmmSimulationStepData { x_added: 7417, y_added: 0, x_checked: 135851, y_checked: 1686117675 },
                AmmSimulationStepData { x_added: 2075, y_added: 0, x_checked: 137924, y_checked: 1660847550 },
                AmmSimulationStepData { x_added: 2362, y_added: 0, x_checked: 140284, y_checked: 1632976928 },
                AmmSimulationStepData { x_added: 0, y_added: 30694575, x_checked: 137704, y_checked: 1663656155 },
                AmmSimulationStepData { x_added: 0, y_added: 97178855, x_checked: 130126, y_checked: 1760786420 },
                AmmSimulationStepData { x_added: 1463, y_added: 0, x_checked: 131588, y_checked: 1741276248 },
                AmmSimulationStepData { x_added: 0, y_added: 13998772, x_checked: 130542, y_checked: 1755268020 },
                AmmSimulationStepData { x_added: 1760, y_added: 0, x_checked: 132301, y_checked: 1731996417 },
                AmmSimulationStepData { x_added: 1019, y_added: 0, x_checked: 133319, y_checked: 1718809881 },
                AmmSimulationStepData { x_added: 1524, y_added: 0, x_checked: 134842, y_checked: 1699446852 },
                AmmSimulationStepData { x_added: 1475, y_added: 0, x_checked: 136316, y_checked: 1681119876 },
                AmmSimulationStepData { x_added: 1998, y_added: 0, x_checked: 138313, y_checked: 1656907316 },
                AmmSimulationStepData { x_added: 0, y_added: 26652979, x_checked: 136130, y_checked: 1683546968 },
                AmmSimulationStepData { x_added: 1543, y_added: 0, x_checked: 137672, y_checked: 1664738711 },
                AmmSimulationStepData { x_added: 1154, y_added: 0, x_checked: 138825, y_checked: 1650948033 },
                AmmSimulationStepData { x_added: 0, y_added: 12684261, x_checked: 137770, y_checked: 1663625951 },
                AmmSimulationStepData { x_added: 1340, y_added: 0, x_checked: 139109, y_checked: 1647660022 },
                AmmSimulationStepData { x_added: 0, y_added: 21234233, x_checked: 137345, y_checked: 1668883637 },
                AmmSimulationStepData { x_added: 0, y_added: 22524754, x_checked: 135522, y_checked: 1691397128 },
                AmmSimulationStepData { x_added: 1981, y_added: 0, x_checked: 137502, y_checked: 1667101985 },
                AmmSimulationStepData { x_added: 6762, y_added: 0, x_checked: 144260, y_checked: 1589192247 },
                AmmSimulationStepData { x_added: 4201, y_added: 0, x_checked: 148458, y_checked: 1544368520 },
                AmmSimulationStepData { x_added: 3104, y_added: 0, x_checked: 151560, y_checked: 1512839565 },
                AmmSimulationStepData { x_added: 0, y_added: 49883167, x_checked: 146737, y_checked: 1562697790 },
                AmmSimulationStepData { x_added: 2310, y_added: 0, x_checked: 149045, y_checked: 1538560952 },
                AmmSimulationStepData { x_added: 0, y_added: 24091153, x_checked: 146754, y_checked: 1562640059 },
                AmmSimulationStepData { x_added: 0, y_added: 24479418, x_checked: 144498, y_checked: 1587107237 },
                AmmSimulationStepData { x_added: 1197, y_added: 0, x_checked: 145694, y_checked: 1574111109 },
                AmmSimulationStepData { x_added: 0, y_added: 75917975, x_checked: 139010, y_checked: 1649991125 },
                AmmSimulationStepData { x_added: 0, y_added: 84974182, x_checked: 132222, y_checked: 1734922819 },
                AmmSimulationStepData { x_added: 1130, y_added: 0, x_checked: 133351, y_checked: 1720273008 },
                AmmSimulationStepData { x_added: 0, y_added: 47574623, x_checked: 129773, y_checked: 1767823843 },
                AmmSimulationStepData { x_added: 0, y_added: 97722280, x_checked: 122995, y_checked: 1865497261 },
                AmmSimulationStepData { x_added: 2714, y_added: 0, x_checked: 125707, y_checked: 1825352710 },
                AmmSimulationStepData { x_added: 0, y_added: 34018653, x_checked: 123414, y_checked: 1859354353 },
                AmmSimulationStepData { x_added: 0, y_added: 37271872, x_checked: 120996, y_checked: 1896607589 },
                AmmSimulationStepData { x_added: 1257, y_added: 0, x_checked: 122252, y_checked: 1877183528 },
                AmmSimulationStepData { x_added: 5355, y_added: 0, x_checked: 127604, y_checked: 1798647549 },
                AmmSimulationStepData { x_added: 0, y_added: 58237563, x_checked: 123614, y_checked: 1856855993 },
                AmmSimulationStepData { x_added: 0, y_added: 46125931, x_checked: 120627, y_checked: 1902958861 },
                AmmSimulationStepData { x_added: 4158, y_added: 0, x_checked: 124782, y_checked: 1839756182 },
                AmmSimulationStepData { x_added: 1271, y_added: 0, x_checked: 126052, y_checked: 1821278053 },
                AmmSimulationStepData { x_added: 2535, y_added: 0, x_checked: 128585, y_checked: 1785497839 },
                AmmSimulationStepData { x_added: 2250, y_added: 0, x_checked: 130833, y_checked: 1754899521 },
                AmmSimulationStepData { x_added: 10174, y_added: 0, x_checked: 141001, y_checked: 1628648832 },
                AmmSimulationStepData { x_added: 0, y_added: 14139842, x_checked: 139791, y_checked: 1642781604 },
                AmmSimulationStepData { x_added: 2632, y_added: 0, x_checked: 142421, y_checked: 1612524634 },
                AmmSimulationStepData { x_added: 2039, y_added: 0, x_checked: 144458, y_checked: 1589852484 },
                AmmSimulationStepData { x_added: 0, y_added: 19620972, x_checked: 142703, y_checked: 1609463645 },
            ]
        };
        test_utils_amm_simulate(admin, &s);
    }

    fun test_amm_simulate_3000_impl(admin: &signer) acquires AptoswapCap, LSPCapabilities, Pool {
        let s = AmmSimulationData {
            x_init: 100000,
            y_init: 1481000000,
            data: vector [
                AmmSimulationStepData { x_added: 0, y_added: 13664876, x_checked: 99089, y_checked: 1494658043 },
                AmmSimulationStepData { x_added: 0, y_added: 14795528, x_checked: 98121, y_checked: 1509446173 },
                AmmSimulationStepData { x_added: 873, y_added: 0, x_checked: 98993, y_checked: 1496195252 },
                AmmSimulationStepData { x_added: 0, y_added: 13158377, x_checked: 98133, y_checked: 1509347049 },
                AmmSimulationStepData { x_added: 1287, y_added: 0, x_checked: 99419, y_checked: 1489883358 },
                AmmSimulationStepData { x_added: 2954, y_added: 0, x_checked: 102371, y_checked: 1447033729 },
                AmmSimulationStepData { x_added: 0, y_added: 16541679, x_checked: 101218, y_checked: 1463567137 },
                AmmSimulationStepData { x_added: 769, y_added: 0, x_checked: 101986, y_checked: 1452574311 },
                AmmSimulationStepData { x_added: 0, y_added: 18068915, x_checked: 100737, y_checked: 1470634191 },
                AmmSimulationStepData { x_added: 1363, y_added: 0, x_checked: 102099, y_checked: 1451072791 },
                AmmSimulationStepData { x_added: 824, y_added: 0, x_checked: 102922, y_checked: 1439511470 },
                AmmSimulationStepData { x_added: 0, y_added: 28710658, x_checked: 100916, y_checked: 1468207772 },
                AmmSimulationStepData { x_added: 849, y_added: 0, x_checked: 101764, y_checked: 1456016112 },
                AmmSimulationStepData { x_added: 0, y_added: 15577293, x_checked: 100690, y_checked: 1471585616 },
                AmmSimulationStepData { x_added: 894, y_added: 0, x_checked: 101583, y_checked: 1458692220 },
                AmmSimulationStepData { x_added: 0, y_added: 14457238, x_checked: 100590, y_checked: 1473142229 },
                AmmSimulationStepData { x_added: 2880, y_added: 0, x_checked: 103468, y_checked: 1432276985 },
                AmmSimulationStepData { x_added: 0, y_added: 15586557, x_checked: 102358, y_checked: 1447855748 },
                AmmSimulationStepData { x_added: 1087, y_added: 0, x_checked: 103444, y_checked: 1432697081 },
                AmmSimulationStepData { x_added: 1047, y_added: 0, x_checked: 104490, y_checked: 1418395752 },
                AmmSimulationStepData { x_added: 0, y_added: 10702712, x_checked: 103710, y_checked: 1429093112 },
                AmmSimulationStepData { x_added: 854, y_added: 0, x_checked: 104563, y_checked: 1417475581 },
                AmmSimulationStepData { x_added: 1009, y_added: 0, x_checked: 105571, y_checked: 1403981313 },
                AmmSimulationStepData { x_added: 980, y_added: 0, x_checked: 106550, y_checked: 1391120456 },
                AmmSimulationStepData { x_added: 1337, y_added: 0, x_checked: 107886, y_checked: 1373944538 },
                AmmSimulationStepData { x_added: 1970, y_added: 0, x_checked: 109855, y_checked: 1349379886 },
                AmmSimulationStepData { x_added: 0, y_added: 11607570, x_checked: 108921, y_checked: 1360981652 },
                AmmSimulationStepData { x_added: 11741, y_added: 0, x_checked: 120656, y_checked: 1228918165 },
                AmmSimulationStepData { x_added: 0, y_added: 41002755, x_checked: 116772, y_checked: 1269900418 },
                AmmSimulationStepData { x_added: 1032, y_added: 0, x_checked: 117803, y_checked: 1258818435 },
                AmmSimulationStepData { x_added: 0, y_added: 12806835, x_checked: 116621, y_checked: 1271618866 },
                AmmSimulationStepData { x_added: 1352, y_added: 0, x_checked: 117972, y_checked: 1257099076 },
                AmmSimulationStepData { x_added: 944, y_added: 0, x_checked: 118915, y_checked: 1247161702 },
                AmmSimulationStepData { x_added: 1919, y_added: 0, x_checked: 120833, y_checked: 1227416111 },
                AmmSimulationStepData { x_added: 0, y_added: 11564764, x_checked: 119709, y_checked: 1238975092 },
                AmmSimulationStepData { x_added: 1374, y_added: 0, x_checked: 121082, y_checked: 1224966297 },
                AmmSimulationStepData { x_added: 0, y_added: 21506359, x_checked: 119000, y_checked: 1246461902 },
                AmmSimulationStepData { x_added: 1789, y_added: 0, x_checked: 120788, y_checked: 1228061618 },
                AmmSimulationStepData { x_added: 0, y_added: 13885079, x_checked: 119442, y_checked: 1241939754 },
                AmmSimulationStepData { x_added: 0, y_added: 53771343, x_checked: 114500, y_checked: 1295684211 },
                AmmSimulationStepData { x_added: 0, y_added: 11261702, x_checked: 113517, y_checked: 1306940282 },
                AmmSimulationStepData { x_added: 0, y_added: 16515041, x_checked: 112105, y_checked: 1323447065 },
                AmmSimulationStepData { x_added: 0, y_added: 15388670, x_checked: 110821, y_checked: 1338828040 },
                AmmSimulationStepData { x_added: 1023, y_added: 0, x_checked: 111843, y_checked: 1326629670 },
                AmmSimulationStepData { x_added: 0, y_added: 28829094, x_checked: 109472, y_checked: 1355444349 },
                AmmSimulationStepData { x_added: 983, y_added: 0, x_checked: 110454, y_checked: 1343430153 },
                AmmSimulationStepData { x_added: 0, y_added: 13160883, x_checked: 109386, y_checked: 1356584455 },
                AmmSimulationStepData { x_added: 1244, y_added: 0, x_checked: 110629, y_checked: 1341390710 },
                AmmSimulationStepData { x_added: 0, y_added: 12118462, x_checked: 109642, y_checked: 1353503112 },
                AmmSimulationStepData { x_added: 847, y_added: 0, x_checked: 110488, y_checked: 1343175890 },
                AmmSimulationStepData { x_added: 0, y_added: 16063008, x_checked: 109187, y_checked: 1359230866 },
                AmmSimulationStepData { x_added: 0, y_added: 10994063, x_checked: 108314, y_checked: 1370219431 },
                AmmSimulationStepData { x_added: 879, y_added: 0, x_checked: 109192, y_checked: 1359239003 },
                AmmSimulationStepData { x_added: 0, y_added: 13834565, x_checked: 108096, y_checked: 1373066650 },
                AmmSimulationStepData { x_added: 0, y_added: 28090775, x_checked: 105936, y_checked: 1401143379 },
                AmmSimulationStepData { x_added: 0, y_added: 12659274, x_checked: 104991, y_checked: 1413796323 },
                AmmSimulationStepData { x_added: 1058, y_added: 0, x_checked: 106048, y_checked: 1399744352 },
                AmmSimulationStepData { x_added: 942, y_added: 0, x_checked: 106989, y_checked: 1387472091 },
                AmmSimulationStepData { x_added: 0, y_added: 55460978, x_checked: 102889, y_checked: 1442905338 },
                AmmSimulationStepData { x_added: 906, y_added: 0, x_checked: 103794, y_checked: 1430365710 },
                AmmSimulationStepData { x_added: 1245, y_added: 0, x_checked: 105038, y_checked: 1413479241 },
                AmmSimulationStepData { x_added: 1256, y_added: 0, x_checked: 106293, y_checked: 1396842877 },
                AmmSimulationStepData { x_added: 925, y_added: 0, x_checked: 107217, y_checked: 1384843584 },
                AmmSimulationStepData { x_added: 0, y_added: 13630414, x_checked: 106176, y_checked: 1398467182 },
                AmmSimulationStepData { x_added: 0, y_added: 12529460, x_checked: 105236, y_checked: 1410990377 },
                AmmSimulationStepData { x_added: 1215, y_added: 0, x_checked: 106450, y_checked: 1394951275 },
                AmmSimulationStepData { x_added: 0, y_added: 12920026, x_checked: 105477, y_checked: 1407864840 },
                AmmSimulationStepData { x_added: 1813, y_added: 0, x_checked: 107289, y_checked: 1384151968 },
                AmmSimulationStepData { x_added: 909, y_added: 0, x_checked: 108197, y_checked: 1372574085 },
                AmmSimulationStepData { x_added: 0, y_added: 35011001, x_checked: 105514, y_checked: 1407567580 },
                AmmSimulationStepData { x_added: 1110, y_added: 0, x_checked: 106623, y_checked: 1392966476 },
                AmmSimulationStepData { x_added: 1335, y_added: 0, x_checked: 107957, y_checked: 1375804884 },
                AmmSimulationStepData { x_added: 1028, y_added: 0, x_checked: 108984, y_checked: 1362877638 },
                AmmSimulationStepData { x_added: 0, y_added: 11755462, x_checked: 108055, y_checked: 1374627222 },
                AmmSimulationStepData { x_added: 0, y_added: 36566939, x_checked: 105264, y_checked: 1411175877 },
                AmmSimulationStepData { x_added: 0, y_added: 36972624, x_checked: 102585, y_checked: 1448130014 },
                AmmSimulationStepData { x_added: 833, y_added: 0, x_checked: 103417, y_checked: 1436521337 },
                AmmSimulationStepData { x_added: 0, y_added: 15744270, x_checked: 102300, y_checked: 1452257734 },
                AmmSimulationStepData { x_added: 1426, y_added: 0, x_checked: 103725, y_checked: 1432361491 },
                AmmSimulationStepData { x_added: 0, y_added: 10867546, x_checked: 102947, y_checked: 1443223603 },
                AmmSimulationStepData { x_added: 0, y_added: 13060805, x_checked: 102027, y_checked: 1456277877 },
                AmmSimulationStepData { x_added: 1636, y_added: 0, x_checked: 103662, y_checked: 1433377997 },
                AmmSimulationStepData { x_added: 858, y_added: 0, x_checked: 104519, y_checked: 1421665869 },
                AmmSimulationStepData { x_added: 1976, y_added: 0, x_checked: 106494, y_checked: 1395365672 },
                AmmSimulationStepData { x_added: 2005, y_added: 0, x_checked: 108497, y_checked: 1369681097 },
                AmmSimulationStepData { x_added: 1087, y_added: 0, x_checked: 109583, y_checked: 1356144278 },
                AmmSimulationStepData { x_added: 0, y_added: 15754167, x_checked: 108329, y_checked: 1371890567 },
                AmmSimulationStepData { x_added: 0, y_added: 11605167, x_checked: 107424, y_checked: 1383489931 },
                AmmSimulationStepData { x_added: 1085, y_added: 0, x_checked: 108508, y_checked: 1369706672 },
                AmmSimulationStepData { x_added: 1219, y_added: 0, x_checked: 109726, y_checked: 1354551791 },
                AmmSimulationStepData { x_added: 884, y_added: 0, x_checked: 110609, y_checked: 1343774749 },
                AmmSimulationStepData { x_added: 1669, y_added: 0, x_checked: 112277, y_checked: 1323870433 },
                AmmSimulationStepData { x_added: 1869, y_added: 0, x_checked: 114145, y_checked: 1302262140 },
                AmmSimulationStepData { x_added: 931, y_added: 0, x_checked: 115075, y_checked: 1291771343 },
                AmmSimulationStepData { x_added: 0, y_added: 14073540, x_checked: 113839, y_checked: 1305837846 },
                AmmSimulationStepData { x_added: 0, y_added: 11446217, x_checked: 112853, y_checked: 1317278339 },
                AmmSimulationStepData { x_added: 1266, y_added: 0, x_checked: 114118, y_checked: 1302721949 },
                AmmSimulationStepData { x_added: 0, y_added: 18144599, x_checked: 112556, y_checked: 1320857475 },
                AmmSimulationStepData { x_added: 2674, y_added: 0, x_checked: 115228, y_checked: 1290306750 },
                AmmSimulationStepData { x_added: 2607, y_added: 0, x_checked: 117833, y_checked: 1261856180 },
                AmmSimulationStepData { x_added: 1016, y_added: 0, x_checked: 118848, y_checked: 1251111105 },
                AmmSimulationStepData { x_added: 0, y_added: 18230531, x_checked: 117147, y_checked: 1269332520 },
                AmmSimulationStepData { x_added: 0, y_added: 12313530, x_checked: 116025, y_checked: 1281639893 },
                AmmSimulationStepData { x_added: 1104, y_added: 0, x_checked: 117128, y_checked: 1269603147 },
                AmmSimulationStepData { x_added: 0, y_added: 10624947, x_checked: 116159, y_checked: 1280222781 },
                AmmSimulationStepData { x_added: 1189, y_added: 0, x_checked: 117347, y_checked: 1267294434 },
                AmmSimulationStepData { x_added: 2289, y_added: 0, x_checked: 119634, y_checked: 1243130371 },
                AmmSimulationStepData { x_added: 0, y_added: 28131701, x_checked: 116995, y_checked: 1271248006 },
                AmmSimulationStepData { x_added: 0, y_added: 14821880, x_checked: 115651, y_checked: 1286062475 },
                AmmSimulationStepData { x_added: 1517, y_added: 0, x_checked: 117167, y_checked: 1269465713 },
                AmmSimulationStepData { x_added: 0, y_added: 24425657, x_checked: 114962, y_checked: 1293879157 },
                AmmSimulationStepData { x_added: 1005, y_added: 0, x_checked: 115966, y_checked: 1282710310 },
                AmmSimulationStepData { x_added: 0, y_added: 14184563, x_checked: 114702, y_checked: 1296887780 },
                AmmSimulationStepData { x_added: 0, y_added: 10850302, x_checked: 113754, y_checked: 1307732656 },
                AmmSimulationStepData { x_added: 1201, y_added: 0, x_checked: 114954, y_checked: 1294126321 },
                AmmSimulationStepData { x_added: 0, y_added: 15466141, x_checked: 113601, y_checked: 1309584728 },
                AmmSimulationStepData { x_added: 1008, y_added: 0, x_checked: 114608, y_checked: 1298112078 },
                AmmSimulationStepData { x_added: 991, y_added: 0, x_checked: 115598, y_checked: 1287028237 },
                AmmSimulationStepData { x_added: 0, y_added: 64918917, x_checked: 110063, y_checked: 1351914694 },
                AmmSimulationStepData { x_added: 1259, y_added: 0, x_checked: 111321, y_checked: 1336685206 },
                AmmSimulationStepData { x_added: 0, y_added: 33177557, x_checked: 108633, y_checked: 1369846174 },
                AmmSimulationStepData { x_added: 0, y_added: 12883794, x_checked: 107624, y_checked: 1382723526 },
                AmmSimulationStepData { x_added: 845, y_added: 0, x_checked: 108468, y_checked: 1372002368 },
                AmmSimulationStepData { x_added: 1004, y_added: 0, x_checked: 109471, y_checked: 1359469004 },
                AmmSimulationStepData { x_added: 0, y_added: 11460094, x_checked: 108559, y_checked: 1370923367 },
                AmmSimulationStepData { x_added: 0, y_added: 15750001, x_checked: 107330, y_checked: 1386665492 },
                AmmSimulationStepData { x_added: 1402, y_added: 0, x_checked: 108731, y_checked: 1368848651 },
                AmmSimulationStepData { x_added: 1529, y_added: 0, x_checked: 110259, y_checked: 1349927738 },
                AmmSimulationStepData { x_added: 1076, y_added: 0, x_checked: 111334, y_checked: 1336929359 },
                AmmSimulationStepData { x_added: 0, y_added: 13276931, x_checked: 110243, y_checked: 1350199651 },
                AmmSimulationStepData { x_added: 1174, y_added: 0, x_checked: 111416, y_checked: 1336020574 },
                AmmSimulationStepData { x_added: 0, y_added: 14111567, x_checked: 110255, y_checked: 1350125085 },
                AmmSimulationStepData { x_added: 0, y_added: 26312603, x_checked: 108154, y_checked: 1376424531 },
                AmmSimulationStepData { x_added: 1046, y_added: 0, x_checked: 109199, y_checked: 1363290036 },
                AmmSimulationStepData { x_added: 0, y_added: 14849944, x_checked: 108026, y_checked: 1378132555 },
                AmmSimulationStepData { x_added: 1047, y_added: 0, x_checked: 109072, y_checked: 1364953813 },
                AmmSimulationStepData { x_added: 991, y_added: 0, x_checked: 110062, y_checked: 1352713021 },
                AmmSimulationStepData { x_added: 921, y_added: 0, x_checked: 110982, y_checked: 1341535791 },
                AmmSimulationStepData { x_added: 911, y_added: 0, x_checked: 111892, y_checked: 1330660969 },
                AmmSimulationStepData { x_added: 0, y_added: 20561438, x_checked: 110195, y_checked: 1351212126 },
                AmmSimulationStepData { x_added: 0, y_added: 29510504, x_checked: 107847, y_checked: 1380707874 },
                AmmSimulationStepData { x_added: 0, y_added: 18484205, x_checked: 106427, y_checked: 1399182836 },
                AmmSimulationStepData { x_added: 1134, y_added: 0, x_checked: 107560, y_checked: 1384482942 },
                AmmSimulationStepData { x_added: 1009, y_added: 0, x_checked: 108568, y_checked: 1371666608 },
                AmmSimulationStepData { x_added: 0, y_added: 14259291, x_checked: 107455, y_checked: 1385918769 },
                AmmSimulationStepData { x_added: 0, y_added: 26664602, x_checked: 105433, y_checked: 1412570038 },
                AmmSimulationStepData { x_added: 1303, y_added: 0, x_checked: 106735, y_checked: 1395391188 },
                AmmSimulationStepData { x_added: 878, y_added: 0, x_checked: 107612, y_checked: 1384057825 },
                AmmSimulationStepData { x_added: 0, y_added: 22052047, x_checked: 105930, y_checked: 1406098845 },
                AmmSimulationStepData { x_added: 801, y_added: 0, x_checked: 106730, y_checked: 1395598590 },
                AmmSimulationStepData { x_added: 0, y_added: 18824136, x_checked: 105314, y_checked: 1414413313 },
                AmmSimulationStepData { x_added: 0, y_added: 13174786, x_checked: 104345, y_checked: 1427581511 },
                AmmSimulationStepData { x_added: 0, y_added: 21384054, x_checked: 102810, y_checked: 1448954872 },
                AmmSimulationStepData { x_added: 0, y_added: 11704329, x_checked: 101989, y_checked: 1460653348 },
                AmmSimulationStepData { x_added: 0, y_added: 11323247, x_checked: 101207, y_checked: 1471970933 },
                AmmSimulationStepData { x_added: 0, y_added: 11234987, x_checked: 100443, y_checked: 1483200302 },
                AmmSimulationStepData { x_added: 2164, y_added: 0, x_checked: 102605, y_checked: 1452032554 },
                AmmSimulationStepData { x_added: 0, y_added: 12340722, x_checked: 101743, y_checked: 1464367105 },
                AmmSimulationStepData { x_added: 0, y_added: 32000051, x_checked: 99574, y_checked: 1496351155 },
                AmmSimulationStepData { x_added: 1000, y_added: 0, x_checked: 100573, y_checked: 1481531967 },
                AmmSimulationStepData { x_added: 844, y_added: 0, x_checked: 101416, y_checked: 1469260495 },
                AmmSimulationStepData { x_added: 0, y_added: 40240132, x_checked: 98721, y_checked: 1509480506 },
                AmmSimulationStepData { x_added: 803, y_added: 0, x_checked: 99523, y_checked: 1497361586 },
                AmmSimulationStepData { x_added: 0, y_added: 12667753, x_checked: 98691, y_checked: 1510023005 },
                AmmSimulationStepData { x_added: 0, y_added: 12287571, x_checked: 97897, y_checked: 1522304432 },
                AmmSimulationStepData { x_added: 835, y_added: 0, x_checked: 98731, y_checked: 1509491097 },
                AmmSimulationStepData { x_added: 0, y_added: 12369055, x_checked: 97931, y_checked: 1521853967 },
                AmmSimulationStepData { x_added: 975, y_added: 0, x_checked: 98905, y_checked: 1506912710 },
                AmmSimulationStepData { x_added: 0, y_added: 15030170, x_checked: 97932, y_checked: 1521935364 },
                AmmSimulationStepData { x_added: 0, y_added: 15021127, x_checked: 96978, y_checked: 1536948980 },
                AmmSimulationStepData { x_added: 1055, y_added: 0, x_checked: 98032, y_checked: 1520470863 },
                AmmSimulationStepData { x_added: 948, y_added: 0, x_checked: 98979, y_checked: 1505969121 },
                AmmSimulationStepData { x_added: 0, y_added: 14447444, x_checked: 98042, y_checked: 1520409341 },
                AmmSimulationStepData { x_added: 1454, y_added: 0, x_checked: 99495, y_checked: 1498265900 },
                AmmSimulationStepData { x_added: 0, y_added: 13044198, x_checked: 98639, y_checked: 1511303575 },
                AmmSimulationStepData { x_added: 1897, y_added: 0, x_checked: 100535, y_checked: 1482875494 },
                AmmSimulationStepData { x_added: 0, y_added: 15133444, x_checked: 99523, y_checked: 1498001371 },
                AmmSimulationStepData { x_added: 0, y_added: 16343538, x_checked: 98453, y_checked: 1514336737 },
                AmmSimulationStepData { x_added: 0, y_added: 25112724, x_checked: 96852, y_checked: 1539436904 },
                AmmSimulationStepData { x_added: 903, y_added: 0, x_checked: 97754, y_checked: 1525278954 },
                AmmSimulationStepData { x_added: 1595, y_added: 0, x_checked: 99348, y_checked: 1500866876 },
                AmmSimulationStepData { x_added: 0, y_added: 19836924, x_checked: 98056, y_checked: 1520693881 },
                AmmSimulationStepData { x_added: 0, y_added: 12525580, x_checked: 97258, y_checked: 1533213198 },
                AmmSimulationStepData { x_added: 0, y_added: 14282508, x_checked: 96364, y_checked: 1547488564 },
                AmmSimulationStepData { x_added: 767, y_added: 0, x_checked: 97130, y_checked: 1535316160 },
                AmmSimulationStepData { x_added: 0, y_added: 17516022, x_checked: 96038, y_checked: 1552823423 },
                AmmSimulationStepData { x_added: 751, y_added: 0, x_checked: 96788, y_checked: 1540822598 },
                AmmSimulationStepData { x_added: 0, y_added: 13501369, x_checked: 95950, y_checked: 1554317216 },
                AmmSimulationStepData { x_added: 0, y_added: 15281163, x_checked: 95019, y_checked: 1569590738 },
                AmmSimulationStepData { x_added: 0, y_added: 14107014, x_checked: 94176, y_checked: 1583690698 },
                AmmSimulationStepData { x_added: 727, y_added: 0, x_checked: 94902, y_checked: 1571608590 },
                AmmSimulationStepData { x_added: 813, y_added: 0, x_checked: 95714, y_checked: 1558324523 },
                AmmSimulationStepData { x_added: 928, y_added: 0, x_checked: 96641, y_checked: 1543424672 },
                AmmSimulationStepData { x_added: 754, y_added: 0, x_checked: 97394, y_checked: 1531523162 },
                AmmSimulationStepData { x_added: 0, y_added: 11950347, x_checked: 96643, y_checked: 1543467533 },
                AmmSimulationStepData { x_added: 810, y_added: 0, x_checked: 97452, y_checked: 1530701524 },
                AmmSimulationStepData { x_added: 783, y_added: 0, x_checked: 98234, y_checked: 1518547164 },
                AmmSimulationStepData { x_added: 0, y_added: 24091324, x_checked: 96705, y_checked: 1542626442 },
                AmmSimulationStepData { x_added: 771, y_added: 0, x_checked: 97475, y_checked: 1530471927 },
                AmmSimulationStepData { x_added: 821, y_added: 0, x_checked: 98295, y_checked: 1517750693 },
                AmmSimulationStepData { x_added: 0, y_added: 13117083, x_checked: 97456, y_checked: 1530861217 },
                AmmSimulationStepData { x_added: 0, y_added: 45474697, x_checked: 94653, y_checked: 1576313176 },
                AmmSimulationStepData { x_added: 0, y_added: 13085354, x_checked: 93877, y_checked: 1589391987 },
                AmmSimulationStepData { x_added: 0, y_added: 15238811, x_checked: 92989, y_checked: 1604623178 },
                AmmSimulationStepData { x_added: 880, y_added: 0, x_checked: 93868, y_checked: 1589647949 },
                AmmSimulationStepData { x_added: 1071, y_added: 0, x_checked: 94938, y_checked: 1571781469 },
                AmmSimulationStepData { x_added: 0, y_added: 15313406, x_checked: 94025, y_checked: 1587087218 },
                AmmSimulationStepData { x_added: 0, y_added: 12095923, x_checked: 93316, y_checked: 1599177093 },
                AmmSimulationStepData { x_added: 0, y_added: 13658221, x_checked: 92529, y_checked: 1612828484 },
                AmmSimulationStepData { x_added: 768, y_added: 0, x_checked: 93296, y_checked: 1599603478 },
                AmmSimulationStepData { x_added: 0, y_added: 18678471, x_checked: 92223, y_checked: 1618272609 },
                AmmSimulationStepData { x_added: 0, y_added: 25829772, x_checked: 90779, y_checked: 1644089466 },
                AmmSimulationStepData { x_added: 1757, y_added: 0, x_checked: 92535, y_checked: 1612977388 },
                AmmSimulationStepData { x_added: 0, y_added: 17431496, x_checked: 91549, y_checked: 1630400168 },
                AmmSimulationStepData { x_added: 0, y_added: 15557752, x_checked: 90687, y_checked: 1645950141 },
                AmmSimulationStepData { x_added: 0, y_added: 27271532, x_checked: 89214, y_checked: 1673208037 },
                AmmSimulationStepData { x_added: 766, y_added: 0, x_checked: 89979, y_checked: 1659019326 },
                AmmSimulationStepData { x_added: 781, y_added: 0, x_checked: 90759, y_checked: 1644797646 },
                AmmSimulationStepData { x_added: 0, y_added: 16007996, x_checked: 89887, y_checked: 1660797638 },
                AmmSimulationStepData { x_added: 0, y_added: 19941642, x_checked: 88824, y_checked: 1680729309 },
                AmmSimulationStepData { x_added: 804, y_added: 0, x_checked: 89627, y_checked: 1665726816 },
                AmmSimulationStepData { x_added: 1303, y_added: 0, x_checked: 90929, y_checked: 1641947730 },
                AmmSimulationStepData { x_added: 0, y_added: 13293203, x_checked: 90201, y_checked: 1655234286 },
                AmmSimulationStepData { x_added: 0, y_added: 17412566, x_checked: 89265, y_checked: 1672638145 },
                AmmSimulationStepData { x_added: 1319, y_added: 0, x_checked: 90583, y_checked: 1648373730 },
                AmmSimulationStepData { x_added: 1657, y_added: 0, x_checked: 92239, y_checked: 1618867637 },
                AmmSimulationStepData { x_added: 0, y_added: 22408020, x_checked: 90984, y_checked: 1641264452 },
                AmmSimulationStepData { x_added: 0, y_added: 14446480, x_checked: 90193, y_checked: 1655703708 },
                AmmSimulationStepData { x_added: 0, y_added: 54929981, x_checked: 87306, y_checked: 1710606224 },
                AmmSimulationStepData { x_added: 0, y_added: 22545530, x_checked: 86174, y_checked: 1733140481 },
                AmmSimulationStepData { x_added: 913, y_added: 0, x_checked: 87086, y_checked: 1715049411 },
                AmmSimulationStepData { x_added: 899, y_added: 0, x_checked: 87984, y_checked: 1697602813 },
                AmmSimulationStepData { x_added: 0, y_added: 14938175, x_checked: 87219, y_checked: 1712533518 },
                AmmSimulationStepData { x_added: 796, y_added: 0, x_checked: 88014, y_checked: 1697103360 },
                AmmSimulationStepData { x_added: 0, y_added: 12857988, x_checked: 87355, y_checked: 1709954919 },
                AmmSimulationStepData { x_added: 0, y_added: 15448312, x_checked: 86576, y_checked: 1725395506 },
                AmmSimulationStepData { x_added: 1029, y_added: 0, x_checked: 87604, y_checked: 1705207034 },
                AmmSimulationStepData { x_added: 711, y_added: 0, x_checked: 88314, y_checked: 1691536338 },
                AmmSimulationStepData { x_added: 0, y_added: 14709555, x_checked: 87555, y_checked: 1706238538 },
                AmmSimulationStepData { x_added: 898, y_added: 0, x_checked: 88452, y_checked: 1688992699 },
                AmmSimulationStepData { x_added: 2926, y_added: 0, x_checked: 91376, y_checked: 1635088677 },
                AmmSimulationStepData { x_added: 0, y_added: 15218307, x_checked: 90536, y_checked: 1650299374 },
                AmmSimulationStepData { x_added: 1310, y_added: 0, x_checked: 91845, y_checked: 1626849710 },
                AmmSimulationStepData { x_added: 0, y_added: 15009900, x_checked: 91008, y_checked: 1641852105 },
                AmmSimulationStepData { x_added: 0, y_added: 16807822, x_checked: 90089, y_checked: 1658651523 },
                AmmSimulationStepData { x_added: 0, y_added: 15936352, x_checked: 89235, y_checked: 1674579906 },
                AmmSimulationStepData { x_added: 0, y_added: 13841167, x_checked: 88506, y_checked: 1688414152 },
                AmmSimulationStepData { x_added: 0, y_added: 13015205, x_checked: 87831, y_checked: 1701422849 },
                AmmSimulationStepData { x_added: 0, y_added: 14827578, x_checked: 87075, y_checked: 1716243013 },
                AmmSimulationStepData { x_added: 0, y_added: 12899535, x_checked: 86428, y_checked: 1729136098 },
                AmmSimulationStepData { x_added: 686, y_added: 0, x_checked: 87113, y_checked: 1715578684 },
                AmmSimulationStepData { x_added: 0, y_added: 16842897, x_checked: 86269, y_checked: 1732413159 },
                AmmSimulationStepData { x_added: 3365, y_added: 0, x_checked: 89632, y_checked: 1667580318 },
                AmmSimulationStepData { x_added: 0, y_added: 12963729, x_checked: 88943, y_checked: 1680537565 },
                AmmSimulationStepData { x_added: 0, y_added: 20736418, x_checked: 87863, y_checked: 1701263614 },
                AmmSimulationStepData { x_added: 674, y_added: 0, x_checked: 88536, y_checked: 1688369722 },
                AmmSimulationStepData { x_added: 0, y_added: 14203149, x_checked: 87800, y_checked: 1702565769 },
                AmmSimulationStepData { x_added: 0, y_added: 16526809, x_checked: 86959, y_checked: 1719084314 },
                AmmSimulationStepData { x_added: 1073, y_added: 0, x_checked: 88031, y_checked: 1698207990 },
                AmmSimulationStepData { x_added: 0, y_added: 14789935, x_checked: 87274, y_checked: 1712990530 },
                AmmSimulationStepData { x_added: 0, y_added: 13017402, x_checked: 86618, y_checked: 1726001423 },
                AmmSimulationStepData { x_added: 0, y_added: 16044156, x_checked: 85823, y_checked: 1742037556 },
                AmmSimulationStepData { x_added: 1273, y_added: 0, x_checked: 87095, y_checked: 1716674389 },
                AmmSimulationStepData { x_added: 0, y_added: 13013749, x_checked: 86442, y_checked: 1729681631 },
                AmmSimulationStepData { x_added: 0, y_added: 114750017, x_checked: 81080, y_checked: 1844374272 },
                AmmSimulationStepData { x_added: 622, y_added: 0, x_checked: 81701, y_checked: 1830400201 },
                AmmSimulationStepData { x_added: 931, y_added: 0, x_checked: 82631, y_checked: 1809865020 },
                AmmSimulationStepData { x_added: 751, y_added: 0, x_checked: 83381, y_checked: 1793628570 },
                AmmSimulationStepData { x_added: 0, y_added: 14726964, x_checked: 82704, y_checked: 1808348170 },
                AmmSimulationStepData { x_added: 655, y_added: 0, x_checked: 83358, y_checked: 1794203502 },
                AmmSimulationStepData { x_added: 0, y_added: 18653856, x_checked: 82503, y_checked: 1812848031 },
                AmmSimulationStepData { x_added: 0, y_added: 16088413, x_checked: 81780, y_checked: 1828928399 },
                AmmSimulationStepData { x_added: 0, y_added: 16997861, x_checked: 81030, y_checked: 1845917761 },
                AmmSimulationStepData { x_added: 1505, y_added: 0, x_checked: 82534, y_checked: 1812367820 },
                AmmSimulationStepData { x_added: 866, y_added: 0, x_checked: 83399, y_checked: 1793634775 },
                AmmSimulationStepData { x_added: 0, y_added: 14753260, x_checked: 82721, y_checked: 1808380658 },
                AmmSimulationStepData { x_added: 641, y_added: 0, x_checked: 83361, y_checked: 1794539959 },
                AmmSimulationStepData { x_added: 0, y_added: 17199657, x_checked: 82572, y_checked: 1811731016 },
                AmmSimulationStepData { x_added: 0, y_added: 14375104, x_checked: 81924, y_checked: 1826098932 },
                AmmSimulationStepData { x_added: 712, y_added: 0, x_checked: 82635, y_checked: 1810430808 },
                AmmSimulationStepData { x_added: 0, y_added: 13582274, x_checked: 82022, y_checked: 1824006290 },
                AmmSimulationStepData { x_added: 677, y_added: 0, x_checked: 82698, y_checked: 1809140030 },
                AmmSimulationStepData { x_added: 0, y_added: 18479364, x_checked: 81865, y_checked: 1827610154 },
                AmmSimulationStepData { x_added: 641, y_added: 0, x_checked: 82505, y_checked: 1813477150 },
                AmmSimulationStepData { x_added: 0, y_added: 17025826, x_checked: 81740, y_checked: 1830494463 },
                AmmSimulationStepData { x_added: 0, y_added: 14394507, x_checked: 81105, y_checked: 1844881772 },
                AmmSimulationStepData { x_added: 0, y_added: 17418898, x_checked: 80349, y_checked: 1862291960 },
                AmmSimulationStepData { x_added: 0, y_added: 29919184, x_checked: 79083, y_checked: 1892196184 },
                AmmSimulationStepData { x_added: 0, y_added: 23735703, x_checked: 78107, y_checked: 1915920019 },
                AmmSimulationStepData { x_added: 608, y_added: 0, x_checked: 78714, y_checked: 1901193782 },
                AmmSimulationStepData { x_added: 0, y_added: 15444790, x_checked: 78082, y_checked: 1916630849 },
                AmmSimulationStepData { x_added: 0, y_added: 20179631, x_checked: 77271, y_checked: 1936800390 },
                AmmSimulationStepData { x_added: 0, y_added: 14702615, x_checked: 76691, y_checked: 1951495653 },
                AmmSimulationStepData { x_added: 0, y_added: 18987251, x_checked: 75955, y_checked: 1970473410 },
                AmmSimulationStepData { x_added: 0, y_added: 15326451, x_checked: 75371, y_checked: 1985792197 },
                AmmSimulationStepData { x_added: 632, y_added: 0, x_checked: 76002, y_checked: 1969357154 },
                AmmSimulationStepData { x_added: 675, y_added: 0, x_checked: 76676, y_checked: 1952096962 },
                AmmSimulationStepData { x_added: 603, y_added: 0, x_checked: 77278, y_checked: 1936940146 },
                AmmSimulationStepData { x_added: 614, y_added: 0, x_checked: 77891, y_checked: 1921745826 },
                AmmSimulationStepData { x_added: 0, y_added: 28299366, x_checked: 76764, y_checked: 1950031042 },
                AmmSimulationStepData { x_added: 0, y_added: 16426020, x_checked: 76125, y_checked: 1966448848 },
                AmmSimulationStepData { x_added: 0, y_added: 14929189, x_checked: 75554, y_checked: 1981370572 },
                AmmSimulationStepData { x_added: 971, y_added: 0, x_checked: 76524, y_checked: 1956331886 },
                AmmSimulationStepData { x_added: 0, y_added: 37634598, x_checked: 75084, y_checked: 1993947666 },
                AmmSimulationStepData { x_added: 0, y_added: 15771982, x_checked: 74497, y_checked: 2009711762 },
                AmmSimulationStepData { x_added: 0, y_added: 15833794, x_checked: 73917, y_checked: 2025537639 },
                AmmSimulationStepData { x_added: 0, y_added: 15787282, x_checked: 73348, y_checked: 2041317027 },
                AmmSimulationStepData { x_added: 0, y_added: 23010422, x_checked: 72533, y_checked: 2064315943 },
                AmmSimulationStepData { x_added: 0, y_added: 17170920, x_checked: 71937, y_checked: 2081478277 },
                AmmSimulationStepData { x_added: 0, y_added: 54567451, x_checked: 70105, y_checked: 2136018444 },
                AmmSimulationStepData { x_added: 644, y_added: 0, x_checked: 70748, y_checked: 2116664872 },
                AmmSimulationStepData { x_added: 0, y_added: 17695898, x_checked: 70164, y_checked: 2134351922 },
                AmmSimulationStepData { x_added: 649, y_added: 0, x_checked: 70812, y_checked: 2114880219 },
                AmmSimulationStepData { x_added: 544, y_added: 0, x_checked: 71355, y_checked: 2098845152 },
                AmmSimulationStepData { x_added: 0, y_added: 16368464, x_checked: 70805, y_checked: 2115205431 },
                AmmSimulationStepData { x_added: 0, y_added: 19486048, x_checked: 70161, y_checked: 2134681735 },
                AmmSimulationStepData { x_added: 0, y_added: 16781481, x_checked: 69616, y_checked: 2151454825 },
                AmmSimulationStepData { x_added: 0, y_added: 19994016, x_checked: 68977, y_checked: 2171438843 },
                AmmSimulationStepData { x_added: 0, y_added: 17217716, x_checked: 68436, y_checked: 2188647950 },
                AmmSimulationStepData { x_added: 0, y_added: 27235035, x_checked: 67598, y_checked: 2215869367 },
                AmmSimulationStepData { x_added: 0, y_added: 21939168, x_checked: 66938, y_checked: 2237797565 },
                AmmSimulationStepData { x_added: 677, y_added: 0, x_checked: 67614, y_checked: 2215489757 },
                AmmSimulationStepData { x_added: 0, y_added: 18471779, x_checked: 67057, y_checked: 2233952300 },
                AmmSimulationStepData { x_added: 511, y_added: 0, x_checked: 67567, y_checked: 2217155915 },
                AmmSimulationStepData { x_added: 0, y_added: 16871824, x_checked: 67059, y_checked: 2234019303 },
                AmmSimulationStepData { x_added: 540, y_added: 0, x_checked: 67598, y_checked: 2216271680 },
                AmmSimulationStepData { x_added: 0, y_added: 25652962, x_checked: 66827, y_checked: 2241911815 },
                AmmSimulationStepData { x_added: 678, y_added: 0, x_checked: 67504, y_checked: 2219493362 },
                AmmSimulationStepData { x_added: 0, y_added: 17388046, x_checked: 66981, y_checked: 2236872713 },
                AmmSimulationStepData { x_added: 0, y_added: 19341627, x_checked: 66409, y_checked: 2256204669 },
                AmmSimulationStepData { x_added: 0, y_added: 17807950, x_checked: 65891, y_checked: 2274003715 },
                AmmSimulationStepData { x_added: 0, y_added: 19462689, x_checked: 65334, y_checked: 2293456672 },
                AmmSimulationStepData { x_added: 0, y_added: 17394304, x_checked: 64844, y_checked: 2310842278 },
                AmmSimulationStepData { x_added: 0, y_added: 18123473, x_checked: 64341, y_checked: 2328956689 },
                AmmSimulationStepData { x_added: 0, y_added: 20121255, x_checked: 63792, y_checked: 2349067883 },
                AmmSimulationStepData { x_added: 0, y_added: 25083978, x_checked: 63121, y_checked: 2374139319 },
                AmmSimulationStepData { x_added: 0, y_added: 18597061, x_checked: 62632, y_checked: 2392727081 },
                AmmSimulationStepData { x_added: 0, y_added: 19968293, x_checked: 62116, y_checked: 2412685389 },
                AmmSimulationStepData { x_added: 0, y_added: 23210179, x_checked: 61526, y_checked: 2435883962 },
                AmmSimulationStepData { x_added: 476, y_added: 0, x_checked: 62001, y_checked: 2417300225 },
                AmmSimulationStepData { x_added: 0, y_added: 19505281, x_checked: 61507, y_checked: 2436795753 },
                AmmSimulationStepData { x_added: 621, y_added: 0, x_checked: 62127, y_checked: 2412555274 },
                AmmSimulationStepData { x_added: 477, y_added: 0, x_checked: 62603, y_checked: 2394287975 },
                AmmSimulationStepData { x_added: 0, y_added: 19631773, x_checked: 62096, y_checked: 2413909932 },
                AmmSimulationStepData { x_added: 469, y_added: 0, x_checked: 62564, y_checked: 2395929656 },
                AmmSimulationStepData { x_added: 0, y_added: 18192557, x_checked: 62094, y_checked: 2414113116 },
                AmmSimulationStepData { x_added: 0, y_added: 18902945, x_checked: 61614, y_checked: 2433006609 },
                AmmSimulationStepData { x_added: 496, y_added: 0, x_checked: 62109, y_checked: 2413693613 },
                AmmSimulationStepData { x_added: 673, y_added: 0, x_checked: 62781, y_checked: 2387933810 },
                AmmSimulationStepData { x_added: 0, y_added: 19912203, x_checked: 62264, y_checked: 2407836056 },
                AmmSimulationStepData { x_added: 472, y_added: 0, x_checked: 62735, y_checked: 2389834764 },
                AmmSimulationStepData { x_added: 0, y_added: 18464019, x_checked: 62256, y_checked: 2408289550 },
                AmmSimulationStepData { x_added: 0, y_added: 22973456, x_checked: 61670, y_checked: 2431251519 },
                AmmSimulationStepData { x_added: 553, y_added: 0, x_checked: 62222, y_checked: 2409760225 },
                AmmSimulationStepData { x_added: 615, y_added: 0, x_checked: 62836, y_checked: 2386289282 },
                AmmSimulationStepData { x_added: 0, y_added: 20843676, x_checked: 62294, y_checked: 2407122536 },
                AmmSimulationStepData { x_added: 684, y_added: 0, x_checked: 62977, y_checked: 2381092359 },
                AmmSimulationStepData { x_added: 0, y_added: 18148271, x_checked: 62503, y_checked: 2399231555 },
                AmmSimulationStepData { x_added: 0, y_added: 18980564, x_checked: 62014, y_checked: 2418202628 },
                AmmSimulationStepData { x_added: 660, y_added: 0, x_checked: 62673, y_checked: 2392851842 },
                AmmSimulationStepData { x_added: 0, y_added: 25784238, x_checked: 62007, y_checked: 2418623187 },
                AmmSimulationStepData { x_added: 0, y_added: 19767745, x_checked: 61506, y_checked: 2438381048 },
                AmmSimulationStepData { x_added: 483, y_added: 0, x_checked: 61988, y_checked: 2419498996 },
                AmmSimulationStepData { x_added: 0, y_added: 20682847, x_checked: 61465, y_checked: 2440171501 },
                AmmSimulationStepData { x_added: 752, y_added: 0, x_checked: 62216, y_checked: 2410794055 },
                AmmSimulationStepData { x_added: 0, y_added: 18548614, x_checked: 61743, y_checked: 2429333394 },
                AmmSimulationStepData { x_added: 708, y_added: 0, x_checked: 62450, y_checked: 2401907696 },
                AmmSimulationStepData { x_added: 0, y_added: 20999781, x_checked: 61911, y_checked: 2422896977 },
                AmmSimulationStepData { x_added: 880, y_added: 0, x_checked: 62790, y_checked: 2389092882 },
                AmmSimulationStepData { x_added: 563, y_added: 0, x_checked: 63352, y_checked: 2367973829 },
                AmmSimulationStepData { x_added: 665, y_added: 0, x_checked: 64016, y_checked: 2343485457 },
                AmmSimulationStepData { x_added: 556, y_added: 0, x_checked: 64571, y_checked: 2323414720 },
                AmmSimulationStepData { x_added: 0, y_added: 17737476, x_checked: 64084, y_checked: 2341143327 },
                AmmSimulationStepData { x_added: 0, y_added: 60528449, x_checked: 62474, y_checked: 2401641511 },
                AmmSimulationStepData { x_added: 0, y_added: 21688892, x_checked: 61917, y_checked: 2423319558 },
                AmmSimulationStepData { x_added: 600, y_added: 0, x_checked: 62516, y_checked: 2400177194 },
                AmmSimulationStepData { x_added: 0, y_added: 18515269, x_checked: 62039, y_checked: 2418683205 },
                AmmSimulationStepData { x_added: 0, y_added: 19104428, x_checked: 61555, y_checked: 2437778080 },
                AmmSimulationStepData { x_added: 519, y_added: 0, x_checked: 62073, y_checked: 2417512683 },
                AmmSimulationStepData { x_added: 473, y_added: 0, x_checked: 62545, y_checked: 2399345487 },
                AmmSimulationStepData { x_added: 0, y_added: 26610870, x_checked: 61861, y_checked: 2425943051 },
                AmmSimulationStepData { x_added: 0, y_added: 21685439, x_checked: 61315, y_checked: 2447617647 },
                AmmSimulationStepData { x_added: 473, y_added: 0, x_checked: 61787, y_checked: 2428998560 },
                AmmSimulationStepData { x_added: 0, y_added: 18251585, x_checked: 61328, y_checked: 2447241019 },
                AmmSimulationStepData { x_added: 491, y_added: 0, x_checked: 61818, y_checked: 2427921529 },
                AmmSimulationStepData { x_added: 530, y_added: 0, x_checked: 62347, y_checked: 2407398398 },
                AmmSimulationStepData { x_added: 0, y_added: 21481420, x_checked: 61798, y_checked: 2428869077 },
                AmmSimulationStepData { x_added: 685, y_added: 0, x_checked: 62482, y_checked: 2402356774 },
                AmmSimulationStepData { x_added: 0, y_added: 19135677, x_checked: 61990, y_checked: 2421482883 },
                AmmSimulationStepData { x_added: 471, y_added: 0, x_checked: 62460, y_checked: 2403338627 },
                AmmSimulationStepData { x_added: 473, y_added: 0, x_checked: 62932, y_checked: 2385389014 },
                AmmSimulationStepData { x_added: 563, y_added: 0, x_checked: 63494, y_checked: 2364349862 },
                AmmSimulationStepData { x_added: 0, y_added: 39104213, x_checked: 62465, y_checked: 2403434522 },
                AmmSimulationStepData { x_added: 471, y_added: 0, x_checked: 62935, y_checked: 2385561430 },
                AmmSimulationStepData { x_added: 504, y_added: 0, x_checked: 63438, y_checked: 2366720925 },
                AmmSimulationStepData { x_added: 0, y_added: 26772760, x_checked: 62731, y_checked: 2393480298 },
                AmmSimulationStepData { x_added: 572, y_added: 0, x_checked: 63302, y_checked: 2371965444 },
                AmmSimulationStepData { x_added: 538, y_added: 0, x_checked: 63839, y_checked: 2352086667 },
                AmmSimulationStepData { x_added: 529, y_added: 0, x_checked: 64367, y_checked: 2332865078 },
                AmmSimulationStepData { x_added: 500, y_added: 0, x_checked: 64866, y_checked: 2314990234 },
                AmmSimulationStepData { x_added: 493, y_added: 0, x_checked: 65358, y_checked: 2297633829 },
                AmmSimulationStepData { x_added: 580, y_added: 0, x_checked: 65937, y_checked: 2277527138 },
                AmmSimulationStepData { x_added: 4039, y_added: 0, x_checked: 69973, y_checked: 2146498198 },
                AmmSimulationStepData { x_added: 667, y_added: 0, x_checked: 70639, y_checked: 2126320745 },
                AmmSimulationStepData { x_added: 712, y_added: 0, x_checked: 71350, y_checked: 2105191051 },
                AmmSimulationStepData { x_added: 1020, y_added: 0, x_checked: 72369, y_checked: 2075634711 },
                AmmSimulationStepData { x_added: 559, y_added: 0, x_checked: 72927, y_checked: 2059809509 },
                AmmSimulationStepData { x_added: 0, y_added: 16363988, x_checked: 72354, y_checked: 2076165315 },
                AmmSimulationStepData { x_added: 614, y_added: 0, x_checked: 72967, y_checked: 2058779761 },
                AmmSimulationStepData { x_added: 0, y_added: 24880702, x_checked: 72099, y_checked: 2083648022 },
                AmmSimulationStepData { x_added: 0, y_added: 17942500, x_checked: 71486, y_checked: 2101581550 },
                AmmSimulationStepData { x_added: 543, y_added: 0, x_checked: 72028, y_checked: 2085825379 },
                AmmSimulationStepData { x_added: 0, y_added: 17117882, x_checked: 71444, y_checked: 2102934702 },
                AmmSimulationStepData { x_added: 0, y_added: 17007065, x_checked: 70873, y_checked: 2119933263 },
                AmmSimulationStepData { x_added: 671, y_added: 0, x_checked: 71543, y_checked: 2100138804 },
                AmmSimulationStepData { x_added: 548, y_added: 0, x_checked: 72090, y_checked: 2084261326 },
                AmmSimulationStepData { x_added: 670, y_added: 0, x_checked: 72759, y_checked: 2065153855 },
                AmmSimulationStepData { x_added: 4080, y_added: 0, x_checked: 76836, y_checked: 1955854596 },
                AmmSimulationStepData { x_added: 698, y_added: 0, x_checked: 77533, y_checked: 1938322010 },
                AmmSimulationStepData { x_added: 930, y_added: 0, x_checked: 78462, y_checked: 1915445270 },
                AmmSimulationStepData { x_added: 842, y_added: 0, x_checked: 79303, y_checked: 1895203869 },
                AmmSimulationStepData { x_added: 805, y_added: 0, x_checked: 80107, y_checked: 1876252777 },
                AmmSimulationStepData { x_added: 0, y_added: 23322785, x_checked: 79127, y_checked: 1899563900 },
                AmmSimulationStepData { x_added: 1703, y_added: 0, x_checked: 80829, y_checked: 1859680203 },
                AmmSimulationStepData { x_added: 0, y_added: 16109500, x_checked: 80137, y_checked: 1875781648 },
                AmmSimulationStepData { x_added: 732, y_added: 0, x_checked: 80868, y_checked: 1858871639 },
                AmmSimulationStepData { x_added: 1141, y_added: 0, x_checked: 82008, y_checked: 1833098369 },
                AmmSimulationStepData { x_added: 639, y_added: 0, x_checked: 82646, y_checked: 1818991470 },
                AmmSimulationStepData { x_added: 652, y_added: 0, x_checked: 83297, y_checked: 1804818645 },
                AmmSimulationStepData { x_added: 0, y_added: 14145649, x_checked: 82652, y_checked: 1818957221 },
                AmmSimulationStepData { x_added: 0, y_added: 13894665, x_checked: 82028, y_checked: 1832844938 },
                AmmSimulationStepData { x_added: 0, y_added: 14358476, x_checked: 81393, y_checked: 1847196234 },
                AmmSimulationStepData { x_added: 0, y_added: 18365153, x_checked: 80595, y_checked: 1865552204 },
                AmmSimulationStepData { x_added: 0, y_added: 17964881, x_checked: 79829, y_checked: 1883508102 },
                AmmSimulationStepData { x_added: 0, y_added: 17157192, x_checked: 79111, y_checked: 1900656715 },
                AmmSimulationStepData { x_added: 0, y_added: 16375135, x_checked: 78438, y_checked: 1917023662 },
                AmmSimulationStepData { x_added: 0, y_added: 27947117, x_checked: 77315, y_checked: 1944956805 },
                AmmSimulationStepData { x_added: 862, y_added: 0, x_checked: 78176, y_checked: 1923609628 },
                AmmSimulationStepData { x_added: 0, y_added: 14679027, x_checked: 77586, y_checked: 1938281315 },
            ]
        };
        test_utils_amm_simulate(admin, &s);
    }

    fun test_amm_simulate_5000_impl(admin: &signer) acquires AptoswapCap, LSPCapabilities, Pool {
        let s = AmmSimulationData {
            x_init: 100000,
            y_init: 3948200000,
            data: vector [
                AmmSimulationStepData { x_added: 0, y_added: 29728174, x_checked: 99255, y_checked: 3977913309 },
                AmmSimulationStepData { x_added: 823, y_added: 0, x_checked: 100077, y_checked: 3945358290 },
                AmmSimulationStepData { x_added: 866, y_added: 0, x_checked: 100942, y_checked: 3911665676 },
                AmmSimulationStepData { x_added: 835, y_added: 0, x_checked: 101776, y_checked: 3879726025 },
                AmmSimulationStepData { x_added: 0, y_added: 29092459, x_checked: 101021, y_checked: 3908803937 },
                AmmSimulationStepData { x_added: 792, y_added: 0, x_checked: 101812, y_checked: 3878511763 },
                AmmSimulationStepData { x_added: 831, y_added: 0, x_checked: 102642, y_checked: 3847261174 },
                AmmSimulationStepData { x_added: 0, y_added: 44214375, x_checked: 101480, y_checked: 3891453441 },
                AmmSimulationStepData { x_added: 1117, y_added: 0, x_checked: 102596, y_checked: 3849236256 },
                AmmSimulationStepData { x_added: 0, y_added: 33632594, x_checked: 101710, y_checked: 3882852033 },
                AmmSimulationStepData { x_added: 844, y_added: 0, x_checked: 102553, y_checked: 3851047102 },
                AmmSimulationStepData { x_added: 1089, y_added: 0, x_checked: 103641, y_checked: 3810729978 },
                AmmSimulationStepData { x_added: 910, y_added: 0, x_checked: 104550, y_checked: 3777706349 },
                AmmSimulationStepData { x_added: 859, y_added: 0, x_checked: 105408, y_checked: 3747063221 },
                AmmSimulationStepData { x_added: 852, y_added: 0, x_checked: 106259, y_checked: 3717158937 },
                AmmSimulationStepData { x_added: 0, y_added: 29990574, x_checked: 105412, y_checked: 3747134515 },
                AmmSimulationStepData { x_added: 0, y_added: 46120046, x_checked: 104135, y_checked: 3793231500 },
                AmmSimulationStepData { x_added: 826, y_added: 0, x_checked: 104960, y_checked: 3763523751 },
                AmmSimulationStepData { x_added: 887, y_added: 0, x_checked: 105846, y_checked: 3732126385 },
                AmmSimulationStepData { x_added: 0, y_added: 53356528, x_checked: 104359, y_checked: 3785456234 },
                AmmSimulationStepData { x_added: 0, y_added: 30143714, x_checked: 103538, y_checked: 3815584876 },
                AmmSimulationStepData { x_added: 843, y_added: 0, x_checked: 104380, y_checked: 3784914559 },
                AmmSimulationStepData { x_added: 858, y_added: 0, x_checked: 105237, y_checked: 3754199039 },
                AmmSimulationStepData { x_added: 981, y_added: 0, x_checked: 106217, y_checked: 3719666375 },
                AmmSimulationStepData { x_added: 0, y_added: 28009854, x_checked: 105426, y_checked: 3747662224 },
                AmmSimulationStepData { x_added: 821, y_added: 0, x_checked: 106246, y_checked: 3718843008 },
                AmmSimulationStepData { x_added: 878, y_added: 0, x_checked: 107123, y_checked: 3688500693 },
                AmmSimulationStepData { x_added: 833, y_added: 0, x_checked: 107955, y_checked: 3660175446 },
                AmmSimulationStepData { x_added: 1227, y_added: 0, x_checked: 109181, y_checked: 3619207712 },
                AmmSimulationStepData { x_added: 916, y_added: 0, x_checked: 110096, y_checked: 3589226538 },
                AmmSimulationStepData { x_added: 881, y_added: 0, x_checked: 110976, y_checked: 3560861516 },
                AmmSimulationStepData { x_added: 894, y_added: 0, x_checked: 111869, y_checked: 3532531490 },
                AmmSimulationStepData { x_added: 0, y_added: 28447326, x_checked: 110978, y_checked: 3560964592 },
                AmmSimulationStepData { x_added: 961, y_added: 0, x_checked: 111938, y_checked: 3530519753 },
                AmmSimulationStepData { x_added: 0, y_added: 30760425, x_checked: 110975, y_checked: 3561264797 },
                AmmSimulationStepData { x_added: 876, y_added: 0, x_checked: 111850, y_checked: 3533499878 },
                AmmSimulationStepData { x_added: 905, y_added: 0, x_checked: 112754, y_checked: 3505263469 },
                AmmSimulationStepData { x_added: 910, y_added: 0, x_checked: 113663, y_checked: 3477322517 },
                AmmSimulationStepData { x_added: 0, y_added: 28458043, x_checked: 112744, y_checked: 3505766330 },
                AmmSimulationStepData { x_added: 954, y_added: 0, x_checked: 113697, y_checked: 3476472982 },
                AmmSimulationStepData { x_added: 0, y_added: 28950665, x_checked: 112761, y_checked: 3505409171 },
                AmmSimulationStepData { x_added: 1134, y_added: 0, x_checked: 113894, y_checked: 3470629317 },
                AmmSimulationStepData { x_added: 994, y_added: 0, x_checked: 114887, y_checked: 3440721558 },
                AmmSimulationStepData { x_added: 990, y_added: 0, x_checked: 115876, y_checked: 3411443371 },
                AmmSimulationStepData { x_added: 912, y_added: 0, x_checked: 116787, y_checked: 3384919271 },
                AmmSimulationStepData { x_added: 1408, y_added: 0, x_checked: 118194, y_checked: 3344737854 },
                AmmSimulationStepData { x_added: 1051, y_added: 0, x_checked: 119244, y_checked: 3315369260 },
                AmmSimulationStepData { x_added: 1059, y_added: 0, x_checked: 120302, y_checked: 3286294085 },
                AmmSimulationStepData { x_added: 1004, y_added: 0, x_checked: 121305, y_checked: 3259202248 },
                AmmSimulationStepData { x_added: 1678, y_added: 0, x_checked: 122982, y_checked: 3214890010 },
                AmmSimulationStepData { x_added: 1159, y_added: 0, x_checked: 124140, y_checked: 3184977914 },
                AmmSimulationStepData { x_added: 0, y_added: 25709163, x_checked: 123149, y_checked: 3210674222 },
                AmmSimulationStepData { x_added: 960, y_added: 0, x_checked: 124108, y_checked: 3185941903 },
                AmmSimulationStepData { x_added: 1030, y_added: 0, x_checked: 125137, y_checked: 3159819695 },
                AmmSimulationStepData { x_added: 2667, y_added: 0, x_checked: 127802, y_checked: 3094098809 },
                AmmSimulationStepData { x_added: 1089, y_added: 0, x_checked: 128890, y_checked: 3068051984 },
                AmmSimulationStepData { x_added: 0, y_added: 26939743, x_checked: 127772, y_checked: 3094978257 },
                AmmSimulationStepData { x_added: 1374, y_added: 0, x_checked: 129145, y_checked: 3062168962 },
                AmmSimulationStepData { x_added: 1027, y_added: 0, x_checked: 130171, y_checked: 3038103149 },
                AmmSimulationStepData { x_added: 0, y_added: 24713871, x_checked: 129124, y_checked: 3062804663 },
                AmmSimulationStepData { x_added: 1223, y_added: 0, x_checked: 130346, y_checked: 3034183835 },
                AmmSimulationStepData { x_added: 1073, y_added: 0, x_checked: 131418, y_checked: 3009502159 },
                AmmSimulationStepData { x_added: 0, y_added: 27503463, x_checked: 130232, y_checked: 3036991870 },
                AmmSimulationStepData { x_added: 0, y_added: 26560842, x_checked: 129107, y_checked: 3063539431 },
                AmmSimulationStepData { x_added: 984, y_added: 0, x_checked: 130090, y_checked: 3040460502 },
                AmmSimulationStepData { x_added: 2254, y_added: 0, x_checked: 132342, y_checked: 2988857958 },
                AmmSimulationStepData { x_added: 1256, y_added: 0, x_checked: 133597, y_checked: 2960869506 },
                AmmSimulationStepData { x_added: 1195, y_added: 0, x_checked: 134791, y_checked: 2934706973 },
                AmmSimulationStepData { x_added: 1071, y_added: 0, x_checked: 135861, y_checked: 2911658406 },
                AmmSimulationStepData { x_added: 0, y_added: 23788343, x_checked: 134764, y_checked: 2935434854 },
                AmmSimulationStepData { x_added: 0, y_added: 22783351, x_checked: 133730, y_checked: 2958206813 },
                AmmSimulationStepData { x_added: 1016, y_added: 0, x_checked: 134745, y_checked: 2935988758 },
                AmmSimulationStepData { x_added: 1083, y_added: 0, x_checked: 135827, y_checked: 2912664958 },
                AmmSimulationStepData { x_added: 0, y_added: 23529850, x_checked: 134742, y_checked: 2936183043 },
                AmmSimulationStepData { x_added: 1212, y_added: 0, x_checked: 135953, y_checked: 2910114643 },
                AmmSimulationStepData { x_added: 1244, y_added: 0, x_checked: 137196, y_checked: 2883832994 },
                AmmSimulationStepData { x_added: 1087, y_added: 0, x_checked: 138282, y_checked: 2861246838 },
                AmmSimulationStepData { x_added: 0, y_added: 34084283, x_checked: 136659, y_checked: 2895314078 },
                AmmSimulationStepData { x_added: 1573, y_added: 0, x_checked: 138231, y_checked: 2862470622 },
                AmmSimulationStepData { x_added: 1845, y_added: 0, x_checked: 140075, y_checked: 2824888817 },
                AmmSimulationStepData { x_added: 1227, y_added: 0, x_checked: 141301, y_checked: 2800457909 },
                AmmSimulationStepData { x_added: 1130, y_added: 0, x_checked: 142430, y_checked: 2778318037 },
                AmmSimulationStepData { x_added: 1321, y_added: 0, x_checked: 143750, y_checked: 2752882432 },
                AmmSimulationStepData { x_added: 1610, y_added: 0, x_checked: 145359, y_checked: 2722504022 },
                AmmSimulationStepData { x_added: 0, y_added: 22067902, x_checked: 144194, y_checked: 2744560890 },
                AmmSimulationStepData { x_added: 1093, y_added: 0, x_checked: 145286, y_checked: 2723988444 },
                AmmSimulationStepData { x_added: 2382, y_added: 0, x_checked: 147666, y_checked: 2680193588 },
                AmmSimulationStepData { x_added: 1253, y_added: 0, x_checked: 148918, y_checked: 2657731754 },
                AmmSimulationStepData { x_added: 1239, y_added: 0, x_checked: 150156, y_checked: 2635889615 },
                AmmSimulationStepData { x_added: 1212, y_added: 0, x_checked: 151367, y_checked: 2614870484 },
                AmmSimulationStepData { x_added: 1176, y_added: 0, x_checked: 152542, y_checked: 2594779700 },
                AmmSimulationStepData { x_added: 0, y_added: 23211148, x_checked: 151194, y_checked: 2617979242 },
                AmmSimulationStepData { x_added: 2303, y_added: 0, x_checked: 153495, y_checked: 2578834663 },
                AmmSimulationStepData { x_added: 1263, y_added: 0, x_checked: 154757, y_checked: 2557871102 },
                AmmSimulationStepData { x_added: 0, y_added: 21550585, x_checked: 153468, y_checked: 2579410911 },
                AmmSimulationStepData { x_added: 1242, y_added: 0, x_checked: 154709, y_checked: 2558786295 },
                AmmSimulationStepData { x_added: 1691, y_added: 0, x_checked: 156399, y_checked: 2531217751 },
                AmmSimulationStepData { x_added: 0, y_added: 20246349, x_checked: 155162, y_checked: 2551453976 },
                AmmSimulationStepData { x_added: 5954, y_added: 0, x_checked: 161113, y_checked: 2457440204 },
                AmmSimulationStepData { x_added: 1263, y_added: 0, x_checked: 162375, y_checked: 2438400722 },
                AmmSimulationStepData { x_added: 0, y_added: 19961676, x_checked: 161061, y_checked: 2458352417 },
                AmmSimulationStepData { x_added: 2034, y_added: 0, x_checked: 163093, y_checked: 2427812755 },
                AmmSimulationStepData { x_added: 0, y_added: 27782559, x_checked: 161254, y_checked: 2455581422 },
                AmmSimulationStepData { x_added: 1520, y_added: 0, x_checked: 162773, y_checked: 2432725683 },
                AmmSimulationStepData { x_added: 1497, y_added: 0, x_checked: 164269, y_checked: 2410629517 },
                AmmSimulationStepData { x_added: 1739, y_added: 0, x_checked: 166007, y_checked: 2385463429 },
                AmmSimulationStepData { x_added: 0, y_added: 21732903, x_checked: 164513, y_checked: 2407185465 },
                AmmSimulationStepData { x_added: 2928, y_added: 0, x_checked: 167439, y_checked: 2365232857 },
                AmmSimulationStepData { x_added: 1550, y_added: 0, x_checked: 168988, y_checked: 2343607823 },
                AmmSimulationStepData { x_added: 2723, y_added: 0, x_checked: 171709, y_checked: 2306563691 },
                AmmSimulationStepData { x_added: 0, y_added: 19052250, x_checked: 170307, y_checked: 2325606414 },
                AmmSimulationStepData { x_added: 2129, y_added: 0, x_checked: 172434, y_checked: 2296999627 },
                AmmSimulationStepData { x_added: 0, y_added: 22013473, x_checked: 170803, y_checked: 2319002093 },
                AmmSimulationStepData { x_added: 4299, y_added: 0, x_checked: 175099, y_checked: 2262248210 },
                AmmSimulationStepData { x_added: 0, y_added: 21519054, x_checked: 173455, y_checked: 2283756504 },
                AmmSimulationStepData { x_added: 0, y_added: 20033034, x_checked: 171952, y_checked: 2303779521 },
                AmmSimulationStepData { x_added: 1486, y_added: 0, x_checked: 173437, y_checked: 2284106809 },
                AmmSimulationStepData { x_added: 1676, y_added: 0, x_checked: 175112, y_checked: 2262323224 },
                AmmSimulationStepData { x_added: 0, y_added: 17486741, x_checked: 173773, y_checked: 2279801221 },
                AmmSimulationStepData { x_added: 0, y_added: 19187482, x_checked: 172327, y_checked: 2298979109 },
                AmmSimulationStepData { x_added: 0, y_added: 27138998, x_checked: 170323, y_checked: 2326104537 },
                AmmSimulationStepData { x_added: 0, y_added: 32411038, x_checked: 167990, y_checked: 2358499369 },
                AmmSimulationStepData { x_added: 1293, y_added: 0, x_checked: 169282, y_checked: 2340554054 },
                AmmSimulationStepData { x_added: 0, y_added: 17559343, x_checked: 168026, y_checked: 2358104617 },
                AmmSimulationStepData { x_added: 1450, y_added: 0, x_checked: 169475, y_checked: 2337998162 },
                AmmSimulationStepData { x_added: 0, y_added: 20249285, x_checked: 168025, y_checked: 2358237322 },
                AmmSimulationStepData { x_added: 1388, y_added: 0, x_checked: 169412, y_checked: 2338985326 },
                AmmSimulationStepData { x_added: 1908, y_added: 0, x_checked: 171319, y_checked: 2313016929 },
                AmmSimulationStepData { x_added: 0, y_added: 20783396, x_checked: 169798, y_checked: 2333789933 },
                AmmSimulationStepData { x_added: 1483, y_added: 0, x_checked: 171280, y_checked: 2313650851 },
                AmmSimulationStepData { x_added: 0, y_added: 35942427, x_checked: 168668, y_checked: 2349575306 },
                AmmSimulationStepData { x_added: 5931, y_added: 0, x_checked: 174596, y_checked: 2269995978 },
                AmmSimulationStepData { x_added: 2057, y_added: 0, x_checked: 176651, y_checked: 2243665079 },
                AmmSimulationStepData { x_added: 0, y_added: 19543656, x_checked: 175131, y_checked: 2263198963 },
                AmmSimulationStepData { x_added: 3280, y_added: 0, x_checked: 178409, y_checked: 2221728126 },
                AmmSimulationStepData { x_added: 0, y_added: 16959953, x_checked: 177062, y_checked: 2238679599 },
                AmmSimulationStepData { x_added: 0, y_added: 24894153, x_checked: 175121, y_checked: 2263561304 },
                AmmSimulationStepData { x_added: 1493, y_added: 0, x_checked: 176613, y_checked: 2244489914 },
                AmmSimulationStepData { x_added: 1414, y_added: 0, x_checked: 178026, y_checked: 2226725333 },
                AmmSimulationStepData { x_added: 1375, y_added: 0, x_checked: 179400, y_checked: 2209720419 },
                AmmSimulationStepData { x_added: 1817, y_added: 0, x_checked: 181216, y_checked: 2187636751 },
                AmmSimulationStepData { x_added: 0, y_added: 22814697, x_checked: 179352, y_checked: 2210440040 },
                AmmSimulationStepData { x_added: 2110, y_added: 0, x_checked: 181460, y_checked: 2184833854 },
                AmmSimulationStepData { x_added: 1376, y_added: 0, x_checked: 182835, y_checked: 2168450379 },
                AmmSimulationStepData { x_added: 0, y_added: 18163736, x_checked: 181321, y_checked: 2186605033 },
                AmmSimulationStepData { x_added: 1695, y_added: 0, x_checked: 183015, y_checked: 2166424847 },
                AmmSimulationStepData { x_added: 0, y_added: 19967224, x_checked: 181349, y_checked: 2186382087 },
                AmmSimulationStepData { x_added: 0, y_added: 21551334, x_checked: 179585, y_checked: 2207922645 },
                AmmSimulationStepData { x_added: 0, y_added: 28544879, x_checked: 177300, y_checked: 2236453251 },
                AmmSimulationStepData { x_added: 0, y_added: 31796381, x_checked: 174822, y_checked: 2268233733 },
                AmmSimulationStepData { x_added: 0, y_added: 17707057, x_checked: 173472, y_checked: 2285931936 },
                AmmSimulationStepData { x_added: 1493, y_added: 0, x_checked: 174964, y_checked: 2266490540 },
                AmmSimulationStepData { x_added: 1615, y_added: 0, x_checked: 176578, y_checked: 2245837421 },
                AmmSimulationStepData { x_added: 0, y_added: 25521715, x_checked: 174600, y_checked: 2271346375 },
                AmmSimulationStepData { x_added: 0, y_added: 26395050, x_checked: 172601, y_checked: 2297728227 },
                AmmSimulationStepData { x_added: 0, y_added: 17212968, x_checked: 171322, y_checked: 2314932588 },
                AmmSimulationStepData { x_added: 0, y_added: 25455009, x_checked: 169465, y_checked: 2340374869 },
                AmmSimulationStepData { x_added: 1749, y_added: 0, x_checked: 171213, y_checked: 2316548451 },
                AmmSimulationStepData { x_added: 0, y_added: 17550590, x_checked: 169930, y_checked: 2334090265 },
                AmmSimulationStepData { x_added: 1353, y_added: 0, x_checked: 171282, y_checked: 2315720401 },
                AmmSimulationStepData { x_added: 0, y_added: 20637885, x_checked: 169774, y_checked: 2336347967 },
                AmmSimulationStepData { x_added: 1386, y_added: 0, x_checked: 171159, y_checked: 2317496654 },
                AmmSimulationStepData { x_added: 0, y_added: 22992505, x_checked: 169483, y_checked: 2340477662 },
                AmmSimulationStepData { x_added: 1342, y_added: 0, x_checked: 170824, y_checked: 2322158855 },
                AmmSimulationStepData { x_added: 1540, y_added: 0, x_checked: 172363, y_checked: 2301478103 },
                AmmSimulationStepData { x_added: 0, y_added: 18039774, x_checked: 171027, y_checked: 2319508857 },
                AmmSimulationStepData { x_added: 0, y_added: 17619909, x_checked: 169742, y_checked: 2337119956 },
                AmmSimulationStepData { x_added: 1607, y_added: 0, x_checked: 171348, y_checked: 2315282303 },
                AmmSimulationStepData { x_added: 3262, y_added: 0, x_checked: 174608, y_checked: 2272172190 },
                AmmSimulationStepData { x_added: 0, y_added: 23967829, x_checked: 172791, y_checked: 2296128035 },
                AmmSimulationStepData { x_added: 1708, y_added: 0, x_checked: 174498, y_checked: 2273731665 },
                AmmSimulationStepData { x_added: 1323, y_added: 0, x_checked: 175820, y_checked: 2256686696 },
                AmmSimulationStepData { x_added: 1764, y_added: 0, x_checked: 177583, y_checked: 2234345780 },
                AmmSimulationStepData { x_added: 0, y_added: 18052255, x_checked: 176164, y_checked: 2252389008 },
                AmmSimulationStepData { x_added: 0, y_added: 19362440, x_checked: 174667, y_checked: 2271741766 },
                AmmSimulationStepData { x_added: 1374, y_added: 0, x_checked: 176040, y_checked: 2254074843 },
                AmmSimulationStepData { x_added: 0, y_added: 20871669, x_checked: 174430, y_checked: 2274936076 },
                AmmSimulationStepData { x_added: 1464, y_added: 0, x_checked: 175893, y_checked: 2256065472 },
                AmmSimulationStepData { x_added: 0, y_added: 19113184, x_checked: 174420, y_checked: 2275169099 },
                AmmSimulationStepData { x_added: 0, y_added: 24620022, x_checked: 172559, y_checked: 2299776810 },
                AmmSimulationStepData { x_added: 0, y_added: 19684008, x_checked: 171099, y_checked: 2319450975 },
                AmmSimulationStepData { x_added: 0, y_added: 20684630, x_checked: 169592, y_checked: 2340125262 },
                AmmSimulationStepData { x_added: 2682, y_added: 0, x_checked: 172272, y_checked: 2303814028 },
                AmmSimulationStepData { x_added: 1355, y_added: 0, x_checked: 173626, y_checked: 2285900694 },
                AmmSimulationStepData { x_added: 0, y_added: 19589443, x_checked: 172156, y_checked: 2305480342 },
                AmmSimulationStepData { x_added: 0, y_added: 17742912, x_checked: 170846, y_checked: 2323214382 },
                AmmSimulationStepData { x_added: 1338, y_added: 0, x_checked: 172183, y_checked: 2305228189 },
                AmmSimulationStepData { x_added: 0, y_added: 32526000, x_checked: 169795, y_checked: 2337737926 },
                AmmSimulationStepData { x_added: 1635, y_added: 0, x_checked: 171429, y_checked: 2315522979 },
                AmmSimulationStepData { x_added: 0, y_added: 21141361, x_checked: 169883, y_checked: 2336653769 },
                AmmSimulationStepData { x_added: 0, y_added: 18778481, x_checked: 168533, y_checked: 2355422860 },
                AmmSimulationStepData { x_added: 1274, y_added: 0, x_checked: 169806, y_checked: 2337819819 },
                AmmSimulationStepData { x_added: 0, y_added: 26751352, x_checked: 167891, y_checked: 2364557795 },
                AmmSimulationStepData { x_added: 1589, y_added: 0, x_checked: 169479, y_checked: 2342457429 },
                AmmSimulationStepData { x_added: 1629, y_added: 0, x_checked: 171107, y_checked: 2320237886 },
                AmmSimulationStepData { x_added: 0, y_added: 22045592, x_checked: 169502, y_checked: 2342272455 },
                AmmSimulationStepData { x_added: 0, y_added: 19918781, x_checked: 168077, y_checked: 2362181276 },
                AmmSimulationStepData { x_added: 1412, y_added: 0, x_checked: 169488, y_checked: 2342571230 },
                AmmSimulationStepData { x_added: 1730, y_added: 0, x_checked: 171217, y_checked: 2318982973 },
                AmmSimulationStepData { x_added: 0, y_added: 19175436, x_checked: 169818, y_checked: 2338148821 },
                AmmSimulationStepData { x_added: 1543, y_added: 0, x_checked: 171360, y_checked: 2317162846 },
                AmmSimulationStepData { x_added: 1432, y_added: 0, x_checked: 172791, y_checked: 2298026040 },
                AmmSimulationStepData { x_added: 0, y_added: 19964748, x_checked: 171308, y_checked: 2317980805 },
                AmmSimulationStepData { x_added: 1333, y_added: 0, x_checked: 172640, y_checked: 2300149771 },
                AmmSimulationStepData { x_added: 0, y_added: 23463162, x_checked: 170902, y_checked: 2323601201 },
                AmmSimulationStepData { x_added: 0, y_added: 38394441, x_checked: 168133, y_checked: 2361976444 },
                AmmSimulationStepData { x_added: 1658, y_added: 0, x_checked: 169790, y_checked: 2338994526 },
                AmmSimulationStepData { x_added: 0, y_added: 21858982, x_checked: 168223, y_checked: 2360842578 },
                AmmSimulationStepData { x_added: 1488, y_added: 0, x_checked: 169710, y_checked: 2340212020 },
                AmmSimulationStepData { x_added: 0, y_added: 17587658, x_checked: 168448, y_checked: 2357790884 },
                AmmSimulationStepData { x_added: 1451, y_added: 0, x_checked: 169898, y_checked: 2337723280 },
                AmmSimulationStepData { x_added: 1577, y_added: 0, x_checked: 171474, y_checked: 2316291537 },
                AmmSimulationStepData { x_added: 1641, y_added: 0, x_checked: 173114, y_checked: 2294414358 },
                AmmSimulationStepData { x_added: 1838, y_added: 0, x_checked: 174951, y_checked: 2270387704 },
                AmmSimulationStepData { x_added: 0, y_added: 19131050, x_checked: 173494, y_checked: 2289509188 },
                AmmSimulationStepData { x_added: 0, y_added: 23205442, x_checked: 171759, y_checked: 2312703027 },
                AmmSimulationStepData { x_added: 1916, y_added: 0, x_checked: 173674, y_checked: 2287268075 },
                AmmSimulationStepData { x_added: 1376, y_added: 0, x_checked: 175049, y_checked: 2269353570 },
                AmmSimulationStepData { x_added: 0, y_added: 37480472, x_checked: 172214, y_checked: 2306815301 },
                AmmSimulationStepData { x_added: 1313, y_added: 0, x_checked: 173526, y_checked: 2289426645 },
                AmmSimulationStepData { x_added: 1680, y_added: 0, x_checked: 175205, y_checked: 2267551644 },
                AmmSimulationStepData { x_added: 0, y_added: 19760586, x_checked: 173696, y_checked: 2287302349 },
                AmmSimulationStepData { x_added: 1340, y_added: 0, x_checked: 175035, y_checked: 2269856591 },
                AmmSimulationStepData { x_added: 1641, y_added: 0, x_checked: 176675, y_checked: 2248850108 },
                AmmSimulationStepData { x_added: 0, y_added: 22297531, x_checked: 174946, y_checked: 2271136490 },
                AmmSimulationStepData { x_added: 1597, y_added: 0, x_checked: 176542, y_checked: 2250655635 },
                AmmSimulationStepData { x_added: 0, y_added: 19414267, x_checked: 175037, y_checked: 2270060194 },
                AmmSimulationStepData { x_added: 0, y_added: 42129647, x_checked: 171858, y_checked: 2312168776 },
                AmmSimulationStepData { x_added: 1979, y_added: 0, x_checked: 173836, y_checked: 2285925419 },
                AmmSimulationStepData { x_added: 1765, y_added: 0, x_checked: 175600, y_checked: 2263026460 },
                AmmSimulationStepData { x_added: 1813, y_added: 0, x_checked: 177412, y_checked: 2239976137 },
                AmmSimulationStepData { x_added: 0, y_added: 20868950, x_checked: 175780, y_checked: 2260834652 },
                AmmSimulationStepData { x_added: 2604, y_added: 0, x_checked: 178382, y_checked: 2227944024 },
                AmmSimulationStepData { x_added: 1626, y_added: 0, x_checked: 180007, y_checked: 2207892751 },
                AmmSimulationStepData { x_added: 1554, y_added: 0, x_checked: 181560, y_checked: 2189055446 },
                AmmSimulationStepData { x_added: 0, y_added: 21692209, x_checked: 179784, y_checked: 2210736808 },
                AmmSimulationStepData { x_added: 0, y_added: 54951374, x_checked: 175437, y_checked: 2265660706 },
                AmmSimulationStepData { x_added: 1384, y_added: 0, x_checked: 176820, y_checked: 2247990665 },
                AmmSimulationStepData { x_added: 0, y_added: 18834928, x_checked: 175356, y_checked: 2266816175 },
                AmmSimulationStepData { x_added: 1837, y_added: 0, x_checked: 177192, y_checked: 2243391543 },
                AmmSimulationStepData { x_added: 3829, y_added: 0, x_checked: 181019, y_checked: 2196084363 },
                AmmSimulationStepData { x_added: 0, y_added: 19142959, x_checked: 179460, y_checked: 2215217750 },
                AmmSimulationStepData { x_added: 2434, y_added: 0, x_checked: 181892, y_checked: 2185683138 },
                AmmSimulationStepData { x_added: 1785, y_added: 0, x_checked: 183676, y_checked: 2164513056 },
                AmmSimulationStepData { x_added: 1555, y_added: 0, x_checked: 185230, y_checked: 2146400074 },
                AmmSimulationStepData { x_added: 0, y_added: 29011817, x_checked: 182768, y_checked: 2175397385 },
                AmmSimulationStepData { x_added: 0, y_added: 17860694, x_checked: 181285, y_checked: 2193249148 },
                AmmSimulationStepData { x_added: 1783, y_added: 0, x_checked: 183067, y_checked: 2171959073 },
                AmmSimulationStepData { x_added: 3437, y_added: 0, x_checked: 186502, y_checked: 2132058746 },
                AmmSimulationStepData { x_added: 0, y_added: 18198462, x_checked: 184929, y_checked: 2150248108 },
                AmmSimulationStepData { x_added: 0, y_added: 17935585, x_checked: 183404, y_checked: 2168174725 },
                AmmSimulationStepData { x_added: 1695, y_added: 0, x_checked: 185098, y_checked: 2148389822 },
                AmmSimulationStepData { x_added: 0, y_added: 21126445, x_checked: 183301, y_checked: 2169505703 },
                AmmSimulationStepData { x_added: 1683, y_added: 0, x_checked: 184983, y_checked: 2149837089 },
                AmmSimulationStepData { x_added: 3146, y_added: 0, x_checked: 188127, y_checked: 2113998662 },
                AmmSimulationStepData { x_added: 1866, y_added: 0, x_checked: 189992, y_checked: 2093302312 },
                AmmSimulationStepData { x_added: 1518, y_added: 0, x_checked: 191509, y_checked: 2076764016 },
                AmmSimulationStepData { x_added: 0, y_added: 28098673, x_checked: 188961, y_checked: 2104848639 },
                AmmSimulationStepData { x_added: 1688, y_added: 0, x_checked: 190648, y_checked: 2086278037 },
                AmmSimulationStepData { x_added: 0, y_added: 24521022, x_checked: 188440, y_checked: 2110786798 },
                AmmSimulationStepData { x_added: 0, y_added: 18852416, x_checked: 186777, y_checked: 2129629787 },
                AmmSimulationStepData { x_added: 1592, y_added: 0, x_checked: 188368, y_checked: 2111687280 },
                AmmSimulationStepData { x_added: 3446, y_added: 0, x_checked: 191812, y_checked: 2073869072 },
                AmmSimulationStepData { x_added: 2445, y_added: 0, x_checked: 194255, y_checked: 2047861366 },
                AmmSimulationStepData { x_added: 0, y_added: 34758968, x_checked: 191023, y_checked: 2082602954 },
                AmmSimulationStepData { x_added: 0, y_added: 18863278, x_checked: 189314, y_checked: 2101456800 },
                AmmSimulationStepData { x_added: 4136, y_added: 0, x_checked: 193447, y_checked: 2056676072 },
                AmmSimulationStepData { x_added: 0, y_added: 108508222, x_checked: 183781, y_checked: 2165130039 },
                AmmSimulationStepData { x_added: 0, y_added: 16794979, x_checked: 182371, y_checked: 2181916620 },
                AmmSimulationStepData { x_added: 1475, y_added: 0, x_checked: 183845, y_checked: 2164469928 },
                AmmSimulationStepData { x_added: 0, y_added: 19050437, x_checked: 182246, y_checked: 2183510839 },
                AmmSimulationStepData { x_added: 1488, y_added: 0, x_checked: 183733, y_checked: 2165886259 },
                AmmSimulationStepData { x_added: 1641, y_added: 0, x_checked: 185373, y_checked: 2146782509 },
                AmmSimulationStepData { x_added: 1573, y_added: 0, x_checked: 186945, y_checked: 2128776000 },
                AmmSimulationStepData { x_added: 2467, y_added: 0, x_checked: 189410, y_checked: 2101149556 },
                AmmSimulationStepData { x_added: 2058, y_added: 0, x_checked: 191466, y_checked: 2078652134 },
                AmmSimulationStepData { x_added: 0, y_added: 19264111, x_checked: 189714, y_checked: 2097906612 },
                AmmSimulationStepData { x_added: 1840, y_added: 0, x_checked: 191553, y_checked: 2077819946 },
                AmmSimulationStepData { x_added: 0, y_added: 24604457, x_checked: 189318, y_checked: 2102412100 },
                AmmSimulationStepData { x_added: 1437, y_added: 0, x_checked: 190754, y_checked: 2086628855 },
                AmmSimulationStepData { x_added: 0, y_added: 19932521, x_checked: 188955, y_checked: 2106551409 },
                AmmSimulationStepData { x_added: 1838, y_added: 0, x_checked: 190792, y_checked: 2086323605 },
                AmmSimulationStepData { x_added: 0, y_added: 19725833, x_checked: 189011, y_checked: 2106039575 },
                AmmSimulationStepData { x_added: 1441, y_added: 0, x_checked: 190451, y_checked: 2090159710 },
                AmmSimulationStepData { x_added: 1589, y_added: 0, x_checked: 192039, y_checked: 2072919036 },
                AmmSimulationStepData { x_added: 2981, y_added: 0, x_checked: 195018, y_checked: 2041337874 },
                AmmSimulationStepData { x_added: 1675, y_added: 0, x_checked: 196692, y_checked: 2024015973 },
                AmmSimulationStepData { x_added: 0, y_added: 19307299, x_checked: 194839, y_checked: 2043313618 },
                AmmSimulationStepData { x_added: 0, y_added: 17822220, x_checked: 193160, y_checked: 2061126926 },
                AmmSimulationStepData { x_added: 0, y_added: 16806809, x_checked: 191603, y_checked: 2077925331 },
                AmmSimulationStepData { x_added: 0, y_added: 16764051, x_checked: 190075, y_checked: 2094680999 },
                AmmSimulationStepData { x_added: 1752, y_added: 0, x_checked: 191826, y_checked: 2075614719 },
                AmmSimulationStepData { x_added: 0, y_added: 22541421, x_checked: 189772, y_checked: 2098144869 },
                AmmSimulationStepData { x_added: 3489, y_added: 0, x_checked: 193259, y_checked: 2060383690 },
                AmmSimulationStepData { x_added: 1799, y_added: 0, x_checked: 195057, y_checked: 2041443777 },
                AmmSimulationStepData { x_added: 2216, y_added: 0, x_checked: 197271, y_checked: 2018593764 },
                AmmSimulationStepData { x_added: 0, y_added: 20396341, x_checked: 195304, y_checked: 2038979906 },
                AmmSimulationStepData { x_added: 3216, y_added: 0, x_checked: 198518, y_checked: 2006059834 },
                AmmSimulationStepData { x_added: 0, y_added: 33857953, x_checked: 195233, y_checked: 2039900858 },
                AmmSimulationStepData { x_added: 0, y_added: 30550236, x_checked: 192361, y_checked: 2070435818 },
                AmmSimulationStepData { x_added: 1674, y_added: 0, x_checked: 194034, y_checked: 2052637000 },
                AmmSimulationStepData { x_added: 0, y_added: 46369931, x_checked: 189761, y_checked: 2098983746 },
                AmmSimulationStepData { x_added: 0, y_added: 36018338, x_checked: 186570, y_checked: 2134984074 },
                AmmSimulationStepData { x_added: 0, y_added: 20286229, x_checked: 184820, y_checked: 2155260159 },
                AmmSimulationStepData { x_added: 2018, y_added: 0, x_checked: 186836, y_checked: 2132072915 },
                AmmSimulationStepData { x_added: 1763, y_added: 0, x_checked: 188598, y_checked: 2112209760 },
                AmmSimulationStepData { x_added: 0, y_added: 33012091, x_checked: 185705, y_checked: 2145205344 },
                AmmSimulationStepData { x_added: 1652, y_added: 0, x_checked: 187356, y_checked: 2126358325 },
                AmmSimulationStepData { x_added: 0, y_added: 31555881, x_checked: 184625, y_checked: 2157898428 },
                AmmSimulationStepData { x_added: 0, y_added: 17406408, x_checked: 183153, y_checked: 2175296132 },
                AmmSimulationStepData { x_added: 0, y_added: 35044814, x_checked: 180258, y_checked: 2210323423 },
                AmmSimulationStepData { x_added: 0, y_added: 16743352, x_checked: 178907, y_checked: 2227058403 },
                AmmSimulationStepData { x_added: 0, y_added: 17616222, x_checked: 177508, y_checked: 2244665816 },
                AmmSimulationStepData { x_added: 0, y_added: 20392117, x_checked: 175915, y_checked: 2265047736 },
                AmmSimulationStepData { x_added: 1610, y_added: 0, x_checked: 177524, y_checked: 2244581552 },
                AmmSimulationStepData { x_added: 0, y_added: 23612013, x_checked: 175682, y_checked: 2268181758 },
                AmmSimulationStepData { x_added: 0, y_added: 23858916, x_checked: 173859, y_checked: 2292028744 },
                AmmSimulationStepData { x_added: 0, y_added: 18877251, x_checked: 172444, y_checked: 2310896556 },
                AmmSimulationStepData { x_added: 0, y_added: 20421456, x_checked: 170938, y_checked: 2331307801 },
                AmmSimulationStepData { x_added: 1765, y_added: 0, x_checked: 172702, y_checked: 2307562337 },
                AmmSimulationStepData { x_added: 0, y_added: 19017422, x_checked: 171295, y_checked: 2326570250 },
                AmmSimulationStepData { x_added: 0, y_added: 20623766, x_checked: 169795, y_checked: 2347183704 },
                AmmSimulationStepData { x_added: 1570, y_added: 0, x_checked: 171364, y_checked: 2325747299 },
                AmmSimulationStepData { x_added: 2375, y_added: 0, x_checked: 173737, y_checked: 2294060129 },
                AmmSimulationStepData { x_added: 1631, y_added: 0, x_checked: 175367, y_checked: 2272802116 },
                AmmSimulationStepData { x_added: 2085, y_added: 0, x_checked: 177450, y_checked: 2246198737 },
                AmmSimulationStepData { x_added: 1430, y_added: 0, x_checked: 178879, y_checked: 2228304492 },
                AmmSimulationStepData { x_added: 0, y_added: 23737137, x_checked: 177000, y_checked: 2252029760 },
                AmmSimulationStepData { x_added: 0, y_added: 25963192, x_checked: 174989, y_checked: 2277979970 },
                AmmSimulationStepData { x_added: 0, y_added: 21781275, x_checked: 173337, y_checked: 2299750354 },
                AmmSimulationStepData { x_added: 1316, y_added: 0, x_checked: 174652, y_checked: 2282487215 },
                AmmSimulationStepData { x_added: 1482, y_added: 0, x_checked: 176133, y_checked: 2263346508 },
                AmmSimulationStepData { x_added: 0, y_added: 19155709, x_checked: 174660, y_checked: 2282492639 },
                AmmSimulationStepData { x_added: 1999, y_added: 0, x_checked: 176658, y_checked: 2256741547 },
                AmmSimulationStepData { x_added: 0, y_added: 21263130, x_checked: 175014, y_checked: 2277994045 },
                AmmSimulationStepData { x_added: 1664, y_added: 0, x_checked: 176677, y_checked: 2256615932 },
                AmmSimulationStepData { x_added: 0, y_added: 17769281, x_checked: 175301, y_checked: 2274376328 },
                AmmSimulationStepData { x_added: 1368, y_added: 0, x_checked: 176668, y_checked: 2256829036 },
                AmmSimulationStepData { x_added: 1810, y_added: 0, x_checked: 178477, y_checked: 2234016945 },
                AmmSimulationStepData { x_added: 0, y_added: 21657433, x_checked: 176769, y_checked: 2255663549 },
                AmmSimulationStepData { x_added: 1907, y_added: 0, x_checked: 178675, y_checked: 2231663905 },
                AmmSimulationStepData { x_added: 1595, y_added: 0, x_checked: 180269, y_checked: 2211979854 },
                AmmSimulationStepData { x_added: 1398, y_added: 0, x_checked: 181666, y_checked: 2195018201 },
                AmmSimulationStepData { x_added: 0, y_added: 29002094, x_checked: 179305, y_checked: 2224005793 },
                AmmSimulationStepData { x_added: 0, y_added: 17171821, x_checked: 177936, y_checked: 2241169028 },
                AmmSimulationStepData { x_added: 1500, y_added: 0, x_checked: 179435, y_checked: 2222495847 },
                AmmSimulationStepData { x_added: 0, y_added: 19085585, x_checked: 177912, y_checked: 2241571889 },
                AmmSimulationStepData { x_added: 1933, y_added: 0, x_checked: 179844, y_checked: 2217553134 },
                AmmSimulationStepData { x_added: 0, y_added: 17750066, x_checked: 178421, y_checked: 2235294324 },
                AmmSimulationStepData { x_added: 2404, y_added: 0, x_checked: 180823, y_checked: 2205686713 },
                AmmSimulationStepData { x_added: 1679, y_added: 0, x_checked: 182501, y_checked: 2185466468 },
                AmmSimulationStepData { x_added: 7368, y_added: 0, x_checked: 189865, y_checked: 2100912403 },
                AmmSimulationStepData { x_added: 0, y_added: 20950461, x_checked: 187996, y_checked: 2121852388 },
                AmmSimulationStepData { x_added: 2705, y_added: 0, x_checked: 190699, y_checked: 2091853678 },
                AmmSimulationStepData { x_added: 0, y_added: 20258317, x_checked: 188876, y_checked: 2112101865 },
                AmmSimulationStepData { x_added: 0, y_added: 31667205, x_checked: 186095, y_checked: 2143753236 },
                AmmSimulationStepData { x_added: 1511, y_added: 0, x_checked: 187605, y_checked: 2126543881 },
                AmmSimulationStepData { x_added: 0, y_added: 25956408, x_checked: 185350, y_checked: 2152487310 },
                AmmSimulationStepData { x_added: 0, y_added: 17084722, x_checked: 183895, y_checked: 2169563489 },
                AmmSimulationStepData { x_added: 0, y_added: 21838672, x_checked: 182068, y_checked: 2191391241 },
                AmmSimulationStepData { x_added: 0, y_added: 61928468, x_checked: 177079, y_checked: 2253288744 },
                AmmSimulationStepData { x_added: 0, y_added: 30920852, x_checked: 174690, y_checked: 2284194135 },
                AmmSimulationStepData { x_added: 1460, y_added: 0, x_checked: 176149, y_checked: 2265326143 },
                AmmSimulationStepData { x_added: 0, y_added: 17318285, x_checked: 174817, y_checked: 2282635768 },
                AmmSimulationStepData { x_added: 0, y_added: 21382499, x_checked: 173200, y_checked: 2304007575 },
                AmmSimulationStepData { x_added: 1465, y_added: 0, x_checked: 174664, y_checked: 2284748151 },
                AmmSimulationStepData { x_added: 0, y_added: 17165166, x_checked: 173366, y_checked: 2301904734 },
                AmmSimulationStepData { x_added: 0, y_added: 19317152, x_checked: 171928, y_checked: 2321212227 },
                AmmSimulationStepData { x_added: 1653, y_added: 0, x_checked: 173580, y_checked: 2299186956 },
                AmmSimulationStepData { x_added: 0, y_added: 17443407, x_checked: 172277, y_checked: 2316621641 },
                AmmSimulationStepData { x_added: 0, y_added: 20903146, x_checked: 170742, y_checked: 2337514335 },
                AmmSimulationStepData { x_added: 0, y_added: 40959637, x_checked: 167811, y_checked: 2378453492 },
                AmmSimulationStepData { x_added: 1298, y_added: 0, x_checked: 169108, y_checked: 2360267404 },
                AmmSimulationStepData { x_added: 0, y_added: 19174788, x_checked: 167750, y_checked: 2379432604 },
                AmmSimulationStepData { x_added: 0, y_added: 18540750, x_checked: 166457, y_checked: 2397964083 },
                AmmSimulationStepData { x_added: 2528, y_added: 0, x_checked: 168983, y_checked: 2362216572 },
                AmmSimulationStepData { x_added: 2573, y_added: 0, x_checked: 171554, y_checked: 2326910078 },
                AmmSimulationStepData { x_added: 1382, y_added: 0, x_checked: 172935, y_checked: 2308381560 },
                AmmSimulationStepData { x_added: 1344, y_added: 0, x_checked: 174278, y_checked: 2290645565 },
                AmmSimulationStepData { x_added: 0, y_added: 19834341, x_checked: 172787, y_checked: 2310469988 },
                AmmSimulationStepData { x_added: 1304, y_added: 0, x_checked: 174090, y_checked: 2293229656 },
                AmmSimulationStepData { x_added: 0, y_added: 18174679, x_checked: 172726, y_checked: 2311395247 },
                AmmSimulationStepData { x_added: 0, y_added: 17881222, x_checked: 171404, y_checked: 2329267528 },
                AmmSimulationStepData { x_added: 4062, y_added: 0, x_checked: 175463, y_checked: 2275527047 },
                AmmSimulationStepData { x_added: 0, y_added: 27311991, x_checked: 173389, y_checked: 2302825382 },
                AmmSimulationStepData { x_added: 0, y_added: 19359166, x_checked: 171948, y_checked: 2322174868 },
                AmmSimulationStepData { x_added: 1600, y_added: 0, x_checked: 173547, y_checked: 2300832210 },
                AmmSimulationStepData { x_added: 0, y_added: 23720506, x_checked: 171782, y_checked: 2324540855 },
                AmmSimulationStepData { x_added: 1980, y_added: 0, x_checked: 173761, y_checked: 2298132308 },
                AmmSimulationStepData { x_added: 0, y_added: 17446614, x_checked: 172456, y_checked: 2315570198 },
                AmmSimulationStepData { x_added: 0, y_added: 20327680, x_checked: 170960, y_checked: 2335887714 },
                AmmSimulationStepData { x_added: 0, y_added: 20757355, x_checked: 169459, y_checked: 2356634690 },
                AmmSimulationStepData { x_added: 1741, y_added: 0, x_checked: 171199, y_checked: 2332750903 },
                AmmSimulationStepData { x_added: 1586, y_added: 0, x_checked: 172784, y_checked: 2311405382 },
                AmmSimulationStepData { x_added: 0, y_added: 57534408, x_checked: 168600, y_checked: 2368911022 },
                AmmSimulationStepData { x_added: 1364, y_added: 0, x_checked: 169963, y_checked: 2349969101 },
                AmmSimulationStepData { x_added: 0, y_added: 21086048, x_checked: 168456, y_checked: 2371044605 },
                AmmSimulationStepData { x_added: 1463, y_added: 0, x_checked: 169918, y_checked: 2350699119 },
                AmmSimulationStepData { x_added: 1411, y_added: 0, x_checked: 171328, y_checked: 2331407701 },
                AmmSimulationStepData { x_added: 1345, y_added: 0, x_checked: 172672, y_checked: 2313314677 },
                AmmSimulationStepData { x_added: 0, y_added: 18709118, x_checked: 171291, y_checked: 2332014440 },
                AmmSimulationStepData { x_added: 1642, y_added: 0, x_checked: 172932, y_checked: 2309952093 },
                AmmSimulationStepData { x_added: 0, y_added: 22551331, x_checked: 171266, y_checked: 2332492148 },
                AmmSimulationStepData { x_added: 0, y_added: 17749493, x_checked: 169977, y_checked: 2350232766 },
                AmmSimulationStepData { x_added: 1302, y_added: 0, x_checked: 171278, y_checked: 2332435250 },
                AmmSimulationStepData { x_added: 1388, y_added: 0, x_checked: 172665, y_checked: 2313752642 },
                AmmSimulationStepData { x_added: 0, y_added: 17331459, x_checked: 171386, y_checked: 2331075435 },
                AmmSimulationStepData { x_added: 1304, y_added: 0, x_checked: 172689, y_checked: 2313540230 },
                AmmSimulationStepData { x_added: 0, y_added: 39093256, x_checked: 169828, y_checked: 2352613939 },
                AmmSimulationStepData { x_added: 0, y_added: 30266050, x_checked: 167678, y_checked: 2382864855 },
                AmmSimulationStepData { x_added: 0, y_added: 19738307, x_checked: 166305, y_checked: 2402593292 },
                AmmSimulationStepData { x_added: 1409, y_added: 0, x_checked: 167713, y_checked: 2382479637 },
                AmmSimulationStepData { x_added: 0, y_added: 19264317, x_checked: 166372, y_checked: 2401734321 },
                AmmSimulationStepData { x_added: 0, y_added: 32955147, x_checked: 164127, y_checked: 2434672990 },
                AmmSimulationStepData { x_added: 0, y_added: 24782295, x_checked: 162479, y_checked: 2459442893 },
                AmmSimulationStepData { x_added: 0, y_added: 18551949, x_checked: 161267, y_checked: 2477985566 },
                AmmSimulationStepData { x_added: 0, y_added: 21031525, x_checked: 159914, y_checked: 2499006575 },
                AmmSimulationStepData { x_added: 0, y_added: 20147841, x_checked: 158639, y_checked: 2519144342 },
                AmmSimulationStepData { x_added: 0, y_added: 34893771, x_checked: 156479, y_checked: 2554020666 },
                AmmSimulationStepData { x_added: 0, y_added: 20709382, x_checked: 155225, y_checked: 2574719693 },
                AmmSimulationStepData { x_added: 0, y_added: 22801578, x_checked: 153867, y_checked: 2597509870 },
                AmmSimulationStepData { x_added: 0, y_added: 21541806, x_checked: 152606, y_checked: 2619040905 },
                AmmSimulationStepData { x_added: 0, y_added: 19775118, x_checked: 151466, y_checked: 2638806135 },
                AmmSimulationStepData { x_added: 0, y_added: 19843163, x_checked: 150339, y_checked: 2658639376 },
                AmmSimulationStepData { x_added: 1236, y_added: 0, x_checked: 151574, y_checked: 2637046812 },
                AmmSimulationStepData { x_added: 0, y_added: 23538339, x_checked: 150238, y_checked: 2660573381 },
                AmmSimulationStepData { x_added: 2106, y_added: 0, x_checked: 152342, y_checked: 2623931465 },
                AmmSimulationStepData { x_added: 0, y_added: 21651676, x_checked: 151099, y_checked: 2645572315 },
                AmmSimulationStepData { x_added: 1168, y_added: 0, x_checked: 152266, y_checked: 2625347795 },
                AmmSimulationStepData { x_added: 0, y_added: 19687355, x_checked: 151137, y_checked: 2645025306 },
                AmmSimulationStepData { x_added: 1217, y_added: 0, x_checked: 152353, y_checked: 2623983024 },
                AmmSimulationStepData { x_added: 0, y_added: 34984945, x_checked: 150355, y_checked: 2658950476 },
                AmmSimulationStepData { x_added: 0, y_added: 19983252, x_checked: 149237, y_checked: 2678923736 },
                AmmSimulationStepData { x_added: 0, y_added: 20295950, x_checked: 148119, y_checked: 2699209538 },
                AmmSimulationStepData { x_added: 0, y_added: 23311118, x_checked: 146855, y_checked: 2722509000 },
                AmmSimulationStepData { x_added: 1277, y_added: 0, x_checked: 148131, y_checked: 2699130201 },
                AmmSimulationStepData { x_added: 0, y_added: 21991509, x_checked: 146938, y_checked: 2721110714 },
                AmmSimulationStepData { x_added: 0, y_added: 20799920, x_checked: 145827, y_checked: 2741900234 },
                AmmSimulationStepData { x_added: 0, y_added: 22374025, x_checked: 144651, y_checked: 2764263071 },
                AmmSimulationStepData { x_added: 0, y_added: 20842482, x_checked: 143572, y_checked: 2785095131 },
                AmmSimulationStepData { x_added: 0, y_added: 23313395, x_checked: 142384, y_checked: 2808396869 },
                AmmSimulationStepData { x_added: 0, y_added: 23485035, x_checked: 141207, y_checked: 2831870161 },
                AmmSimulationStepData { x_added: 0, y_added: 38101063, x_checked: 139338, y_checked: 2869952173 },
                AmmSimulationStepData { x_added: 0, y_added: 22557697, x_checked: 138255, y_checked: 2892498591 },
                AmmSimulationStepData { x_added: 0, y_added: 31918329, x_checked: 136751, y_checked: 2924400960 },
                AmmSimulationStepData { x_added: 0, y_added: 26872612, x_checked: 135510, y_checked: 2951260135 },
                AmmSimulationStepData { x_added: 0, y_added: 22716062, x_checked: 134479, y_checked: 2973964838 },
                AmmSimulationStepData { x_added: 0, y_added: 23136066, x_checked: 133444, y_checked: 2997089335 },
                AmmSimulationStepData { x_added: 1042, y_added: 0, x_checked: 134485, y_checked: 2973956286 },
                AmmSimulationStepData { x_added: 1043, y_added: 0, x_checked: 135527, y_checked: 2951156335 },
                AmmSimulationStepData { x_added: 0, y_added: 28395035, x_checked: 134240, y_checked: 2979537172 },
                AmmSimulationStepData { x_added: 1146, y_added: 0, x_checked: 135385, y_checked: 2954403614 },
                AmmSimulationStepData { x_added: 0, y_added: 22276033, x_checked: 134375, y_checked: 2976668508 },
                AmmSimulationStepData { x_added: 0, y_added: 35216794, x_checked: 132809, y_checked: 3011867693 },
                AmmSimulationStepData { x_added: 0, y_added: 30134457, x_checked: 131498, y_checked: 3041987082 },
                AmmSimulationStepData { x_added: 1183, y_added: 0, x_checked: 132680, y_checked: 3014955248 },
                AmmSimulationStepData { x_added: 1106, y_added: 0, x_checked: 133785, y_checked: 2990120213 },
                AmmSimulationStepData { x_added: 0, y_added: 36132034, x_checked: 132193, y_checked: 3026234180 },
                AmmSimulationStepData { x_added: 0, y_added: 28233272, x_checked: 130975, y_checked: 3054453335 },
                AmmSimulationStepData { x_added: 0, y_added: 27100102, x_checked: 129827, y_checked: 3081539886 },
                AmmSimulationStepData { x_added: 1036, y_added: 0, x_checked: 130862, y_checked: 3057237781 },
                AmmSimulationStepData { x_added: 0, y_added: 32822124, x_checked: 129477, y_checked: 3090043493 },
                AmmSimulationStepData { x_added: 987, y_added: 0, x_checked: 130463, y_checked: 3066760397 },
                AmmSimulationStepData { x_added: 1237, y_added: 0, x_checked: 131699, y_checked: 3038071011 },
                AmmSimulationStepData { x_added: 0, y_added: 35922267, x_checked: 130165, y_checked: 3073975316 },
                AmmSimulationStepData { x_added: 0, y_added: 23931722, x_checked: 129163, y_checked: 3097895072 },
                AmmSimulationStepData { x_added: 1114, y_added: 0, x_checked: 130276, y_checked: 3071499246 },
                AmmSimulationStepData { x_added: 0, y_added: 24666084, x_checked: 129242, y_checked: 3096152996 },
            ]
        };
        test_utils_amm_simulate(admin, &s);
    }

    fun test_amm_simulate_10000_impl(admin: &signer) acquires AptoswapCap, LSPCapabilities, Pool {
        let s = AmmSimulationData {
            x_init: 100000,
            y_init: 1048100000,
            data: vector [
                AmmSimulationStepData { x_added: 0, y_added: 8164146, x_checked: 99230, y_checked: 1056260063 },
                AmmSimulationStepData { x_added: 0, y_added: 8828381, x_checked: 98410, y_checked: 1065084029 },
                AmmSimulationStepData { x_added: 0, y_added: 8804583, x_checked: 97606, y_checked: 1073884209 },
                AmmSimulationStepData { x_added: 942, y_added: 0, x_checked: 98547, y_checked: 1063662345 },
                AmmSimulationStepData { x_added: 0, y_added: 8934684, x_checked: 97729, y_checked: 1072592561 },
                AmmSimulationStepData { x_added: 840, y_added: 0, x_checked: 98568, y_checked: 1063495140 },
                AmmSimulationStepData { x_added: 791, y_added: 0, x_checked: 99358, y_checked: 1055060480 },
                AmmSimulationStepData { x_added: 0, y_added: 14967118, x_checked: 97973, y_checked: 1070020114 },
                AmmSimulationStepData { x_added: 802, y_added: 0, x_checked: 98774, y_checked: 1061375107 },
                AmmSimulationStepData { x_added: 0, y_added: 12175887, x_checked: 97658, y_checked: 1073544906 },
                AmmSimulationStepData { x_added: 809, y_added: 0, x_checked: 98466, y_checked: 1064767968 },
                AmmSimulationStepData { x_added: 752, y_added: 0, x_checked: 99217, y_checked: 1056729756 },
                AmmSimulationStepData { x_added: 0, y_added: 9657535, x_checked: 98322, y_checked: 1066382462 },
                AmmSimulationStepData { x_added: 0, y_added: 10168595, x_checked: 97397, y_checked: 1076545972 },
                AmmSimulationStepData { x_added: 0, y_added: 15274709, x_checked: 96039, y_checked: 1091813043 },
                AmmSimulationStepData { x_added: 0, y_added: 8288210, x_checked: 95318, y_checked: 1100097108 },
                AmmSimulationStepData { x_added: 750, y_added: 0, x_checked: 96067, y_checked: 1091542770 },
                AmmSimulationStepData { x_added: 979, y_added: 0, x_checked: 97045, y_checked: 1080575826 },
                AmmSimulationStepData { x_added: 0, y_added: 8093931, x_checked: 96326, y_checked: 1088665710 },
                AmmSimulationStepData { x_added: 0, y_added: 9860943, x_checked: 95464, y_checked: 1098521722 },
                AmmSimulationStepData { x_added: 0, y_added: 10819265, x_checked: 94536, y_checked: 1109335577 },
                AmmSimulationStepData { x_added: 0, y_added: 8845925, x_checked: 93791, y_checked: 1118177079 },
                AmmSimulationStepData { x_added: 716, y_added: 0, x_checked: 94506, y_checked: 1109740820 },
                AmmSimulationStepData { x_added: 919, y_added: 0, x_checked: 95424, y_checked: 1099099422 },
                AmmSimulationStepData { x_added: 0, y_added: 9119430, x_checked: 94642, y_checked: 1108214292 },
                AmmSimulationStepData { x_added: 752, y_added: 0, x_checked: 95393, y_checked: 1099512712 },
                AmmSimulationStepData { x_added: 0, y_added: 8403900, x_checked: 94672, y_checked: 1107912410 },
                AmmSimulationStepData { x_added: 0, y_added: 12413659, x_checked: 93627, y_checked: 1120319862 },
                AmmSimulationStepData { x_added: 0, y_added: 8957281, x_checked: 92887, y_checked: 1129272664 },
                AmmSimulationStepData { x_added: 0, y_added: 9194423, x_checked: 92140, y_checked: 1138462489 },
                AmmSimulationStepData { x_added: 825, y_added: 0, x_checked: 92964, y_checked: 1128407975 },
                AmmSimulationStepData { x_added: 0, y_added: 11566219, x_checked: 92024, y_checked: 1139968410 },
                AmmSimulationStepData { x_added: 0, y_added: 9165325, x_checked: 91293, y_checked: 1149129152 },
                AmmSimulationStepData { x_added: 0, y_added: 9630216, x_checked: 90537, y_checked: 1158754552 },
                AmmSimulationStepData { x_added: 0, y_added: 10583385, x_checked: 89721, y_checked: 1169332645 },
                AmmSimulationStepData { x_added: 0, y_added: 20545887, x_checked: 88177, y_checked: 1189868259 },
                AmmSimulationStepData { x_added: 664, y_added: 0, x_checked: 88840, y_checked: 1181015033 },
                AmmSimulationStepData { x_added: 0, y_added: 9238851, x_checked: 88153, y_checked: 1190249264 },
                AmmSimulationStepData { x_added: 0, y_added: 9870283, x_checked: 87431, y_checked: 1200114611 },
                AmmSimulationStepData { x_added: 780, y_added: 0, x_checked: 88210, y_checked: 1189543132 },
                AmmSimulationStepData { x_added: 957, y_added: 0, x_checked: 89166, y_checked: 1176828951 },
                AmmSimulationStepData { x_added: 0, y_added: 9421090, x_checked: 88460, y_checked: 1186245330 },
                AmmSimulationStepData { x_added: 2638, y_added: 0, x_checked: 91096, y_checked: 1152008057 },
                AmmSimulationStepData { x_added: 0, y_added: 9035534, x_checked: 90390, y_checked: 1161039073 },
                AmmSimulationStepData { x_added: 821, y_added: 0, x_checked: 91210, y_checked: 1150638897 },
                AmmSimulationStepData { x_added: 0, y_added: 14587994, x_checked: 90072, y_checked: 1165219597 },
                AmmSimulationStepData { x_added: 0, y_added: 9476871, x_checked: 89348, y_checked: 1174691729 },
                AmmSimulationStepData { x_added: 0, y_added: 9205413, x_checked: 88656, y_checked: 1183892539 },
                AmmSimulationStepData { x_added: 747, y_added: 0, x_checked: 89402, y_checked: 1174040011 },
                AmmSimulationStepData { x_added: 704, y_added: 0, x_checked: 90105, y_checked: 1164905998 },
                AmmSimulationStepData { x_added: 0, y_added: 10427406, x_checked: 89308, y_checked: 1175328190 },
                AmmSimulationStepData { x_added: 0, y_added: 11768793, x_checked: 88426, y_checked: 1187091098 },
                AmmSimulationStepData { x_added: 0, y_added: 9121919, x_checked: 87754, y_checked: 1196208456 },
                AmmSimulationStepData { x_added: 0, y_added: 9911237, x_checked: 87036, y_checked: 1206114737 },
                AmmSimulationStepData { x_added: 0, y_added: 9579636, x_checked: 86353, y_checked: 1215689583 },
                AmmSimulationStepData { x_added: 686, y_added: 0, x_checked: 87038, y_checked: 1206149669 },
                AmmSimulationStepData { x_added: 0, y_added: 13671048, x_checked: 86066, y_checked: 1219813881 },
                AmmSimulationStepData { x_added: 1445, y_added: 0, x_checked: 87510, y_checked: 1199740607 },
                AmmSimulationStepData { x_added: 0, y_added: 9831220, x_checked: 86801, y_checked: 1209566911 },
                AmmSimulationStepData { x_added: 0, y_added: 11613322, x_checked: 85978, y_checked: 1221174426 },
                AmmSimulationStepData { x_added: 734, y_added: 0, x_checked: 86711, y_checked: 1210879319 },
                AmmSimulationStepData { x_added: 0, y_added: 10504140, x_checked: 85968, y_checked: 1221378206 },
                AmmSimulationStepData { x_added: 737, y_added: 0, x_checked: 86704, y_checked: 1211038288 },
                AmmSimulationStepData { x_added: 0, y_added: 11493340, x_checked: 85892, y_checked: 1222525881 },
                AmmSimulationStepData { x_added: 0, y_added: 11971225, x_checked: 85062, y_checked: 1234491120 },
                AmmSimulationStepData { x_added: 0, y_added: 9664631, x_checked: 84404, y_checked: 1244150918 },
                AmmSimulationStepData { x_added: 0, y_added: 14391711, x_checked: 83442, y_checked: 1258535433 },
                AmmSimulationStepData { x_added: 0, y_added: 13460001, x_checked: 82562, y_checked: 1271988703 },
                AmmSimulationStepData { x_added: 0, y_added: 9593973, x_checked: 81946, y_checked: 1281577879 },
                AmmSimulationStepData { x_added: 0, y_added: 18020751, x_checked: 80814, y_checked: 1299589619 },
                AmmSimulationStepData { x_added: 0, y_added: 10257353, x_checked: 80184, y_checked: 1309841843 },
                AmmSimulationStepData { x_added: 0, y_added: 9911423, x_checked: 79584, y_checked: 1319748310 },
                AmmSimulationStepData { x_added: 936, y_added: 0, x_checked: 80519, y_checked: 1304471776 },
                AmmSimulationStepData { x_added: 0, y_added: 10527260, x_checked: 79877, y_checked: 1314993772 },
                AmmSimulationStepData { x_added: 0, y_added: 10348248, x_checked: 79256, y_checked: 1325336845 },
                AmmSimulationStepData { x_added: 0, y_added: 11055596, x_checked: 78603, y_checked: 1336386913 },
                AmmSimulationStepData { x_added: 0, y_added: 10460592, x_checked: 77995, y_checked: 1346842274 },
                AmmSimulationStepData { x_added: 0, y_added: 10107280, x_checked: 77416, y_checked: 1356944500 },
                AmmSimulationStepData { x_added: 690, y_added: 0, x_checked: 78105, y_checked: 1345008712 },
                AmmSimulationStepData { x_added: 0, y_added: 15062097, x_checked: 77243, y_checked: 1360063277 },
                AmmSimulationStepData { x_added: 0, y_added: 10562522, x_checked: 76650, y_checked: 1370620517 },
                AmmSimulationStepData { x_added: 0, y_added: 14454381, x_checked: 75853, y_checked: 1385067670 },
                AmmSimulationStepData { x_added: 645, y_added: 0, x_checked: 76497, y_checked: 1373443206 },
                AmmSimulationStepData { x_added: 0, y_added: 10464116, x_checked: 75921, y_checked: 1383902089 },
                AmmSimulationStepData { x_added: 0, y_added: 12101851, x_checked: 75265, y_checked: 1395997889 },
                AmmSimulationStepData { x_added: 791, y_added: 0, x_checked: 76055, y_checked: 1381533682 },
                AmmSimulationStepData { x_added: 0, y_added: 10996604, x_checked: 75457, y_checked: 1392524787 },
                AmmSimulationStepData { x_added: 585, y_added: 0, x_checked: 76041, y_checked: 1381866449 },
                AmmSimulationStepData { x_added: 0, y_added: 11043441, x_checked: 75440, y_checked: 1392904368 },
                AmmSimulationStepData { x_added: 0, y_added: 13106870, x_checked: 74739, y_checked: 1406004684 },
                AmmSimulationStepData { x_added: 595, y_added: 0, x_checked: 75333, y_checked: 1394955385 },
                AmmSimulationStepData { x_added: 0, y_added: 14977432, x_checked: 74536, y_checked: 1409925328 },
                AmmSimulationStepData { x_added: 0, y_added: 10645398, x_checked: 73980, y_checked: 1420565403 },
                AmmSimulationStepData { x_added: 0, y_added: 11505580, x_checked: 73388, y_checked: 1432065230 },
                AmmSimulationStepData { x_added: 0, y_added: 11706379, x_checked: 72795, y_checked: 1443765755 },
                AmmSimulationStepData { x_added: 0, y_added: 12585092, x_checked: 72168, y_checked: 1456344554 },
                AmmSimulationStepData { x_added: 0, y_added: 17480706, x_checked: 71315, y_checked: 1473816519 },
                AmmSimulationStepData { x_added: 0, y_added: 11400429, x_checked: 70770, y_checked: 1485211247 },
                AmmSimulationStepData { x_added: 0, y_added: 11260490, x_checked: 70240, y_checked: 1496466106 },
                AmmSimulationStepData { x_added: 0, y_added: 11701226, x_checked: 69697, y_checked: 1508161481 },
                AmmSimulationStepData { x_added: 0, y_added: 11365167, x_checked: 69178, y_checked: 1519520965 },
                AmmSimulationStepData { x_added: 0, y_added: 14440103, x_checked: 68529, y_checked: 1533953847 },
                AmmSimulationStepData { x_added: 942, y_added: 0, x_checked: 69470, y_checked: 1513241154 },
                AmmSimulationStepData { x_added: 0, y_added: 11723470, x_checked: 68938, y_checked: 1524958762 },
                AmmSimulationStepData { x_added: 660, y_added: 0, x_checked: 69597, y_checked: 1510562643 },
                AmmSimulationStepData { x_added: 0, y_added: 11574798, x_checked: 69070, y_checked: 1522131653 },
                AmmSimulationStepData { x_added: 0, y_added: 11849878, x_checked: 68539, y_checked: 1533975606 },
                AmmSimulationStepData { x_added: 0, y_added: 11764437, x_checked: 68019, y_checked: 1545734160 },
                AmmSimulationStepData { x_added: 570, y_added: 0, x_checked: 68588, y_checked: 1532955587 },
                AmmSimulationStepData { x_added: 0, y_added: 15844435, x_checked: 67889, y_checked: 1548792099 },
                AmmSimulationStepData { x_added: 546, y_added: 0, x_checked: 68434, y_checked: 1536502613 },
                AmmSimulationStepData { x_added: 0, y_added: 17199789, x_checked: 67679, y_checked: 1553693802 },
                AmmSimulationStepData { x_added: 0, y_added: 15120685, x_checked: 67029, y_checked: 1568806926 },
                AmmSimulationStepData { x_added: 0, y_added: 13774796, x_checked: 66448, y_checked: 1582574834 },
                AmmSimulationStepData { x_added: 0, y_added: 11941972, x_checked: 65952, y_checked: 1594510835 },
                AmmSimulationStepData { x_added: 0, y_added: 12070229, x_checked: 65458, y_checked: 1606575028 },
                AmmSimulationStepData { x_added: 0, y_added: 12434243, x_checked: 64957, y_checked: 1619003053 },
                AmmSimulationStepData { x_added: 0, y_added: 12634151, x_checked: 64456, y_checked: 1631630886 },
                AmmSimulationStepData { x_added: 0, y_added: 12541744, x_checked: 63966, y_checked: 1644166359 },
                AmmSimulationStepData { x_added: 492, y_added: 0, x_checked: 64457, y_checked: 1631692582 },
                AmmSimulationStepData { x_added: 0, y_added: 12619868, x_checked: 63964, y_checked: 1644306140 },
                AmmSimulationStepData { x_added: 0, y_added: 13459354, x_checked: 63447, y_checked: 1657758764 },
                AmmSimulationStepData { x_added: 0, y_added: 13110360, x_checked: 62951, y_checked: 1670862568 },
                AmmSimulationStepData { x_added: 0, y_added: 13158554, x_checked: 62461, y_checked: 1684014542 },
                AmmSimulationStepData { x_added: 0, y_added: 13275437, x_checked: 61974, y_checked: 1697283341 },
                AmmSimulationStepData { x_added: 0, y_added: 14828748, x_checked: 61439, y_checked: 1712104674 },
                AmmSimulationStepData { x_added: 0, y_added: 12941702, x_checked: 60980, y_checked: 1725039905 },
                AmmSimulationStepData { x_added: 0, y_added: 26350456, x_checked: 60066, y_checked: 1751377185 },
                AmmSimulationStepData { x_added: 0, y_added: 13393027, x_checked: 59612, y_checked: 1764763515 },
                AmmSimulationStepData { x_added: 561, y_added: 0, x_checked: 60172, y_checked: 1748397585 },
                AmmSimulationStepData { x_added: 0, y_added: 13257675, x_checked: 59721, y_checked: 1761648631 },
                AmmSimulationStepData { x_added: 0, y_added: 14449898, x_checked: 59237, y_checked: 1776091304 },
                AmmSimulationStepData { x_added: 452, y_added: 0, x_checked: 59688, y_checked: 1762730299 },
                AmmSimulationStepData { x_added: 0, y_added: 13661469, x_checked: 59231, y_checked: 1776384937 },
                AmmSimulationStepData { x_added: 0, y_added: 13720018, x_checked: 58779, y_checked: 1790098094 },
                AmmSimulationStepData { x_added: 0, y_added: 21503202, x_checked: 58084, y_checked: 1811590544 },
                AmmSimulationStepData { x_added: 0, y_added: 14206840, x_checked: 57634, y_checked: 1825790280 },
                AmmSimulationStepData { x_added: 464, y_added: 0, x_checked: 58097, y_checked: 1811302126 },
                AmmSimulationStepData { x_added: 0, y_added: 16540766, x_checked: 57573, y_checked: 1827834621 },
                AmmSimulationStepData { x_added: 0, y_added: 15172091, x_checked: 57101, y_checked: 1842999125 },
                AmmSimulationStepData { x_added: 494, y_added: 0, x_checked: 57594, y_checked: 1827286656 },
                AmmSimulationStepData { x_added: 574, y_added: 0, x_checked: 58167, y_checked: 1809348366 },
                AmmSimulationStepData { x_added: 0, y_added: 13588758, x_checked: 57735, y_checked: 1822930329 },
                AmmSimulationStepData { x_added: 0, y_added: 16779162, x_checked: 57210, y_checked: 1839701101 },
                AmmSimulationStepData { x_added: 0, y_added: 14451602, x_checked: 56766, y_checked: 1854145477 },
                AmmSimulationStepData { x_added: 0, y_added: 15749050, x_checked: 56290, y_checked: 1869886652 },
                AmmSimulationStepData { x_added: 477, y_added: 0, x_checked: 56766, y_checked: 1854272420 },
                AmmSimulationStepData { x_added: 0, y_added: 14644608, x_checked: 56323, y_checked: 1868909705 },
                AmmSimulationStepData { x_added: 0, y_added: 20814416, x_checked: 55705, y_checked: 1889713713 },
                AmmSimulationStepData { x_added: 0, y_added: 15509102, x_checked: 55253, y_checked: 1905215060 },
                AmmSimulationStepData { x_added: 0, y_added: 14426185, x_checked: 54840, y_checked: 1919634031 },
                AmmSimulationStepData { x_added: 0, y_added: 19142273, x_checked: 54301, y_checked: 1938766732 },
                AmmSimulationStepData { x_added: 0, y_added: 15823636, x_checked: 53863, y_checked: 1954582456 },
                AmmSimulationStepData { x_added: 0, y_added: 15942817, x_checked: 53429, y_checked: 1970517301 },
                AmmSimulationStepData { x_added: 483, y_added: 0, x_checked: 53911, y_checked: 1952972025 },
                AmmSimulationStepData { x_added: 419, y_added: 0, x_checked: 54329, y_checked: 1938017466 },
                AmmSimulationStepData { x_added: 0, y_added: 31240141, x_checked: 53470, y_checked: 1969241986 },
                AmmSimulationStepData { x_added: 0, y_added: 20336301, x_checked: 52926, y_checked: 1989568118 },
                AmmSimulationStepData { x_added: 450, y_added: 0, x_checked: 53375, y_checked: 1972905444 },
                AmmSimulationStepData { x_added: 603, y_added: 0, x_checked: 53977, y_checked: 1950974120 },
                AmmSimulationStepData { x_added: 0, y_added: 16035296, x_checked: 53539, y_checked: 1967001398 },
                AmmSimulationStepData { x_added: 0, y_added: 15856674, x_checked: 53113, y_checked: 1982850143 },
                AmmSimulationStepData { x_added: 0, y_added: 15075677, x_checked: 52714, y_checked: 1997918282 },
                AmmSimulationStepData { x_added: 404, y_added: 0, x_checked: 53117, y_checked: 1982834686 },
                AmmSimulationStepData { x_added: 0, y_added: 17976578, x_checked: 52642, y_checked: 2000802275 },
                AmmSimulationStepData { x_added: 0, y_added: 16126140, x_checked: 52223, y_checked: 2016920351 },
                AmmSimulationStepData { x_added: 444, y_added: 0, x_checked: 52666, y_checked: 2000030980 },
                AmmSimulationStepData { x_added: 0, y_added: 17410429, x_checked: 52213, y_checked: 2017432703 },
                AmmSimulationStepData { x_added: 0, y_added: 17845877, x_checked: 51757, y_checked: 2035269657 },
                AmmSimulationStepData { x_added: 0, y_added: 15466327, x_checked: 51368, y_checked: 2050728250 },
                AmmSimulationStepData { x_added: 447, y_added: 0, x_checked: 51814, y_checked: 2033154651 },
                AmmSimulationStepData { x_added: 406, y_added: 0, x_checked: 52219, y_checked: 2017463185 },
                AmmSimulationStepData { x_added: 0, y_added: 15383887, x_checked: 51826, y_checked: 2032839380 },
                AmmSimulationStepData { x_added: 421, y_added: 0, x_checked: 52246, y_checked: 2016574798 },
                AmmSimulationStepData { x_added: 430, y_added: 0, x_checked: 52675, y_checked: 2000227193 },
                AmmSimulationStepData { x_added: 0, y_added: 18294618, x_checked: 52200, y_checked: 2018512663 },
                AmmSimulationStepData { x_added: 632, y_added: 0, x_checked: 52831, y_checked: 1994479567 },
                AmmSimulationStepData { x_added: 427, y_added: 0, x_checked: 53257, y_checked: 1978600132 },
                AmmSimulationStepData { x_added: 434, y_added: 0, x_checked: 53690, y_checked: 1962716198 },
                AmmSimulationStepData { x_added: 524, y_added: 0, x_checked: 54213, y_checked: 1943853327 },
                AmmSimulationStepData { x_added: 514, y_added: 0, x_checked: 54726, y_checked: 1925702077 },
                AmmSimulationStepData { x_added: 417, y_added: 0, x_checked: 55142, y_checked: 1911243596 },
                AmmSimulationStepData { x_added: 417, y_added: 0, x_checked: 55558, y_checked: 1897001123 },
                AmmSimulationStepData { x_added: 443, y_added: 0, x_checked: 56000, y_checked: 1882095582 },
                AmmSimulationStepData { x_added: 0, y_added: 16509989, x_checked: 55515, y_checked: 1898597316 },
                AmmSimulationStepData { x_added: 0, y_added: 27407870, x_checked: 54728, y_checked: 1925991482 },
                AmmSimulationStepData { x_added: 458, y_added: 0, x_checked: 55185, y_checked: 1910111119 },
                AmmSimulationStepData { x_added: 419, y_added: 0, x_checked: 55603, y_checked: 1895819898 },
                AmmSimulationStepData { x_added: 432, y_added: 0, x_checked: 56034, y_checked: 1881304858 },
                AmmSimulationStepData { x_added: 532, y_added: 0, x_checked: 56565, y_checked: 1863710136 },
                AmmSimulationStepData { x_added: 501, y_added: 0, x_checked: 57065, y_checked: 1847445172 },
                AmmSimulationStepData { x_added: 440, y_added: 0, x_checked: 57504, y_checked: 1833405078 },
                AmmSimulationStepData { x_added: 0, y_added: 14792086, x_checked: 57046, y_checked: 1848189767 },
                AmmSimulationStepData { x_added: 0, y_added: 15011358, x_checked: 56588, y_checked: 1863193619 },
                AmmSimulationStepData { x_added: 567, y_added: 0, x_checked: 57154, y_checked: 1844806840 },
                AmmSimulationStepData { x_added: 441, y_added: 0, x_checked: 57594, y_checked: 1830776673 },
                AmmSimulationStepData { x_added: 0, y_added: 18618006, x_checked: 57016, y_checked: 1849385369 },
                AmmSimulationStepData { x_added: 470, y_added: 0, x_checked: 57485, y_checked: 1834360702 },
                AmmSimulationStepData { x_added: 470, y_added: 0, x_checked: 57954, y_checked: 1819578703 },
                AmmSimulationStepData { x_added: 465, y_added: 0, x_checked: 58418, y_checked: 1805188034 },
                AmmSimulationStepData { x_added: 0, y_added: 13747324, x_checked: 57978, y_checked: 1818928484 },
                AmmSimulationStepData { x_added: 448, y_added: 0, x_checked: 58425, y_checked: 1805073955 },
                AmmSimulationStepData { x_added: 481, y_added: 0, x_checked: 58905, y_checked: 1790425714 },
                AmmSimulationStepData { x_added: 0, y_added: 13717247, x_checked: 58459, y_checked: 1804136102 },
                AmmSimulationStepData { x_added: 0, y_added: 13802959, x_checked: 58017, y_checked: 1817932159 },
                AmmSimulationStepData { x_added: 0, y_added: 14966706, x_checked: 57545, y_checked: 1832891381 },
                AmmSimulationStepData { x_added: 490, y_added: 0, x_checked: 58034, y_checked: 1817509901 },
                AmmSimulationStepData { x_added: 853, y_added: 0, x_checked: 58886, y_checked: 1791304275 },
                AmmSimulationStepData { x_added: 503, y_added: 0, x_checked: 59388, y_checked: 1776222402 },
                AmmSimulationStepData { x_added: 483, y_added: 0, x_checked: 59870, y_checked: 1761981293 },
                AmmSimulationStepData { x_added: 467, y_added: 0, x_checked: 60336, y_checked: 1748430736 },
                AmmSimulationStepData { x_added: 0, y_added: 15755204, x_checked: 59799, y_checked: 1764178062 },
                AmmSimulationStepData { x_added: 464, y_added: 0, x_checked: 60262, y_checked: 1750681778 },
                AmmSimulationStepData { x_added: 474, y_added: 0, x_checked: 60735, y_checked: 1737104792 },
                AmmSimulationStepData { x_added: 0, y_added: 13392236, x_checked: 60272, y_checked: 1750490331 },
                AmmSimulationStepData { x_added: 500, y_added: 0, x_checked: 60771, y_checked: 1736173925 },
                AmmSimulationStepData { x_added: 528, y_added: 0, x_checked: 61298, y_checked: 1721303603 },
                AmmSimulationStepData { x_added: 0, y_added: 13619754, x_checked: 60819, y_checked: 1734916547 },
                AmmSimulationStepData { x_added: 0, y_added: 15200084, x_checked: 60293, y_checked: 1750109030 },
                AmmSimulationStepData { x_added: 470, y_added: 0, x_checked: 60762, y_checked: 1736657732 },
                AmmSimulationStepData { x_added: 0, y_added: 13398959, x_checked: 60299, y_checked: 1750049991 },
                AmmSimulationStepData { x_added: 0, y_added: 16595656, x_checked: 59735, y_checked: 1766637349 },
                AmmSimulationStepData { x_added: 0, y_added: 14262412, x_checked: 59259, y_checked: 1780892629 },
                AmmSimulationStepData { x_added: 525, y_added: 0, x_checked: 59783, y_checked: 1765342104 },
                AmmSimulationStepData { x_added: 450, y_added: 0, x_checked: 60232, y_checked: 1752240529 },
                AmmSimulationStepData { x_added: 0, y_added: 14651651, x_checked: 59735, y_checked: 1766884854 },
                AmmSimulationStepData { x_added: 504, y_added: 0, x_checked: 60238, y_checked: 1752189169 },
                AmmSimulationStepData { x_added: 0, y_added: 13719243, x_checked: 59772, y_checked: 1765901552 },
                AmmSimulationStepData { x_added: 560, y_added: 0, x_checked: 60331, y_checked: 1749597500 },
                AmmSimulationStepData { x_added: 670, y_added: 0, x_checked: 61000, y_checked: 1730466028 },
                AmmSimulationStepData { x_added: 0, y_added: 15737295, x_checked: 60452, y_checked: 1746195454 },
                AmmSimulationStepData { x_added: 473, y_added: 0, x_checked: 60924, y_checked: 1732723936 },
                AmmSimulationStepData { x_added: 466, y_added: 0, x_checked: 61389, y_checked: 1719655189 },
                AmmSimulationStepData { x_added: 483, y_added: 0, x_checked: 61871, y_checked: 1706313540 },
                AmmSimulationStepData { x_added: 523, y_added: 0, x_checked: 62393, y_checked: 1692092210 },
                AmmSimulationStepData { x_added: 476, y_added: 0, x_checked: 62868, y_checked: 1679361011 },
                AmmSimulationStepData { x_added: 478, y_added: 0, x_checked: 63345, y_checked: 1666767726 },
                AmmSimulationStepData { x_added: 0, y_added: 79074850, x_checked: 60485, y_checked: 1745803038 },
                AmmSimulationStepData { x_added: 473, y_added: 0, x_checked: 60957, y_checked: 1732341839 },
                AmmSimulationStepData { x_added: 535, y_added: 0, x_checked: 61491, y_checked: 1717353698 },
                AmmSimulationStepData { x_added: 546, y_added: 0, x_checked: 62036, y_checked: 1702321248 },
                AmmSimulationStepData { x_added: 556, y_added: 0, x_checked: 62591, y_checked: 1687280528 },
                AmmSimulationStepData { x_added: 508, y_added: 0, x_checked: 63098, y_checked: 1673776080 },
                AmmSimulationStepData { x_added: 516, y_added: 0, x_checked: 63613, y_checked: 1660277674 },
                AmmSimulationStepData { x_added: 488, y_added: 0, x_checked: 64100, y_checked: 1647715119 },
                AmmSimulationStepData { x_added: 634, y_added: 0, x_checked: 64733, y_checked: 1631653136 },
                AmmSimulationStepData { x_added: 511, y_added: 0, x_checked: 65243, y_checked: 1618948246 },
                AmmSimulationStepData { x_added: 500, y_added: 0, x_checked: 65742, y_checked: 1606708860 },
                AmmSimulationStepData { x_added: 1210, y_added: 0, x_checked: 66951, y_checked: 1577789205 },
                AmmSimulationStepData { x_added: 504, y_added: 0, x_checked: 67454, y_checked: 1566070170 },
                AmmSimulationStepData { x_added: 579, y_added: 0, x_checked: 68032, y_checked: 1552810485 },
                AmmSimulationStepData { x_added: 631, y_added: 0, x_checked: 68662, y_checked: 1538607675 },
                AmmSimulationStepData { x_added: 561, y_added: 0, x_checked: 69222, y_checked: 1526204568 },
                AmmSimulationStepData { x_added: 0, y_added: 13954847, x_checked: 68597, y_checked: 1540152437 },
                AmmSimulationStepData { x_added: 620, y_added: 0, x_checked: 69216, y_checked: 1526422931 },
                AmmSimulationStepData { x_added: 552, y_added: 0, x_checked: 69767, y_checked: 1514411089 },
                AmmSimulationStepData { x_added: 595, y_added: 0, x_checked: 70361, y_checked: 1501668848 },
                AmmSimulationStepData { x_added: 581, y_added: 0, x_checked: 70941, y_checked: 1489433483 },
                AmmSimulationStepData { x_added: 0, y_added: 15158132, x_checked: 70229, y_checked: 1504584035 },
                AmmSimulationStepData { x_added: 543, y_added: 0, x_checked: 70771, y_checked: 1493103368 },
                AmmSimulationStepData { x_added: 0, y_added: 12454559, x_checked: 70188, y_checked: 1505551699 },
                AmmSimulationStepData { x_added: 0, y_added: 13295941, x_checked: 69576, y_checked: 1518840992 },
                AmmSimulationStepData { x_added: 626, y_added: 0, x_checked: 70201, y_checked: 1505361628 },
                AmmSimulationStepData { x_added: 570, y_added: 0, x_checked: 70770, y_checked: 1493300527 },
                AmmSimulationStepData { x_added: 721, y_added: 0, x_checked: 71490, y_checked: 1478302349 },
                AmmSimulationStepData { x_added: 0, y_added: 12558278, x_checked: 70890, y_checked: 1490854347 },
                AmmSimulationStepData { x_added: 0, y_added: 12791911, x_checked: 70289, y_checked: 1503639862 },
                AmmSimulationStepData { x_added: 558, y_added: 0, x_checked: 70846, y_checked: 1491860176 },
                AmmSimulationStepData { x_added: 623, y_added: 0, x_checked: 71468, y_checked: 1478917612 },
                AmmSimulationStepData { x_added: 619, y_added: 0, x_checked: 72086, y_checked: 1466279395 },
                AmmSimulationStepData { x_added: 564, y_added: 0, x_checked: 72649, y_checked: 1454956385 },
                AmmSimulationStepData { x_added: 0, y_added: 10956626, x_checked: 72108, y_checked: 1465907532 },
                AmmSimulationStepData { x_added: 680, y_added: 0, x_checked: 72787, y_checked: 1452272588 },
                AmmSimulationStepData { x_added: 897, y_added: 0, x_checked: 73683, y_checked: 1434671076 },
                AmmSimulationStepData { x_added: 653, y_added: 0, x_checked: 74335, y_checked: 1422125690 },
                AmmSimulationStepData { x_added: 611, y_added: 0, x_checked: 74945, y_checked: 1410588223 },
                AmmSimulationStepData { x_added: 0, y_added: 10673771, x_checked: 74384, y_checked: 1421256657 },
                AmmSimulationStepData { x_added: 590, y_added: 0, x_checked: 74973, y_checked: 1410128653 },
                AmmSimulationStepData { x_added: 608, y_added: 0, x_checked: 75580, y_checked: 1398840609 },
                AmmSimulationStepData { x_added: 852, y_added: 0, x_checked: 76431, y_checked: 1383319899 },
                AmmSimulationStepData { x_added: 593, y_added: 0, x_checked: 77023, y_checked: 1372723325 },
                AmmSimulationStepData { x_added: 0, y_added: 10562316, x_checked: 76437, y_checked: 1383280359 },
                AmmSimulationStepData { x_added: 601, y_added: 0, x_checked: 77037, y_checked: 1372542362 },
                AmmSimulationStepData { x_added: 0, y_added: 12648775, x_checked: 76336, y_checked: 1385184812 },
                AmmSimulationStepData { x_added: 715, y_added: 0, x_checked: 77050, y_checked: 1372384330 },
                AmmSimulationStepData { x_added: 581, y_added: 0, x_checked: 77630, y_checked: 1362165877 },
                AmmSimulationStepData { x_added: 0, y_added: 10983875, x_checked: 77011, y_checked: 1373144260 },
                AmmSimulationStepData { x_added: 622, y_added: 0, x_checked: 77632, y_checked: 1362195191 },
                AmmSimulationStepData { x_added: 0, y_added: 10910006, x_checked: 77018, y_checked: 1373099741 },
                AmmSimulationStepData { x_added: 626, y_added: 0, x_checked: 77643, y_checked: 1362081837 },
                AmmSimulationStepData { x_added: 619, y_added: 0, x_checked: 78261, y_checked: 1351360484 },
                AmmSimulationStepData { x_added: 0, y_added: 11343596, x_checked: 77612, y_checked: 1362698408 },
                AmmSimulationStepData { x_added: 0, y_added: 12831372, x_checked: 76891, y_checked: 1375523364 },
                AmmSimulationStepData { x_added: 704, y_added: 0, x_checked: 77594, y_checked: 1363096286 },
                AmmSimulationStepData { x_added: 0, y_added: 10898335, x_checked: 76981, y_checked: 1373989171 },
                AmmSimulationStepData { x_added: 887, y_added: 0, x_checked: 77867, y_checked: 1358407742 },
                AmmSimulationStepData { x_added: 599, y_added: 0, x_checked: 78465, y_checked: 1348089363 },
                AmmSimulationStepData { x_added: 0, y_added: 15971683, x_checked: 77549, y_checked: 1364053060 },
                AmmSimulationStepData { x_added: 772, y_added: 0, x_checked: 78320, y_checked: 1350659501 },
                AmmSimulationStepData { x_added: 679, y_added: 0, x_checked: 78998, y_checked: 1339101374 },
                AmmSimulationStepData { x_added: 0, y_added: 10652101, x_checked: 78377, y_checked: 1349748148 },
                AmmSimulationStepData { x_added: 813, y_added: 0, x_checked: 79189, y_checked: 1335958511 },
                AmmSimulationStepData { x_added: 0, y_added: 12970136, x_checked: 78430, y_checked: 1348922161 },
                AmmSimulationStepData { x_added: 611, y_added: 0, x_checked: 79040, y_checked: 1338545575 },
                AmmSimulationStepData { x_added: 0, y_added: 21124856, x_checked: 77816, y_checked: 1359659868 },
                AmmSimulationStepData { x_added: 586, y_added: 0, x_checked: 78401, y_checked: 1349549004 },
                AmmSimulationStepData { x_added: 632, y_added: 0, x_checked: 79032, y_checked: 1338807940 },
                AmmSimulationStepData { x_added: 645, y_added: 0, x_checked: 79676, y_checked: 1328020046 },
                AmmSimulationStepData { x_added: 0, y_added: 11483905, x_checked: 78995, y_checked: 1339498209 },
                AmmSimulationStepData { x_added: 0, y_added: 10586819, x_checked: 78378, y_checked: 1350079734 },
                AmmSimulationStepData { x_added: 694, y_added: 0, x_checked: 79071, y_checked: 1338281114 },
                AmmSimulationStepData { x_added: 0, y_added: 17780413, x_checked: 78038, y_checked: 1356052636 },
                AmmSimulationStepData { x_added: 609, y_added: 0, x_checked: 78646, y_checked: 1345603424 },
                AmmSimulationStepData { x_added: 612, y_added: 0, x_checked: 79257, y_checked: 1335263730 },
                AmmSimulationStepData { x_added: 0, y_added: 11732350, x_checked: 78569, y_checked: 1346990213 },
                AmmSimulationStepData { x_added: 828, y_added: 0, x_checked: 79396, y_checked: 1333010141 },
                AmmSimulationStepData { x_added: 0, y_added: 11074313, x_checked: 78744, y_checked: 1344078916 },
                AmmSimulationStepData { x_added: 0, y_added: 10280029, x_checked: 78149, y_checked: 1354353804 },
                AmmSimulationStepData { x_added: 0, y_added: 10322625, x_checked: 77560, y_checked: 1364671267 },
                AmmSimulationStepData { x_added: 723, y_added: 0, x_checked: 78282, y_checked: 1352119360 },
                AmmSimulationStepData { x_added: 864, y_added: 0, x_checked: 79145, y_checked: 1337426496 },
                AmmSimulationStepData { x_added: 644, y_added: 0, x_checked: 79788, y_checked: 1326681624 },
                AmmSimulationStepData { x_added: 0, y_added: 10197743, x_checked: 79182, y_checked: 1336874268 },
                AmmSimulationStepData { x_added: 751, y_added: 0, x_checked: 79932, y_checked: 1324363547 },
                AmmSimulationStepData { x_added: 784, y_added: 0, x_checked: 80715, y_checked: 1311548661 },
                AmmSimulationStepData { x_added: 651, y_added: 0, x_checked: 81365, y_checked: 1301103084 },
                AmmSimulationStepData { x_added: 705, y_added: 0, x_checked: 82069, y_checked: 1289973466 },
                AmmSimulationStepData { x_added: 0, y_added: 17331862, x_checked: 80985, y_checked: 1307296662 },
                AmmSimulationStepData { x_added: 733, y_added: 0, x_checked: 81717, y_checked: 1295617943 },
                AmmSimulationStepData { x_added: 626, y_added: 0, x_checked: 82342, y_checked: 1285815053 },
                AmmSimulationStepData { x_added: 730, y_added: 0, x_checked: 83071, y_checked: 1274561908 },
                AmmSimulationStepData { x_added: 750, y_added: 0, x_checked: 83820, y_checked: 1263202800 },
                AmmSimulationStepData { x_added: 759, y_added: 0, x_checked: 84578, y_checked: 1251911402 },
                AmmSimulationStepData { x_added: 715, y_added: 0, x_checked: 85292, y_checked: 1241460460 },
                AmmSimulationStepData { x_added: 674, y_added: 0, x_checked: 85965, y_checked: 1231770013 },
                AmmSimulationStepData { x_added: 825, y_added: 0, x_checked: 86789, y_checked: 1220117406 },
                AmmSimulationStepData { x_added: 676, y_added: 0, x_checked: 87464, y_checked: 1210728883 },
                AmmSimulationStepData { x_added: 0, y_added: 9671250, x_checked: 86773, y_checked: 1220395297 },
                AmmSimulationStepData { x_added: 656, y_added: 0, x_checked: 87428, y_checked: 1211279953 },
                AmmSimulationStepData { x_added: 716, y_added: 0, x_checked: 88143, y_checked: 1201481533 },
                AmmSimulationStepData { x_added: 0, y_added: 9576349, x_checked: 87449, y_checked: 1211053093 },
                AmmSimulationStepData { x_added: 671, y_added: 0, x_checked: 88119, y_checked: 1201872306 },
                AmmSimulationStepData { x_added: 1028, y_added: 0, x_checked: 89146, y_checked: 1188066206 },
                AmmSimulationStepData { x_added: 843, y_added: 0, x_checked: 89988, y_checked: 1176988943 },
                AmmSimulationStepData { x_added: 870, y_added: 0, x_checked: 90857, y_checked: 1165770148 },
                AmmSimulationStepData { x_added: 0, y_added: 8950723, x_checked: 90167, y_checked: 1174716395 },
                AmmSimulationStepData { x_added: 1192, y_added: 0, x_checked: 91358, y_checked: 1159440132 },
                AmmSimulationStepData { x_added: 734, y_added: 0, x_checked: 92091, y_checked: 1150236528 },
                AmmSimulationStepData { x_added: 883, y_added: 0, x_checked: 92973, y_checked: 1139361430 },
                AmmSimulationStepData { x_added: 847, y_added: 0, x_checked: 93819, y_checked: 1129123500 },
                AmmSimulationStepData { x_added: 0, y_added: 9291805, x_checked: 93056, y_checked: 1138410659 },
                AmmSimulationStepData { x_added: 0, y_added: 10089465, x_checked: 92241, y_checked: 1148495079 },
                AmmSimulationStepData { x_added: 0, y_added: 10139775, x_checked: 91437, y_checked: 1158629784 },
                AmmSimulationStepData { x_added: 762, y_added: 0, x_checked: 92198, y_checked: 1149091410 },
                AmmSimulationStepData { x_added: 855, y_added: 0, x_checked: 93052, y_checked: 1138582143 },
                AmmSimulationStepData { x_added: 0, y_added: 15042137, x_checked: 91843, y_checked: 1153616758 },
                AmmSimulationStepData { x_added: 923, y_added: 0, x_checked: 92765, y_checked: 1142187792 },
                AmmSimulationStepData { x_added: 837, y_added: 0, x_checked: 93601, y_checked: 1132022592 },
                AmmSimulationStepData { x_added: 757, y_added: 0, x_checked: 94357, y_checked: 1122976490 },
                AmmSimulationStepData { x_added: 795, y_added: 0, x_checked: 95151, y_checked: 1113629074 },
                AmmSimulationStepData { x_added: 0, y_added: 31549229, x_checked: 92538, y_checked: 1145162528 },
                AmmSimulationStepData { x_added: 745, y_added: 0, x_checked: 93282, y_checked: 1136053281 },
                AmmSimulationStepData { x_added: 717, y_added: 0, x_checked: 93998, y_checked: 1127423744 },
                AmmSimulationStepData { x_added: 714, y_added: 0, x_checked: 94711, y_checked: 1118959942 },
                AmmSimulationStepData { x_added: 0, y_added: 10563128, x_checked: 93828, y_checked: 1129517788 },
                AmmSimulationStepData { x_added: 826, y_added: 0, x_checked: 94653, y_checked: 1119708347 },
                AmmSimulationStepData { x_added: 0, y_added: 11301173, x_checked: 93711, y_checked: 1131003869 },
                AmmSimulationStepData { x_added: 739, y_added: 0, x_checked: 94449, y_checked: 1122190261 },
                AmmSimulationStepData { x_added: 973, y_added: 0, x_checked: 95421, y_checked: 1110794064 },
                AmmSimulationStepData { x_added: 0, y_added: 8803619, x_checked: 94673, y_checked: 1119593281 },
                AmmSimulationStepData { x_added: 912, y_added: 0, x_checked: 95584, y_checked: 1108957374 },
                AmmSimulationStepData { x_added: 827, y_added: 0, x_checked: 96410, y_checked: 1099490511 },
                AmmSimulationStepData { x_added: 935, y_added: 0, x_checked: 97344, y_checked: 1088974638 },
                AmmSimulationStepData { x_added: 736, y_added: 0, x_checked: 98079, y_checked: 1080835947 },
                AmmSimulationStepData { x_added: 0, y_added: 12576006, x_checked: 96955, y_checked: 1093405664 },
                AmmSimulationStepData { x_added: 863, y_added: 0, x_checked: 97817, y_checked: 1083803404 },
                AmmSimulationStepData { x_added: 900, y_added: 0, x_checked: 98716, y_checked: 1073965918 },
                AmmSimulationStepData { x_added: 1398, y_added: 0, x_checked: 100113, y_checked: 1059021862 },
                AmmSimulationStepData { x_added: 1030, y_added: 0, x_checked: 101142, y_checked: 1048278663 },
                AmmSimulationStepData { x_added: 1011, y_added: 0, x_checked: 102152, y_checked: 1037944577 },
                AmmSimulationStepData { x_added: 846, y_added: 0, x_checked: 102997, y_checked: 1029459138 },
                AmmSimulationStepData { x_added: 0, y_added: 44702054, x_checked: 98724, y_checked: 1074138840 },
                AmmSimulationStepData { x_added: 1346, y_added: 0, x_checked: 100069, y_checked: 1059743995 },
                AmmSimulationStepData { x_added: 0, y_added: 9861120, x_checked: 99150, y_checked: 1069600184 },
                AmmSimulationStepData { x_added: 1032, y_added: 0, x_checked: 100181, y_checked: 1058624232 },
                AmmSimulationStepData { x_added: 0, y_added: 15562515, x_checked: 98734, y_checked: 1074178965 },
            ]
        };
        test_utils_amm_simulate(admin, &s);
    }
}
