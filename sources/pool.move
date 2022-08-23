module Aptoswap::pool {
    use std::string;
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_std::event;
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

    struct AptoswapCap has key {
        /// Points to the next pool id that should be used
        pool_id_counter: u64,
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
        /// Admin fee is denominated in basis points, in bps
        admin_fee: u64,
        /// Liqudity fee is denominated in basis points, in bps
        lp_fee: u64,
        /// Capability
        pool_cap: account::SignerCapability,
    }

    // ============================================= Entry points =============================================
    public entry fun initialize(owner: &signer, demicals: u8) {
        initialize_impl(owner, demicals);
    }
    public entry fun create_pool<X, Y>(owner: &signer, x_amt: u64, y_amt: u64, admin_fee: u64, lp_fee: u64) acquires AptoswapCap, LSPCapabilities {
        create_pool_impl<X, Y>(owner, x_amt, y_amt, admin_fee, lp_fee);
    }
    public entry fun swap_x_to_y<X, Y>(user: &signer, pool_account_addr: address, x_amt: u64) {
        swap_x_to_y_impl<X, Y>(user, pool_account_addr, x_amt);
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

        let aptos_cap = AptoswapCap { pool_id_counter: 0 };
        move_to(owner, aptos_cap);
    }

    fun create_pool_impl<X, Y>(owner: &signer, x_amt: u64, y_amt: u64, admin_fee: u64, lp_fee: u64) acquires AptoswapCap, LSPCapabilities {
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

        // Create pool and move
        let pool = Pool<X, Y> {
            x: x_amt,
            y: y_amt,
            x_admin: 0,
            y_admin: 0,
            admin_fee: admin_fee,
            lp_fee: lp_fee,
            pool_cap: pool_account_cap,
        };
        move_to(&pool_account_signer, pool);

        // Transfer the balance to the pool account
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
        let lsp_share_amt = sqrt(x_amt) * sqrt(y_amt);
        let lsp_coin_minted = coin::mint(lsp_share_amt, &lsp_cap.mint);

        if (!coin::is_account_registered<LSP<X, Y>>(owner_addr)) {
            managed_coin::register<LSP<X, Y>>(owner);
        };
        coin::deposit(owner_addr, lsp_coin_minted);
    }

    fun swap_x_to_y_impl<X, Y>(user: &signer, pool_account_addr: address, x_amt: u64) {
        
    }
    // ============================================= Implementations =============================================

    // ============================================= Helper Function =============================================

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
}
