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
    const EZeroAmount: u64 = 13400;
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
    public entry fun create_pool<X, Y>(owner: &signer, x_amt: u64, y_amt: u64, admin_fee: u64, lp_fee: u64) acquires AptoswapCap, LSPCapabilities, Pool {
        let _ = create_pool_impl<X, Y>(owner, x_amt, y_amt, admin_fee, lp_fee);
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

    fun create_pool_impl<X, Y>(owner: &signer, x_amt: u64, y_amt: u64, admin_fee: u64, lp_fee: u64): address acquires AptoswapCap, LSPCapabilities, Pool {
        let owner_addr = signer::address_of(owner);

        assert!(exists<AptoswapCap>(owner_addr), EPermissionDenied);
        assert!(coin::balance<X>(owner_addr) >= x_amt, ENotEnoughBalance);
        assert!(coin::balance<Y>(owner_addr) >= y_amt, ENotEnoughBalance);
        assert!(x_amt > 0 && y_amt > 0, EZeroAmount);
        assert!(lp_fee >= 0, EWrongFee);
        assert!(admin_fee >= 0, EWrongFee);
        assert!(lp_fee + admin_fee < (BPS_SCALING as u64), EWrongFee);

        let aptos_cap = borrow_global_mut<AptoswapCap>(owner_addr);
        let pool_id = aptos_cap.pool_id_counter;
        aptos_cap.pool_id_counter = aptos_cap.pool_id_counter + 1;

        let (pool_account_signer, pool_account_cap) = account::create_resource_account(owner, get_pool_seed_from_pool_id(pool_id));
        let pool_account_addr = signer::address_of(&pool_account_signer);

        let lsp_share_amt = sqrt(x_amt) * sqrt(y_amt);

        // Create pool and move
        let pool = Pool<X, Y> {
            x: x_amt,
            y: y_amt,
            x_admin: 0,
            y_admin: 0,
            lsp_supply: lsp_share_amt,
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
        coin::transfer<X>(owner, pool_account_addr, x_amt);
        coin::transfer<Y>(owner, pool_account_addr, y_amt);

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

        // Mint corresponding lsp token and transfer to the owner
        let lsp_cap = borrow_global<LSPCapabilities<X, Y>>(pool_account_addr);
        let lsp_coin_minted = coin::mint(lsp_share_amt, &lsp_cap.mint);

        if (!coin::is_account_registered<LSP<X, Y>>(owner_addr)) {
            managed_coin::register<LSP<X, Y>>(owner);
        };
        
        coin::deposit(owner_addr, lsp_coin_minted);

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
        assert!(in_amount > 0, EZeroAmount);

        let user_addr = signer::address_of(user);
        
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
        assert!(in_amount > 0, EZeroAmount);

        let user_addr = signer::address_of(user);
        
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);
        let k_before = compute_k(pool);

        let (x_reserve_amt, y_reserve_amt, _) = get_amounts(pool);
        assert!(x_reserve_amt > 0 && y_reserve_amt > 0, EReservesEmpty);

        let ComputeShareStruct { 
            remain: y_remain_amt,
            admin: y_admin_amt,
            lp: _
        } = compute_share(pool, in_amount);

        // Get the output amount
        let output_amount = compute_amount(
            y_remain_amt,
            y_reserve_amt,
            x_reserve_amt,
        );

        pool.y_admin = pool.y_admin + y_admin_amt;
        pool.y = pool.y + y_remain_amt;
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
        assert!(x_added > 0, EZeroAmount);
        assert!(y_added > 0, EZeroAmount);

        let user_addr = signer::address_of(user);
        let pool = borrow_global_mut<Pool<X, Y>>(pool_account_addr);
        // let pool_account_signer = &account::create_signer_with_capability(&pool.pool_cap);

        // We should make the value "token / lsp" larger than the previous value before adding liqudity
        // Thus 
        // (token + dtoken) / (lsp + dlsp) >= token / lsp
        //  ==> (token + dtoken) * lsp >= token * (lsp + dlsp)
        //  ==> dtoken * lsdp >= token * dlsp
        //  ==> dlsp <= dtoken * lsdp / token
        //  ==> dslp = floor[dtoken * lsdp / token] <= dtoken * lsdp / token
        // We use the floor operation
        let (x_amt, y_amt, lsp_supply) = get_amounts(pool);
        let x_shared_minted: u128 = ((x_added as u128) * (pool.lsp_supply as u128)) / (x_amt as u128);
        let y_shared_minted: u128 = ((y_added as u128) * (pool.lsp_supply as u128)) / (y_amt as u128);

        let share_minted: u128 = if (x_shared_minted < y_shared_minted) { x_shared_minted } else { y_shared_minted };
        let share_minted: u64 = (share_minted as u64);

        // Transfer the X, Y to the pool and transfer 
        let mint_cap = &borrow_global<LSPCapabilities<X, Y>>(pool_account_addr).mint;
        coin::transfer<X>(user, pool_account_addr, x_added);
        coin::transfer<Y>(user, pool_account_addr, y_added);
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
        assert!(lsp_amount > 0, EZeroAmount);

        let user_addr = signer::address_of(user);
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
            coin::transfer<X>(pool_account_signer, owner_addr, pool.x_admin);
            pool.x_admin = 0;
        };

        if (pool.y_admin > 0)
        {
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
    fun test_create_pool(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool { test_create_pool_impl(admin); }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134007)] // EPermissionDenied
    fun test_create_pool_with_non_admin(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_create_pool_with_non_admin_impl(admin, guy);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    fun test_swap_x_to_y(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(admin, guy, false);
    }

    #[test(admin = @Aptoswap, guy = @0x10000)]
    #[expected_failure(abort_code = 134007)] // EPermissionDenied
    fun test_swap_x_to_y_with_non_admin(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        test_swap_x_to_y_impl(admin, guy, true);
    }
    // ============================================= Test Case =============================================

    struct TX { }
    struct TY { }
    struct TZ { }
    struct TW { }

    const TEST_Y_AMT: u64 = 1000000000;
    const TEST_X_AMT: u64 = 1000000;
    const TEST_LSP_AMT: u64 = 31622000;

    fun test_create_pool_impl(admin: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        account::create_account(signer::address_of(&admin));

        let admin = &admin;
        let admin_addr = signer::address_of(admin);
        test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);

        assert!(coin::balance<LSP<TX, TY>>(admin_addr) == TEST_LSP_AMT, 0);
    }

    fun test_create_pool_with_non_admin_impl(admin: signer, guy: signer) acquires AptoswapCap, LSPCapabilities, Pool {
        let admin = &admin;
        let guy = &guy;
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);

        managed_coin::initialize<TZ>(admin, b"TX", b"TX", 10, true);
        managed_coin::initialize<TW>(admin, b"TY", b"TY", 10, true);
        assert!(coin::is_coin_initialized<TZ>(), 1);
        assert!(coin::is_coin_initialized<TW>(), 2);
        managed_coin::register<TZ>(guy);
        managed_coin::register<TW>(guy);
        assert!(coin::is_account_registered<TZ>(guy_addr), 3);
        assert!(coin::is_account_registered<TW>(guy_addr), 4);
        managed_coin::mint<TZ>(admin, guy_addr, 10);
        managed_coin::mint<TW>(admin, guy_addr, 10);
        assert!(coin::balance<TZ>(guy_addr) == 10, 5);
        assert!(coin::balance<TW>(guy_addr) == 10, 5);

        let _ = create_pool_impl<TZ, TW>(guy, 10, 10, 5, 25);
    }

    fun test_swap_x_to_y_impl(admin: signer, guy: signer, check_redeem_permision: bool) acquires AptoswapCap, LSPCapabilities, Pool {
        let admin = &admin;
        let guy = &guy;
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account(admin_addr);
        account::create_account(guy_addr);

        // Create pool
        let pool_account_addr = test_utils_create_pool(admin, TEST_X_AMT, TEST_Y_AMT);
        managed_coin::register<TX>(guy);
        managed_coin::register<TY>(guy);
        managed_coin::mint<TX>(admin, guy_addr, 5000);

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
        let (check_user, check_user_addr) = if (check_redeem_permision) { (guy, guy_addr) } else { (admin,admin_addr) };
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

        // Register & mint some coin
        managed_coin::register<TX>(admin);
        managed_coin::register<TY>(admin);
        assert!(coin::is_account_registered<TX>(admin_addr), 3);
        assert!(coin::is_account_registered<TY>(admin_addr), 4);
        managed_coin::mint<TX>(admin, admin_addr, init_x_amt);
        managed_coin::mint<TY>(admin, admin_addr, init_y_amt);
        assert!(coin::balance<TX>(admin_addr) == init_x_amt, 5);
        assert!(coin::balance<TY>(admin_addr) == init_y_amt, 5);
        
        let pool_account_addr = create_pool_impl<TX, TY>(admin, init_x_amt, init_y_amt, 5, 25);
        let _ = borrow_global<LSPCapabilities<TX, TY>>(pool_account_addr);
        let pool = borrow_global<Pool<TX, TY>>(pool_account_addr);
        assert!(coin::is_coin_initialized<LSP<TX, TY>>(), 6);
        assert!(coin::is_account_registered<LSP<TX, TY>>(pool_account_addr), 7);
        assert!(coin::balance<LSP<TX, TY>>(admin_addr) > 0, 8);
        assert!(coin::balance<LSP<TX, TY>>(admin_addr) == get_lsp_supply(pool), 8);

        // Use == for testing
        assert!(pool.x_admin == 0 && pool.y_admin == 0, 9);
        assert!(coin::balance<TX>(pool_account_addr) == pool.x, 9);
        assert!(coin::balance<TY>(pool_account_addr) == pool.y, 9);
        assert!(pool.x == TEST_X_AMT, 9);
        assert!(pool.y == TEST_Y_AMT, 10);

        // Validate the lsp information
        validate_lsp<TX, TY>(pool);

        pool_account_addr
    }
}
