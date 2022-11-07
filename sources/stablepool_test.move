#[test_only]
module Aptoswap::stablepool_test {

    use std::signer;
    use std::vector;
    use aptos_framework::coin;
    use aptos_framework::managed_coin;
    use aptos_framework::account;

    use Aptoswap::u256::{ 
        U256, 
        add,
        sub,
        mul,
        div,
        from_u64,
        from_u128,
        as_u128,
        as_u64,
        greater_or_equals,
        less_or_equals,
        equals
    };

    use Aptoswap::pool::{ 
        LSP, Token,
        swap_y_to_x_impl, 
        initialize_impl, 
        add_liquidity_impl, 
        create_pool_impl, 
        swap_x_to_y_impl, 
        remove_liquidity_impl_v2,
        validate_lsp_from_address,
        get_pool_x, 
        get_pool_y, 
        get_pool_lsp_supply, 
        is_swap_cap_exists, 
        get_pool_admin_fee, 
        get_pool_lp_fee, 
        get_pool_connect_fee, 
        get_pool_incentive_fee,
        ss_compute_d,
        ss_compute_y,
        ss_swap_to,
        ss_compute_mint_amount_for_deposit,
        ss_compute_withdraw_one,
        ss_compute_withdraw
    };

    struct SwapTest has copy, store, drop {
        amp: U256,
        x: U256,
        y: U256,
    }

    struct SwapTestUser has copy, store, drop {
        x: U256,
        y: U256
    }

    struct USDC {}
    struct USDT {}

    struct AmmStableSwapBacktestStepData has copy, drop {
        /// The tag, swap for 0, 1 for deposit, 2 for withdraw
        tag: u8,
        /// The index for the movement, we can have multiple actions in a single index
        index: u64,
        /// The previous reserve x in the pool
        x_prev: u64,
        /// The current reserve x in the pool after the action
        x: u64,
        /// The previous reserve y in the pool
        y_prev: u64,
        /// The current reserve y in the pool after the action
        y: u64,
        /// The previous lsp supply in the pool
        lsp_prev: u64,
        /// The current lsp supply after the action in the pool
        lsp: u64,
        /// The price numerator
        pn: u128,
        /// The price denominator
        pd: u128
    }

    struct AmmStableSwapBacktestData has copy, drop {
        /// The decimal X token for the pool
        x_decimal: u8,
        /// The decimal Y token for the pool
        y_decimal: u8,
        /// The amplifier
        amp: u64,
        // The simulation step data
        data: vector<AmmStableSwapBacktestStepData>
    }

    #[test_only]
    fun do_swap_test_x_to_y(t: &mut SwapTest, user: &mut SwapTestUser, dx: U256) {
        let dy = ss_swap_to(dx, t.x, t.y, t.amp);
        t.x = add(t.x, dx);
        t.y = sub(t.y, dy);
        user.x = sub(user.x, dx);
        user.x = add(user.x, dy);
    }

    #[test_only]
    fun do_swap_test_y_to_x(t: &mut SwapTest, user: &mut SwapTestUser, dy: U256) {
        let dx = ss_swap_to(dy, t.y, t.x, t.amp);
        t.x = sub(t.x, dx);
        t.y = add(t.y, dy);
        user.x = add(user.x, dx);
        user.x = sub(user.x, dy);
    }

    #[test_only]
    fun check_d(amount_a: u128, amount_b: u128, amp: u128, d_check: u128) {
        let amount_a_ = from_u128(amount_a);
        let amount_b_ = from_u128(amount_b);
        let amp_ = from_u128(amp);
        let d_check_ = from_u128(d_check);
        let d = ss_compute_d(amount_a_, amount_b_, amp_);
        assert!(equals(&d, &d_check_), 0);
    }

    #[test_only]
    fun check_y(x: u128, d: u128, amp: u128, y_check: u128) {
        let x_ = from_u128(x);
        let d_ = from_u128(d);
        let amp_ = from_u128(amp);
        let y_check_ = from_u128(y_check);
        let y = ss_compute_y(x_, d_, amp_);
        assert!(equals(&y, &y_check_), 0);
    }

    #[test_only]
    fun check_swap(source_amount: u128, swap_source_amount: u128, swap_destination_amount: u128, amp: u128, new_source_amount_check: u128, new_destination_amount_check: u128, amount_swap_check: u128) {
        let amount_swap = as_u128(ss_swap_to(
            from_u128(source_amount),
            from_u128(swap_source_amount),
            from_u128(swap_destination_amount),
            from_u128(amp)
        ));

        assert!(amount_swap == amount_swap_check, 0);
        assert!(source_amount + swap_source_amount == new_source_amount_check, 0);
        assert!(new_destination_amount_check + amount_swap == swap_destination_amount, 0);
    }

    #[test_only]
    fun check_withdraw_one(
        pool_token_amount: u128,
        pool_token_supply: u128,
        swap_base_amount: u128,
        swap_quote_amount: u128,
        amp: u128,
        withdraw_checked: u128
    ) {
        let withdraw = as_u128(ss_compute_withdraw_one(
            from_u128(pool_token_amount),
            from_u128(pool_token_supply),
            from_u128(swap_base_amount),
            from_u128(swap_quote_amount),
            from_u128(amp),
       ));
       assert!(withdraw == withdraw_checked, 0);
    }

    #[test_only]
    fun check_virtual_price_does_not_decrease_from_deposit(
        amp: u128,
        deposit_amount_a: u128,
        deposit_amount_b: u128,
        swap_token_a_amount: u128,
        swap_token_b_amount: u128,
        pool_token_supply: u128
    ) {
        let amp = from_u128(amp);
        let deposit_amount_a = from_u128(deposit_amount_a);
        let deposit_amount_b = from_u128(deposit_amount_b);
        let swap_token_a_amount = from_u128(swap_token_a_amount);
        let swap_token_b_amount = from_u128(swap_token_b_amount);
        let pool_token_supply = from_u128(pool_token_supply);

        let d0 = ss_compute_d(swap_token_a_amount, swap_token_b_amount, amp);

        let mint_amount = ss_compute_mint_amount_for_deposit(
            deposit_amount_a,
            deposit_amount_b,
            swap_token_a_amount,
            swap_token_b_amount,
            pool_token_supply,
            amp
        );

        let new_swap_token_a_amount = add(swap_token_a_amount, deposit_amount_a);
        let new_swap_token_b_amount = add(swap_token_b_amount, deposit_amount_b);
        let new_pool_token_supply = add(pool_token_supply, mint_amount);

        let d1 = ss_compute_d(new_swap_token_a_amount, new_swap_token_b_amount, amp);

        assert!(less_or_equals(&d0, &d1), 0);
        assert!(
            less_or_equals(&div(d0, pool_token_supply), &div(d1, new_pool_token_supply)), 0
        );
    }

    #[test_only]
    fun check_virtual_price_does_not_decrease_from_swap(
        amp: u128,
        source_token_amount: u128,
        swap_source_amount: u128,
        swap_destination_amount: u128,
    ) {
        let amp = from_u128(amp);
        let source_token_amount = from_u128(source_token_amount);
        let swap_source_amount = from_u128(swap_source_amount);
        let swap_destination_amount = from_u128(swap_destination_amount);

        let d0 = ss_compute_d(swap_source_amount, swap_destination_amount, amp);

        let destination_token_amount = ss_swap_to(source_token_amount, swap_source_amount, swap_destination_amount, amp);

        let d1 = ss_compute_d(add(swap_source_amount, source_token_amount), sub(swap_destination_amount, destination_token_amount), amp);

        // Pool token supply not changed on swaps
        assert!(less_or_equals(&d0, &d1), 0);
    }

    #[test_only]
    fun check_virtual_price_does_not_decrease_from_withdraw(
        amp: u128,
        pool_token_amount: u128,
        pool_token_supply: u128,
        swap_base_amount: u128,
        swap_quote_amount: u128
    ) {
        let amp = from_u128(amp);
        let pool_token_amount = from_u128(pool_token_amount);
        let pool_token_supply = from_u128(pool_token_supply);
        let swap_base_amount = from_u128(swap_base_amount);
        let swap_quote_amount = from_u128(swap_quote_amount);

        // The validation will do inside
        ss_compute_withdraw(pool_token_amount, pool_token_supply, swap_base_amount, swap_quote_amount, amp);
    }

    #[test_only]
    fun check_virtual_price_does_not_decrease_from_withdraw_one(
        amp: u128,
        pool_token_amount: u128,
        pool_token_supply: u128,
        swap_base_amount: u128,
        swap_quote_amount: u128
    ) {
        let amp = from_u128(amp);
        let pool_token_amount = from_u128(pool_token_amount);
        let pool_token_supply = from_u128(pool_token_supply);
        let swap_base_amount = from_u128(swap_base_amount);
        let swap_quote_amount = from_u128(swap_quote_amount);

        // The validation will do inside
        ss_compute_withdraw_one(pool_token_amount, pool_token_supply, swap_base_amount, swap_quote_amount, amp);
    }
    

    fun check_swaps_does_not_result_in_more_tokens(
        pool_x: u64,
        pool_y: u64,
        user_x: u64,
        user_y: u64,
        amp: u64,
        x_to_y: bool
    ) {
        let iterations: u64 = 100;
        let shirnk_mul: u64= 10;

        let t = SwapTest {  amp: from_u64(amp), x: from_u64(pool_x), y: from_u64(pool_y) };
        let user = SwapTestUser { x: from_u64(user_x), y: from_u64(user_y) };

        let counter = 0;
        while (counter < 2) {
            let i = 0;
            while (i < iterations) {
                let bx = user.x;
                let by = user.y;
                if (x_to_y) {
                    let swap_amount = div(bx,  mul(from_u64(i + 1), from_u64(shirnk_mul)));
                    do_swap_test_x_to_y(&mut t, &mut user, swap_amount);                    
                }
                else {
                    let swap_amount = div(by,  mul(from_u64(i + 1), from_u64(shirnk_mul)));
                    do_swap_test_y_to_x(&mut t, &mut user, swap_amount);                    
                };
                assert!(
                    greater_or_equals(
                        &add(bx, by), 
                        &add(user.x, user.y)
                    ), 
                    0
                );
                i = i + 1;
            };
            counter = counter + 1;
        };
    }

    #[test]
    fun test_compute_mint_amount_for_deposit() {
        let deposit_amount_a = 1152921504606846976;
        let deposit_amount_b = 1152921504606846976;
        let swap_amount_a = 1152921504606846976;
        let swap_amount_b = 1152921504606846976;
        let pool_token_supply = 1152921504606846976;
        let actual_mint_amount = ss_compute_mint_amount_for_deposit(
            from_u64(deposit_amount_a),
            from_u64(deposit_amount_b),
            from_u64(swap_amount_a),
            from_u64(swap_amount_b),
            from_u64(pool_token_supply),
            from_u64(2000)
        );
        let expected_mint_amount = 1152921504606846976;
        assert!(as_u64(actual_mint_amount) == expected_mint_amount, 0);
    }

    #[test_only]
    fun test_utils_create_stablepool(admin: &signer, guy: &signer, init_x_amt: u64, init_y_amt: u64, x_decimal: u8, y_decimal: u8): address {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);

        initialize_impl(admin, 8);

        // Check registe token and borrow capability
        assert!(coin::is_coin_initialized<Token>(), 0);
        assert!(is_swap_cap_exists(admin_addr), 0);

        managed_coin::initialize<USDC>(admin, b"USDC", b"USDC", x_decimal, true);
        managed_coin::initialize<USDT>(admin, b"USDT", b"USDT", y_decimal, true);
        assert!(coin::is_coin_initialized<USDC>(), 1);
        assert!(coin::is_coin_initialized<USDT>(), 2);

        // Creat the pool
        let pool_account_addr = create_pool_impl<USDC, USDT>(admin, 101, 200, 0, 0, 0, 0, 0, 100);
        assert!(coin::is_coin_initialized<LSP<USDC, USDT>>(), 8);
        assert!(coin::is_account_registered<LSP<USDC, USDT>>(pool_account_addr), 8);
        assert!(get_pool_x<USDC, USDT>() == 0, 0);
        assert!(get_pool_y<USDC, USDT>() == 0, 0);
        assert!(get_pool_lsp_supply<USDC, USDT>() == 0, 0);

        assert!(get_pool_admin_fee<USDC, USDT>() == 0, 0);
        assert!(get_pool_connect_fee<USDC, USDT>() == 0, 0);
        assert!(get_pool_lp_fee<USDC, USDT>() == 0, 0);
        assert!(get_pool_incentive_fee<USDC, USDT>() == 0, 0);

        validate_lsp_from_address<USDC, USDT>();

        // Register & mint some coin
        assert!(coin::is_account_registered<USDC>(admin_addr), 3);
        assert!(coin::is_account_registered<USDT>(admin_addr), 4);

        if (!coin::is_account_registered<USDC>(guy_addr)) {
            managed_coin::register<USDC>(guy);
        };
        if (!coin::is_account_registered<USDT>(guy_addr)) {
            managed_coin::register<USDT>(guy);
        };
        managed_coin::mint<USDC>(admin, guy_addr, init_x_amt);
        managed_coin::mint<USDT>(admin, guy_addr, init_y_amt);
        assert!(coin::balance<USDC>(guy_addr) == init_x_amt, 5);
        assert!(coin::balance<USDT>(guy_addr) == init_y_amt, 5);

        if (init_x_amt > 0 && init_y_amt > 0) {
            add_liquidity_impl<USDC, USDT>(guy, init_x_amt, init_y_amt);
            assert!(coin::balance<LSP<USDC, USDT>>(guy_addr) > 0, 8);
            assert!(coin::balance<LSP<USDC, USDT>>(guy_addr) == get_pool_lsp_supply<USDC, USDT>(), 8);
        };
        validate_lsp_from_address<USDC, USDT>();

        // Use == for testing
        assert!(get_pool_x<USDC, USDT>() == init_x_amt, 9);
        assert!(get_pool_y<USDC, USDT>() == init_y_amt, 10);

        pool_account_addr
    }

    #[test_only]
    fun test_utils_backtest(admin: &signer, guy: &signer, s: &AmmStableSwapBacktestData) {
        let admin_addr = signer::address_of(admin);
        let guy_addr = signer::address_of(guy);
        account::create_account_for_test(admin_addr);
        account::create_account_for_test(guy_addr);

        test_utils_create_stablepool(admin, guy, 0, 0, s.x_decimal, s.y_decimal);
        let i: u64 = 0;
        let data_legnth: u64 = vector::length(&s.data);
        while (i < data_legnth) 
        {
            let info = vector::borrow(&s.data, i);
            // Do the simulation

            let (x_old, y_old, lsp_old) = (get_pool_x<USDC, USDT>(), get_pool_y<USDC, USDT>(), get_pool_lsp_supply<USDC, USDT>());
            assert!(x_old == info.x_prev, 0);
            assert!(y_old == info.y_prev, 0);
            assert!(lsp_old == info.lsp_prev, 0);

            if (info.tag == 0) {
                if (info.x > info.x_prev) {
                    managed_coin::mint<USDC>(admin, guy_addr, info.x - info.x_prev);
                    swap_x_to_y_impl<USDC, USDT>(guy, info.x - info.x_prev, 0, 0);
                }
                else if (info.y > info.y_prev) {
                    managed_coin::mint<USDT>(admin, guy_addr, info.y - info.y_prev);
                    swap_y_to_x_impl<USDC, USDT>(guy, info.y - info.y_prev, 0, 0);
                }
            } else if (info.tag == 1) {
                let dx = info.x - info.x_prev;
                let dy = info.y - info.y_prev;
                managed_coin::mint<USDC>(admin, guy_addr, dx);
                managed_coin::mint<USDT>(admin, guy_addr, dy);
                add_liquidity_impl<USDC, USDT>(guy, dx, dy);
            }
            else if (info.tag == 2) {
                let dlsp = info.lsp_prev - info.lsp;
                remove_liquidity_impl_v2<USDC, USDT>(guy, dlsp, 0);
            };

            let (x_new, y_new, lsp_new) = (get_pool_x<USDC, USDT>(), get_pool_y<USDC, USDT>(), get_pool_lsp_supply<USDC, USDT>());
            assert!(x_new == info.x, 0);
            assert!(y_new == info.y, 0);
            assert!(lsp_new == info.lsp, 0);

            i = i + 1;
        };

        // Last withdraw all the tokens and validate (for testing re-empty the pool)
        remove_liquidity_impl_v2<USDC, USDT>(guy, get_pool_lsp_supply<USDC, USDT>(), 0);
        let (x_final, y_final, lsp_final) = (get_pool_x<USDC, USDT>(), get_pool_y<USDC, USDT>(), get_pool_lsp_supply<USDC, USDT>());
        assert!(x_final == 0, 0);
        assert!(y_final == 0, 0);
        assert!(lsp_final == 0, 0);
    }

    // Test two backtest data is generated from the "develop/scripts/amm_stable_price_data_raw/stable_backtest.wl" in suiswap. A mathematica 
    // code that generats a list of backtest data based on the market price for USDC/USDT in binance market
    #[test(admin = @Aptoswap, guy = @0x10000)] fun test_backtest(admin: signer, guy: signer) { test_backtest_impl(&admin, &guy); }
    #[test(admin = @Aptoswap, guy = @0x10000)] fun test_backtest2(admin: signer, guy: signer) { test_backtest2_impl(&admin, &guy); }

    #[test_only]
    fun test_backtest_impl(admin: &signer, guy: &signer) {
        let s = AmmStableSwapBacktestData {
            x_decimal: 8,
            y_decimal: 4,
            amp: 100,
            data: vector[
                AmmStableSwapBacktestStepData { tag: 1, index: 1, x_prev: 0, x: 12724391200000000, y_prev: 0, y: 1272439120000, lsp_prev: 0, lsp: 127243862962632, pn: 1, pd: 1},
                AmmStableSwapBacktestStepData { tag: 0, index: 1, x_prev: 12724391200000000, x: 9955414196461476, y_prev: 1272439120000, y: 1549963930764, lsp_prev: 127243862962632, lsp: 127243862962632, pn: 1079087822395775424884406620000, pd: 1076396830319999639912008065129},
                AmmStableSwapBacktestStepData { tag: 1, index: 2, x_prev: 9955414196461476, x: 9965309718209943, y_prev: 1549963930764, y: 1551504570006, lsp_prev: 127243862962632, lsp: 127370341317848, pn: 1729974528723376726542642700940000, pd: 1725660377778971886171539949523007},
                AmmStableSwapBacktestStepData { tag: 0, index: 2, x_prev: 9965309718209943, x: 12102007689110934, y_prev: 1551504570006, y: 1337238478659, lsp_prev: 127370341317848, lsp: 127370341317848, pn: 903825170300721582711863131205000, pd: 903373483558958275626941512374033},
                AmmStableSwapBacktestStepData { tag: 2, index: 3, x_prev: 12102007689110934, x: 11585062510211455, y_prev: 1337238478659, y: 1280117461855, lsp_prev: 127370341317848, lsp: 121929633827777, pn: 159025794599784939733188214770000, pd: 158946321439067740916291200870357},
                AmmStableSwapBacktestStepData { tag: 0, index: 3, x_prev: 11585062510211455, x: 10781447932864542, y_prev: 1280117461855, y: 1360612956609, lsp_prev: 121929633827777, lsp: 121929633827777, pn: 131151649089619184862572928225000, pd: 130994455742730770107069744933187},
                AmmStableSwapBacktestStepData { tag: 2, index: 4, x_prev: 10781447932864542, x: 10392322383050117, y_prev: 1360612956609, y: 1311505520565, lsp_prev: 121929633827777, lsp: 117528932169025, pn: 27417466112285871409595916580350000, pd: 27384604586782328534789618435097563},
                AmmStableSwapBacktestStepData { tag: 0, index: 4, x_prev: 10392322383050117, x: 9275663139961511, y_prev: 1311505520565, y: 1423554973129, lsp_prev: 117528932169025, lsp: 117528932169025, pn: 26591565617195673363249223920310000, pd: 26527898660411291688739340527834729},
                AmmStableSwapBacktestStepData { tag: 2, index: 5, x_prev: 9275663139961511, x: 9101798119522894, y_prev: 1423554973129, y: 1396871553220, lsp_prev: 117528932169025, lsp: 115325944642919, pn: 775879770345138206411728788100000, pd: 774022117263722715978825154730987},
                AmmStableSwapBacktestStepData { tag: 0, index: 5, x_prev: 9101798119522894, x: 10197526462126716, y_prev: 1396871553220, y: 1286922379641, lsp_prev: 115325944642919, lsp: 115325944642919, pn: 366656408065946513450948031552500, pd: 366216947728679397933787127108699},
                AmmStableSwapBacktestStepData { tag: 2, index: 6, x_prev: 10197526462126716, x: 9832633378333283, y_prev: 1286922379641, y: 1240873067835, lsp_prev: 115325944642919, lsp: 111199292975141, pn: 3067974881764517695373418839400000, pd: 3064297724495177105268633684694387},
                AmmStableSwapBacktestStepData { tag: 0, index: 6, x_prev: 9832633378333283, x: 10349225290031714, y_prev: 1240873067835, y: 1189117362560, lsp_prev: 111199292975141, lsp: 111199292975141, pn: 128887399216227462867258251200000, pd: 128797241147426643628072135517703},
                AmmStableSwapBacktestStepData { tag: 2, index: 7, x_prev: 10349225290031714, x: 10331154185965586, y_prev: 1189117362560, y: 1187041007761, lsp_prev: 111199292975141, lsp: 111005124432171, pn: 4932007050244556321908298576615000, pd: 4928557060302417485247952583325059},
                AmmStableSwapBacktestStepData { tag: 0, index: 7, x_prev: 10331154185965586, x: 9620917026798342, y_prev: 1187041007761, y: 1258210638812, lsp_prev: 111005124432171, lsp: 111005124432171, pn: 4870991161642776701216065978180000, pd: 4864181307811940780340618137327553},
                AmmStableSwapBacktestStepData { tag: 1, index: 8, x_prev: 9620917026798342, x: 9911309784878481, y_prev: 1258210638812, y: 1296187814650, lsp_prev: 111005124432171, lsp: 114355645401747, pn: 833786414763468699143703576500000, pd: 832620745719479005526655657986901},
                AmmStableSwapBacktestStepData { tag: 0, index: 8, x_prev: 9911309784878481, x: 9270780003572034, y_prev: 1296187814650, y: 1360457148284, lsp_prev: 114355645401747, lsp: 114355645401747, pn: 12696019344876754904112372268420000, pd: 12669413576366630379624555734316867},
                AmmStableSwapBacktestStepData { tag: 1, index: 9, x_prev: 9270780003572034, x: 9389744796790139, y_prev: 1360457148284, y: 1377914849067, lsp_prev: 114355645401747, lsp: 115823083492531, pn: 651197323147295747959441433520000, pd: 649832674530793777547529752626379},
                AmmStableSwapBacktestStepData { tag: 0, index: 9, x_prev: 9389744796790139, x: 9565198022045050, y_prev: 1377914849067, y: 1360301884924, lsp_prev: 115823083492531, lsp: 115823083492531, pn: 6349197230004521417561490661600, pd: 6337156632403148256577034627717},
                AmmStableSwapBacktestStepData { tag: 2, index: 10, x_prev: 9565198022045050, x: 9404914201114071, y_prev: 1360301884924, y: 1337507335012, lsp_prev: 115823083492531, lsp: 113882238532353, pn: 184145800019487655710125432360000, pd: 183796586505133177467207315362367},
                AmmStableSwapBacktestStepData { tag: 0, index: 10, x_prev: 9404914201114071, x: 10820444635037638, y_prev: 1337507335012, y: 1195629295060, lsp_prev: 113882238532353, lsp: 113882238532353, pn: 433521906031726788800739002900000, pd: 433305253405036475490202452050687},
                AmmStableSwapBacktestStepData { tag: 1, index: 11, x_prev: 10820444635037638, x: 11324679814418516, y_prev: 1195629295060, y: 1251345891965, lsp_prev: 113882238532353, lsp: 119189176732332, pn: 365282902122046363507583859337500, pd: 365100351946084201145114157027391},
                AmmStableSwapBacktestStepData { tag: 0, index: 11, x_prev: 11324679814418516, x: 9662633028835839, y_prev: 1251345891965, y: 1417960319440, lsp_prev: 119189176732332, lsp: 119189176732332, pn: 27583920505159062710189389090400000, pd: 27526115662268856783019840619356149},
                AmmStableSwapBacktestStepData { tag: 1, index: 12, x_prev: 9662633028835839, x: 9664576646847223, y_prev: 1417960319440, y: 1418245539132, lsp_prev: 119189176732332, lsp: 119213151380854, pn: 4725174403201262040238333020000, pd: 4715272331305615608444979012483},
                AmmStableSwapBacktestStepData { tag: 0, index: 12, x_prev: 9664576646847223, x: 10868591369141173, y_prev: 1418245539132, y: 1297497643138, lsp_prev: 119213151380854, lsp: 119213151380854, pn: 3781470832127689137576145890980000, pd: 3778070568616004155847413994780393},
                AmmStableSwapBacktestStepData { tag: 2, index: 13, x_prev: 10868591369141173, x: 10537830648092760, y_prev: 1297497643138, y: 1258011269843, lsp_prev: 119213151380854, lsp: 115585171767862, pn: 1333054578321337736254073645493250, pd: 1331855908004153205066601987551609},
                AmmStableSwapBacktestStepData { tag: 0, index: 13, x_prev: 10537830648092760, x: 11442404718298084, y_prev: 1258011269843, y: 1167465009611, lsp_prev: 115585171767862, lsp: 115585171767862, pn: 6713045734349078800829618037272500, pd: 6712374496899493604539575982558399},
                AmmStableSwapBacktestStepData { tag: 2, index: 14, x_prev: 11442404718298084, x: 11338322678624005, y_prev: 1167465009611, y: 1156845551339, lsp_prev: 115585171767862, lsp: 114533789586419, pn: 10546360296504674632729695987322000, pd: 10545305765928202246205726109228199},
                AmmStableSwapBacktestStepData { tag: 0, index: 14, x_prev: 11338322678624005, x: 9548400150994164, y_prev: 1156845551339, y: 1336159672632, lsp_prev: 114533789586419, lsp: 114533789586419, pn: 7132789409489310867464849580000, pd: 7119973457266377780123051473869},
                AmmStableSwapBacktestStepData { tag: 1, index: 15, x_prev: 9548400150994164, x: 9718514998506856, y_prev: 1336159672632, y: 1359964770383, lsp_prev: 114533789586419, lsp: 116574330184039, pn: 6650288834745641320553241091446250, pd: 6638339823064269255701837213567503},
                AmmStableSwapBacktestStepData { tag: 0, index: 15, x_prev: 9718514998506856, x: 9627239397149435, y_prev: 1359964770383, y: 1369125016376, lsp_prev: 116574330184039, lsp: 116574330184039, pn: 176875273327287051907745203056000, pd: 176539847616819194246717628257411},
                AmmStableSwapBacktestStepData { tag: 1, index: 16, x_prev: 9627239397149435, x: 9706834438789930, y_prev: 1369125016376, y: 1380444519111, lsp_prev: 116574330184039, lsp: 117538130738101, pn: 5394361915153070996174434208001000, pd: 5384132064231164142353768518333063},
                AmmStableSwapBacktestStepData { tag: 0, index: 16, x_prev: 9706834438789930, x: 11283731305782057, y_prev: 1380444519111, y: 1222409041424, lsp_prev: 117538130738101, lsp: 117538130738101, pn: 55461612115267782087194359442080000, pd: 55439436340732895038801988160615369},
                AmmStableSwapBacktestStepData { tag: 1, index: 17, x_prev: 11283731305782057, x: 11609377853338546, y_prev: 1222409041424, y: 1257687556416, lsp_prev: 117538130738101, lsp: 120930261004553, pn: 202444933519800065304343414080000, pd: 202363987924635690828785672405813},
                AmmStableSwapBacktestStepData { tag: 0, index: 17, x_prev: 11609377853338546, x: 10081658230340334, y_prev: 1257687556416, y: 1410781381972, lsp_prev: 120930261004553, lsp: 120930261004553, pn: 5725252141488332828692379660740000, pd: 5714965204121027382743338699227663},
                AmmStableSwapBacktestStepData { tag: 2, index: 18, x_prev: 10081658230340334, x: 9606892839707203, y_prev: 1410781381972, y: 1344344873354, lsp_prev: 120930261004553, lsp: 115235413858038, pn: 51987216998009631820867365966860000, pd: 51893808143352473124930905281242977},
                AmmStableSwapBacktestStepData { tag: 0, index: 18, x_prev: 9606892839707203, x: 9516665585720451, y_prev: 1344344873354, y: 1353399909196, lsp_prev: 115235413858038, lsp: 115235413858038, pn: 2592533979879081645466288025480000, pd: 2587617506616550691174731127389593},
                AmmStableSwapBacktestStepData { tag: 1, index: 19, x_prev: 9516665585720451, x: 9867868555315123, y_prev: 1353399909196, y: 1403345771313, lsp_prev: 115235413858038, lsp: 119488060878660, pn: 55748289622231013510079305633370000, pd: 55642568741622821560025631920688427},
                AmmStableSwapBacktestStepData { tag: 0, index: 19, x_prev: 9867868555315123, x: 9348609118645557, y_prev: 1403345771313, y: 1455490113295, lsp_prev: 119488060878660, lsp: 119488060878660, pn: 54809344843010647165409149104550000, pd: 54672663185049404396357490043464093},
                AmmStableSwapBacktestStepData { tag: 1, index: 20, x_prev: 9348609118645557, x: 9461860728026217, y_prev: 1455490113295, y: 1473122318864, lsp_prev: 119488060878660, lsp: 120935571949487, pn: 1145823249590442183868383019360000, pd: 1142965835002966048976710277601783},
                AmmStableSwapBacktestStepData { tag: 0, index: 20, x_prev: 9461860728026217, x: 9149649652055649, y_prev: 1473122318864, y: 1504502723312, lsp_prev: 120935571949487, lsp: 120935571949487, pn: 1733501321667690910660845330320000, pd: 1728488704424889428925667004096889},
                AmmStableSwapBacktestStepData { tag: 1, index: 21, x_prev: 9149649652055649, x: 9211069065009118, y_prev: 1504502723312, y: 1514602090781, lsp_prev: 120935571949487, lsp: 121747383561580, pn: 28109641535864532884422405106845000, pd: 28028359293912745719069472961399491},
                AmmStableSwapBacktestStepData { tag: 0, index: 21, x_prev: 9211069065009118, x: 10346705961179101, y_prev: 1514602090781, y: 1400556348748, lsp_prev: 121747383561580, lsp: 121747383561580, pn: 19440400043742685749748101703080000, pd: 19409345091596438940646196492412271},
                AmmStableSwapBacktestStepData { tag: 2, index: 22, x_prev: 10346705961179101, x: 10346658485710535, y_prev: 1400556348748, y: 1400549922349, lsp_prev: 121747383561580, lsp: 121746824928320, pn: 11664132984650237601071946148414000, pd: 11645500184355415120058240373460201},
                AmmStableSwapBacktestStepData { tag: 0, index: 22, x_prev: 10346658485710535, x: 9286906064109600, y_prev: 1400549922349, y: 1506966473657, lsp_prev: 121746824928320, lsp: 121746824928320, pn: 35244087725304609430638123310675, pd: 35145679821804148081927170783414},
                AmmStableSwapBacktestStepData { tag: 1, index: 23, x_prev: 9286906064109600, x: 9303366302339931, y_prev: 1506966473657, y: 1509637441468, lsp_prev: 121746824928320, lsp: 121962610651600, pn: 2263624489008835703601680032840000, pd: 2257304037703304909947642515005577},
                AmmStableSwapBacktestStepData { tag: 0, index: 23, x_prev: 9303366302339931, x: 9227352549165062, y_prev: 1509637441468, y: 1517279630052, lsp_prev: 121962610651600, lsp: 121962610651600, pn: 1128364591432972776695218362300000, pd: 1125101796223944766325136969644753},
                AmmStableSwapBacktestStepData { tag: 2, index: 24, x_prev: 9227352549165062, x: 8929587546034677, y_prev: 1517279630052, y: 1468317289946, lsp_prev: 121962610651600, lsp: 118026899194932, pn: 2113430720370583854469804131700000, pd: 2107319493838490132668709097928401},
                AmmStableSwapBacktestStepData { tag: 0, index: 24, x_prev: 8929587546034677, x: 10030520457670933, y_prev: 1468317289946, y: 1357756677430, lsp_prev: 118026899194932, lsp: 118026899194932, pn: 18270394259711653621090193835700000, pd: 18241208326390041059732784987482967},
                AmmStableSwapBacktestStepData { tag: 1, index: 25, x_prev: 10030520457670933, x: 10034254391664531, y_prev: 1357756677430, y: 1358262112201, lsp_prev: 118026899194932, lsp: 118070835564216, pn: 6856499761912611711109227987890000, pd: 6845546886893818138671310439615109},
                AmmStableSwapBacktestStepData { tag: 0, index: 25, x_prev: 10034254391664531, x: 10132780163618434, y_prev: 1358262112201, y: 1348379757024, lsp_prev: 118070835564216, lsp: 118070835564216, pn: 13745676009514728431227469250720000, pd: 13725088376949637636049483272399327},
                AmmStableSwapBacktestStepData { tag: 1, index: 26, x_prev: 10132780163618434, x: 10506455681123041, y_prev: 1348379757024, y: 1398105152756, lsp_prev: 118070835564216, lsp: 122425038445297, pn: 738909639749751780760049229760000, pd: 737802935346748804235368317330931},
                AmmStableSwapBacktestStepData { tag: 0, index: 26, x_prev: 10506455681123041, x: 9578394881837900, y_prev: 1398105152756, y: 1491265585589, lsp_prev: 122425038445297, lsp: 122425038445297, pn: 2627253430069752613699746211100, pd: 2620701675880106491995635316321},
                AmmStableSwapBacktestStepData { tag: 1, index: 27, x_prev: 9578394881837900, x: 9716359085502029, y_prev: 1491265585589, y: 1512745308602, lsp_prev: 122425038445297, lsp: 124188410403354, pn: 9867712108753630068463287096940000, pd: 9843104347884106261031254171994263},
                AmmStableSwapBacktestStepData { tag: 0, index: 27, x_prev: 9716359085502029, x: 9395750379488194, y_prev: 1512745308602, y: 1544969760707, lsp_prev: 124188410403354, lsp: 124188410403354, pn: 29248134445893123082667729773405000, pd: 29163560121541335693231224254568851},
                AmmStableSwapBacktestStepData { tag: 1, index: 28, x_prev: 9395750379488194, x: 9412539916872533, y_prev: 1544969760707, y: 1547730511739, lsp_prev: 124188410403354, lsp: 124410326256269, pn: 1223031521200801137088699869820000, pd: 1219494985742176357833988319674479},
                AmmStableSwapBacktestStepData { tag: 0, index: 28, x_prev: 9412539916872533, x: 10573016246060053, y_prev: 1547730511739, y: 1431190282622, lsp_prev: 124410326256269, lsp: 124410326256269, pn: 60900384822453970518652335563780000, pd: 60803099862675829740178340709514847},
                AmmStableSwapBacktestStepData { tag: 1, index: 29, x_prev: 10573016246060053, x: 10954500515414339, y_prev: 1431190282622, y: 1482828960419, lsp_prev: 124410326256269, lsp: 128899166650293, pn: 871658028673381642958647056030000, pd: 870265603707480396911526140151731},
                AmmStableSwapBacktestStepData { tag: 0, index: 29, x_prev: 10954500515414339, x: 9752153119899253, y_prev: 1482828960419, y: 1603574069499, lsp_prev: 128899166650293, lsp: 128899166650293, pn: 2520729478069468023721164394410000, pd: 2513440500617730435357110492980783},
                AmmStableSwapBacktestStepData { tag: 1, index: 30, x_prev: 9752153119899253, x: 9788693985053753, y_prev: 1603574069499, y: 1609582587117, lsp_prev: 128899166650293, lsp: 129382145845652, pn: 36074644616437458981487051665000, pd: 35970330657531467206622529717101},
                AmmStableSwapBacktestStepData { tag: 0, index: 30, x_prev: 9788693985053753, x: 9632861185669005, y_prev: 1609582587117, y: 1625253555421, lsp_prev: 129382145845652, lsp: 129382145845652, pn: 2719920637276627086554181091000, pd: 2711514940959725133928067785173},
                AmmStableSwapBacktestStepData { tag: 2, index: 31, x_prev: 9632861185669005, x: 9361713360709318, y_prev: 1625253555421, y: 1579505572754, lsp_prev: 129382145845652, lsp: 125740269692920, pn: 29799865019443585628590847563330000, pd: 29707770929562670003398396448684111},
                AmmStableSwapBacktestStepData { tag: 0, index: 31, x_prev: 9361713360709318, x: 10583268617907494, y_prev: 1579505572754, y: 1456799952215, lsp_prev: 125740269692920, lsp: 125740269692920, pn: 940240169165080741060328355075000, pd: 938644473560053997497466210792387},
                AmmStableSwapBacktestStepData { tag: 1, index: 32, x_prev: 10583268617907494, x: 10933336972071320, y_prev: 1456799952215, y: 1504987292065, lsp_prev: 125740269692920, lsp: 129899446867057, pn: 1655726401985962966339888326338750, pd: 1652916444031156464464022353768861},
                AmmStableSwapBacktestStepData { tag: 0, index: 32, x_prev: 10933336972071320, x: 10829397181054226, y_prev: 1504987292065, y: 1515416568579, lsp_prev: 129899446867057, lsp: 129899446867057, pn: 33030051081666899363566350640965000, pd: 32970703814800942454380111638011171},
                AmmStableSwapBacktestStepData { tag: 1, index: 33, x_prev: 10829397181054226, x: 10957335837300471, y_prev: 1515416568579, y: 1533319722023, lsp_prev: 129899446867057, lsp: 131434080826963, pn: 16907548063713488561069993434330000, pd: 16877169159227223027174404458513941},
                AmmStableSwapBacktestStepData { tag: 0, index: 33, x_prev: 10957335837300471, x: 11062503574518908, y_prev: 1533319722023, y: 1522767233885, lsp_prev: 131434080826963, lsp: 131434080826963, pn: 35314146770873481760074908262500, pd: 35254214606043955123613319023581},
                AmmStableSwapBacktestStepData { tag: 2, index: 34, x_prev: 11062503574518908, x: 10822762917125438, y_prev: 1522767233885, y: 1489766637298, lsp_prev: 131434080826963, lsp: 128585711763929, pn: 6489621804135462285429082230590000, pd: 6478608170246172067220174724539669},
                AmmStableSwapBacktestStepData { tag: 0, index: 34, x_prev: 10822762917125438, x: 9650115787972558, y_prev: 1489766637298, y: 1607550151820, lsp_prev: 128585711763929, lsp: 128585711763929, pn: 6252002844073888299076039198100000, pd: 6233302935268223180461235436099629},
                AmmStableSwapBacktestStepData { tag: 2, index: 35, x_prev: 9650115787972558, x: 9579431048973768, y_prev: 1607550151820, y: 1595775239954, lsp_prev: 128585711763929, lsp: 127643852860398, pn: 3850468432484279748321745102757500, pd: 3838951577751095280277173512127519},
                AmmStableSwapBacktestStepData { tag: 0, index: 35, x_prev: 9579431048973768, x: 10847817625865671, y_prev: 1595775239954, y: 1468388094043, lsp_prev: 127643852860398, lsp: 127643852860398, pn: 21369075501789956328159301393890000, pd: 21334939598432864286562691047722433},
                AmmStableSwapBacktestStepData { tag: 2, index: 36, x_prev: 10847817625865671, x: 10620034460742953, y_prev: 1468388094043, y: 1437554787361, lsp_prev: 127643852860398, lsp: 124963579111725, pn: 7680404666494315953661186725310000, pd: 7668135649455328740474354002481913},
                AmmStableSwapBacktestStepData { tag: 0, index: 36, x_prev: 10620034460742953, x: 10724311973819560, y_prev: 1437554787361, y: 1427095519691, lsp_prev: 124963579111725, lsp: 124963579111725, pn: 769870617906429023983545042592750, pd: 768717541594054979577796502033209},
                AmmStableSwapBacktestStepData { tag: 1, index: 37, x_prev: 10724311973819560, x: 11137956636799502, y_prev: 1427095519691, y: 1482139651820, lsp_prev: 124963579111725, lsp: 129783516996081, pn: 11072065559161826742293744804900000, pd: 11055482335658597072473105198703689},
                AmmStableSwapBacktestStepData { tag: 0, index: 37, x_prev: 11137956636799502, x: 9982721972172510, y_prev: 1482139651820, y: 1598123287989, lsp_prev: 129783516996081, lsp: 129783516996081, pn: 238057752009897268951337956419000, pd: 237416726847414453628241687135621},
                AmmStableSwapBacktestStepData { tag: 2, index: 38, x_prev: 9982721972172510, x: 9689049815239578, y_prev: 1598123287989, y: 1551109626351, lsp_prev: 129783516996081, lsp: 125965539747308, pn: 3363860779352166957023085257295000, pd: 3354802811760483134473319596530601},
                AmmStableSwapBacktestStepData { tag: 0, index: 38, x_prev: 9689049815239578, x: 10402808277158809, y_prev: 1551109626351, y: 1479421510703, lsp_prev: 125965539747308, lsp: 125965539747308, pn: 12391275721502198869386060490090000, pd: 12367776945306356122215554985158647},
                AmmStableSwapBacktestStepData { tag: 1, index: 39, x_prev: 10402808277158809, x: 10673580445012023, y_prev: 1479421510703, y: 1517929013576, lsp_prev: 125965539747308, lsp: 129244266160730, pn: 100498688526406543310415906640000, pd: 100308103130460677016668652626847},
                AmmStableSwapBacktestStepData { tag: 0, index: 39, x_prev: 10673580445012023, x: 9858814469036824, y_prev: 1517929013576, y: 1599768832837, lsp_prev: 129244266160730, lsp: 129244266160730, pn: 1323952185831824677611501272248750, pd: 1320255470514403554961849388687281},
                AmmStableSwapBacktestStepData { tag: 1, index: 40, x_prev: 9858814469036824, x: 9899376686303654, y_prev: 1599768832837, y: 1606350777469, lsp_prev: 129244266160730, lsp: 129776017115256, pn: 32036853505763630304436435733755000, pd: 31947400783570127389431861681137233},
                AmmStableSwapBacktestStepData { tag: 0, index: 40, x_prev: 9899376686303654, x: 9586664248358371, y_prev: 1606350777469, y: 1637797848788, lsp_prev: 129776017115256, lsp: 129776017115256, pn: 3164546973802894183466002146520000, pd: 3154452725082707270851015923532789},
                AmmStableSwapBacktestStepData { tag: 1, index: 41, x_prev: 9586664248358371, x: 9679654994536162, y_prev: 1637797848788, y: 1653684505513, lsp_prev: 129776017115256, lsp: 131034845875198, pn: 672132709574882825756946022835000, pd: 669988745589013032703934668901529},
                AmmStableSwapBacktestStepData { tag: 0, index: 41, x_prev: 9679654994536162, x: 10527014792334946, y_prev: 1653684505513, y: 1568518881436, lsp_prev: 131034845875198, lsp: 131034845875198, pn: 5540927094844591497545290924820000, pd: 5528763814452949803635715464705527},
                AmmStableSwapBacktestStepData { tag: 1, index: 42, x_prev: 10527014792334946, x: 10938860563573088, y_prev: 1568518881436, y: 1629883653992, lsp_prev: 131034845875198, lsp: 136161289432375, pn: 747870074328531681266090909552500, pd: 746228371910350175404085890169611},
                AmmStableSwapBacktestStepData { tag: 0, index: 42, x_prev: 10938860563573088, x: 10653103436753453, y_prev: 1629883653992, y: 1658587553650, lsp_prev: 136161289432375, lsp: 136161289432375, pn: 1617559329584936491059945935500000, pd: 1613525515795473361159810159828231},
                AmmStableSwapBacktestStepData { tag: 1, index: 43, x_prev: 10653103436753453, x: 10924598911551951, y_prev: 1658587553650, y: 1700856833963, lsp_prev: 136161289432375, lsp: 139631374383958, pn: 74846519552516534432217804640990000, pd: 74659869877823204813563421642041623},
                AmmStableSwapBacktestStepData { tag: 0, index: 43, x_prev: 10924598911551951, x: 11319876241970360, y_prev: 1700856833963, y: 1661155430841, lsp_prev: 139631374383958, lsp: 139631374383958, pn: 1892859514547573315083365058857750, pd: 1888892839584492823172437216447669},
                AmmStableSwapBacktestStepData { tag: 1, index: 44, x_prev: 11319876241970360, x: 11781531103117177, y_prev: 1661155430841, y: 1728901796912, lsp_prev: 139631374383958, lsp: 145325915682377, pn: 2050399527122308550526887540960000, pd: 2046102711428360715037494138174551},
                AmmStableSwapBacktestStepData { tag: 0, index: 44, x_prev: 11781531103117177, x: 12231747288022904, y_prev: 1728901796912, y: 1683715070274, lsp_prev: 145325915682377, lsp: 145325915682377, pn: 1036167845256197492364062817802500, pd: 1034409349362298698599883800860799},
                AmmStableSwapBacktestStepData { tag: 2, index: 45, x_prev: 12231747288022904, x: 11867990210042809, y_prev: 1683715070274, y: 1633643460741, lsp_prev: 145325915682377, lsp: 141004102191743, pn: 19509110373350730165736309321830000, pd: 19476001171359730612020018453768367},
                AmmStableSwapBacktestStepData { tag: 0, index: 45, x_prev: 11867990210042809, x: 10180729049081585, y_prev: 1633643460741, y: 1803181162679, lsp_prev: 141004102191743, lsp: 141004102191743, pn: 4934917593902816637139021218258000, pd: 4917705624218185507577599774743667},
                AmmStableSwapBacktestStepData { tag: 2, index: 46, x_prev: 10180729049081585, x: 9845000877082395, y_prev: 1803181162679, y: 1743717963864, lsp_prev: 141004102191743, lsp: 136354233872392, pn: 512756477478273454221218347792000, pd: 510968089166204914919711852584381},
                AmmStableSwapBacktestStepData { tag: 0, index: 46, x_prev: 9845000877082395, x: 11476621513431148, y_prev: 1743717963864, y: 1579771077916, lsp_prev: 136354233872392, lsp: 136354233872392, pn: 1520302394634185219028664085290000, pd: 1517722266780682559322481448608237},
                AmmStableSwapBacktestStepData { tag: 2, index: 47, x_prev: 11476621513431148, x: 11304822532540707, y_prev: 1579771077916, y: 1556122736729, lsp_prev: 136354233872392, lsp: 134313082790433, pn: 7080608732048131879561468461670000, pd: 7068592125435000589630033681578501},
                AmmStableSwapBacktestStepData { tag: 0, index: 47, x_prev: 11304822532540707, x: 9770692430841995, y_prev: 1556122736729, y: 1710262115613, lsp_prev: 134313082790433, lsp: 134313082790433, pn: 1347486196660353862067373596838000, pd: 1342920267750025231454445741889337},
                AmmStableSwapBacktestStepData { tag: 2, index: 48, x_prev: 9770692430841995, x: 9710611114143391, y_prev: 1710262115613, y: 1699745481247, lsp_prev: 134313082790433, lsp: 133487173376027, pn: 22182756597350530009708438858310000, pd: 22107590788669318562040301668941143},
                AmmStableSwapBacktestStepData { tag: 0, index: 48, x_prev: 9710611114143391, x: 9784866807719454, y_prev: 1699745481247, y: 1692273694930, lsp_prev: 133487173376027, lsp: 133487173376027, pn: 33377625249346434094020922298450000, pd: 33267841372816791042763002048653091},
                AmmStableSwapBacktestStepData { tag: 2, index: 49, x_prev: 9784866807719454, x: 9731592769335723, y_prev: 1692273694930, y: 1683060053544, lsp_prev: 133487173376027, lsp: 132760397944341, pn: 815189220758763840235315271120000, pd: 812507944541790503292819614989479},
                AmmStableSwapBacktestStepData { tag: 0, index: 49, x_prev: 9731592769335723, x: 11174136628638122, y_prev: 1683060053544, y: 1538133661191, lsp_prev: 132760397944341, lsp: 132760397944341, pn: 34589242982761973811090877737705000, pd: 34530541062956060173548010916198111},
                AmmStableSwapBacktestStepData { tag: 1, index: 50, x_prev: 11174136628638122, x: 11568152147298524, y_prev: 1538133661191, y: 1592370382329, lsp_prev: 132760397944341, lsp: 137441713270273, pn: 13127329736969876832198022582500, pd: 13105051150015263312854212760087},
                AmmStableSwapBacktestStepData { tag: 0, index: 50, x_prev: 11568152147298524, x: 10232918432475074, y_prev: 1592370382329, y: 1726495040692, lsp_prev: 137441713270273, lsp: 137441713270273, pn: 1424172624886870401241585493620000, pd: 1419771333752264038242709479232381},
                AmmStableSwapBacktestStepData { tag: 2, index: 51, x_prev: 10232918432475074, x: 9897321548930022, y_prev: 1726495040692, y: 1669873231486, lsp_prev: 137441713270273, lsp: 132934200487193, pn: 33307265407920956504475483260270000, pd: 33204331978787191314506097815746479},
                AmmStableSwapBacktestStepData { tag: 0, index: 51, x_prev: 9897321548930022, x: 11408346721115109, y_prev: 1669873231486, y: 1518120745885, lsp_prev: 132934200487193, lsp: 132934200487193, pn: 69697030824409426957035395129650000, pd: 69592641861618206934308349104803581},
                AmmStableSwapBacktestStepData { tag: 1, index: 52, x_prev: 11408346721115109, x: 11666925923296840, y_prev: 1518120745885, y: 1552530153390, lsp_prev: 132934200487193, lsp: 135947259289215, pn: 911153918851359629639390473402500, pd: 909789234998877497421141549632879},
                AmmStableSwapBacktestStepData { tag: 0, index: 52, x_prev: 11666925923296840, x: 10202586082127904, y_prev: 1552530153390, y: 1699582592130, lsp_prev: 135947259289215, lsp: 135947259289215, pn: 242651045005085264025074823259375, pd: 241925269197498672167624255233567},
                AmmStableSwapBacktestStepData { tag: 1, index: 53, x_prev: 10202586082127904, x: 10243632748585992, y_prev: 1699582592130, y: 1706420289868, lsp_prev: 135947259289215, lsp: 136494197267776, pn: 1403996681885814461593062430000, pd: 1399797290015802264952974064017},
                AmmStableSwapBacktestStepData { tag: 0, index: 53, x_prev: 10243632748585992, x: 11599964477523720, y_prev: 1706420289868, y: 1570200598643, lsp_prev: 136494197267776, lsp: 136494197267776, pn: 1832633263803513108793233779007250, pd: 1829705734628150797408479586865379},
                AmmStableSwapBacktestStepData { tag: 1, index: 54, x_prev: 11599964477523720, x: 11859461960614609, y_prev: 1570200598643, y: 1605326835804, lsp_prev: 136494197267776, lsp: 139547646329295, pn: 15324355077153294854954059243080000, pd: 15299875276710909720794178125688563},
                AmmStableSwapBacktestStepData { tag: 0, index: 54, x_prev: 11859461960614609, x: 11975909341650693, y_prev: 1605326835804, y: 1593646903173, lsp_prev: 139547646329295, lsp: 139547646329295, pn: 4266908676676092521302404989670000, pd: 4260517899826384639258044913072847},
                AmmStableSwapBacktestStepData { tag: 1, index: 55, x_prev: 11975909341650693, x: 12427490317108094, y_prev: 1593646903173, y: 1653739260466, lsp_prev: 139547646329295, lsp: 144809631908367, pn: 10338219133669189317003331957510000, pd: 10322735031122589768582018642991609},
                AmmStableSwapBacktestStepData { tag: 0, index: 55, x_prev: 12427490317108094, x: 10867690476378920, y_prev: 1653739260466, y: 1810378016086, lsp_prev: 144809631908367, lsp: 144809631908367, pn: 116605685677988792344722440015500, pd: 116256914933192117729724611345341},
                AmmStableSwapBacktestStepData { tag: 2, index: 56, x_prev: 10867690476378920, x: 10544503024060557, y_prev: 1810378016086, y: 1756540316161, lsp_prev: 144809631908367, lsp: 140503228803738, pn: 37322983606021074436770876344690000, pd: 37211349557349847505503870239220953},
                AmmStableSwapBacktestStepData { tag: 0, index: 56, x_prev: 10544503024060557, x: 10299157178409472, y_prev: 1756540316161, y: 1781219214882, lsp_prev: 140503228803738, lsp: 140503228803738, pn: 2311154543135189888850352233886875, pd: 2303552818833086839736501269298864},
                AmmStableSwapBacktestStepData { tag: 1, index: 57, x_prev: 10299157178409472, x: 10720488287866754, y_prev: 1781219214882, y: 1854087611295, lsp_prev: 140503228803738, lsp: 146251114795659, pn: 10016471036066119943626412990475000, pd: 9983525402238917370964472247563657},
                AmmStableSwapBacktestStepData { tag: 0, index: 57, x_prev: 10720488287866754, x: 10559572024637120, y_prev: 1854087611295, y: 1870280730290, lsp_prev: 146251114795659, lsp: 146251114795659, pn: 33181406982832679230117958224375, pd: 33065677112937943562927154610122},
                AmmStableSwapBacktestStepData { tag: 1, index: 58, x_prev: 10559572024637120, x: 10841090054500131, y_prev: 1870280730290, y: 1920142386165, lsp_prev: 146251114795659, lsp: 150150167295738, pn: 9326459317229856332785649902650000, pd: 9293930560269077014026983555124271},
                AmmStableSwapBacktestStepData { tag: 0, index: 58, x_prev: 10841090054500131, x: 12400085025632034, y_prev: 1920142386165, y: 1763461560831, lsp_prev: 150150167295738, lsp: 150150167295738, pn: 1222648630176954372330642442255000, pd: 1220330003170954032030329847329157},
                AmmStableSwapBacktestStepData { tag: 1, index: 59, x_prev: 12400085025632034, x: 12854601296702286, y_prev: 1763461560831, y: 1828099986386, lsp_prev: 150150167295738, lsp: 155653814569025, pn: 23650594744612973644017578763910000, pd: 23605743831333910317248361084528441},
                AmmStableSwapBacktestStepData { tag: 0, index: 59, x_prev: 12854601296702286, x: 13228245272955280, y_prev: 1828099986386, y: 1790608814953, lsp_prev: 155653814569025, lsp: 155653814569025, pn: 49650712694714409449805532471125, pd: 49571398457184004653375651379093},
                AmmStableSwapBacktestStepData { tag: 2, index: 60, x_prev: 13228245272955280, x: 13121539604784253, y_prev: 1790608814953, y: 1776164865201, lsp_prev: 155653814569025, lsp: 154398232748138, pn: 93797622209794634852924154306870000, pd: 93647785752592479246087593545931011},
                AmmStableSwapBacktestStepData { tag: 0, index: 60, x_prev: 13121539604784253, x: 11976814473719855, y_prev: 1776164865201, y: 1891095293452, lsp_prev: 154398232748138, lsp: 154398232748138, pn: 18248498588576096128414975679848000, pd: 18201175532192737030611953502249277},
                AmmStableSwapBacktestStepData { tag: 1, index: 61, x_prev: 11976814473719855, x: 12292053015932016, y_prev: 1891095293452, y: 1940870308737, lsp_prev: 154398232748138, lsp: 158462107488671, pn: 667422518715058361529850490848125, pd: 665691720242439926610492283816411},
                AmmStableSwapBacktestStepData { tag: 0, index: 61, x_prev: 12292053015932016, x: 13337390268165231, y_prev: 1940870308737, y: 1835908187429, lsp_prev: 158462107488671, lsp: 158462107488671, pn: 98556396706412789481679915757110000, pd: 98389135176613958305430131319882829},
                AmmStableSwapBacktestStepData { tag: 2, index: 62, x_prev: 13337390268165231, x: 13079799679507463, y_prev: 1835908187429, y: 1800450525832, lsp_prev: 158462107488671, lsp: 155401662624477, pn: 1934413006873747045390166729840000, pd: 1931130085728034330468279349074781},
                AmmStableSwapBacktestStepData { tag: 0, index: 62, x_prev: 13079799679507463, x: 13468806143828667, y_prev: 1800450525832, y: 1761432422201, lsp_prev: 155401662624477, lsp: 155401662624477, pn: 47732327510870717923064344774910000, pd: 47665595676923265380700455803503297},
                AmmStableSwapBacktestStepData { tag: 1, index: 63, x_prev: 13468806143828667, x: 13679509817591009, y_prev: 1761432422201, y: 1788987966358, lsp_prev: 155401662624477, lsp: 157832739356439, pn: 19694976625126793375547532984660000, pd: 19667442206038454923940048966232163},
                AmmStableSwapBacktestStepData { tag: 0, index: 63, x_prev: 13679509817591009, x: 12456535558728869, y_prev: 1788987966358, y: 1911729962055, lsp_prev: 157832739356439, lsp: 157832739356439, pn: 19182645764362529380867483964850000, pd: 19136717642022061915500420497478383},
                AmmStableSwapBacktestStepData { tag: 2, index: 64, x_prev: 12456535558728869, x: 12267956667587707, y_prev: 1911729962055, y: 1882788374348, lsp_prev: 157832739356439, lsp: 155443317126375, pn: 46515579738815503710446549251720000, pd: 46404209635690681674258685932896173},
                AmmStableSwapBacktestStepData { tag: 0, index: 64, x_prev: 12267956667587707, x: 13744845920672890, y_prev: 1882788374348, y: 1734592196034, lsp_prev: 155443317126375, lsp: 155443317126375, pn: 479602949876091039379910931702000, pd: 479028116136732926954459526818267},
                AmmStableSwapBacktestStepData { tag: 2, index: 65, x_prev: 13744845920672890, x: 13327261419691473, y_prev: 1734592196034, y: 1681893255590, lsp_prev: 155443317126375, lsp: 150720767278400, pn: 45090383329292229200175433216100000, pd: 45036339721626820479326888592891567},
                AmmStableSwapBacktestStepData { tag: 0, index: 65, x_prev: 13327261419691473, x: 12000663991663939, y_prev: 1681893255590, y: 1814997516618, lsp_prev: 150720767278400, lsp: 150720767278400, pn: 43859409504773900572615915340220000, pd: 43758764346777110352393111672009581},
                AmmStableSwapBacktestStepData { tag: 2, index: 66, x_prev: 12000663991663939, x: 11821171727151354, y_prev: 1814997516618, y: 1787850850853, lsp_prev: 150720767278400, lsp: 148466457696308, pn: 4255722299976964792144238519885000, pd: 4245956599797504323815444952131473},
                AmmStableSwapBacktestStepData { tag: 0, index: 66, x_prev: 11821171727151354, x: 13127927421721813, y_prev: 1787850850853, y: 1656737411769, lsp_prev: 148466457696308, lsp: 148466457696308, pn: 17500659677441125682293813372290000, pd: 17479684056573624988699604243928713},
                AmmStableSwapBacktestStepData { tag: 1, index: 67, x_prev: 13127927421721813, x: 13618008977782803, y_prev: 1656737411769, y: 1718585441748, lsp_prev: 148466457696308, lsp: 154008891796766, pn: 10462050514163764124829313629480000, pd: 10449511100842993123231671439378103},
                AmmStableSwapBacktestStepData { tag: 0, index: 67, x_prev: 13618008977782803, x: 12372692708364834, y_prev: 1718585441748, y: 1843523782396, lsp_prev: 154008891796766, lsp: 154008891796766, pn: 4592526527063159193851690328980000, pd: 4582445147738219287952375162366847},
                AmmStableSwapBacktestStepData { tag: 1, index: 68, x_prev: 12372692708364834, x: 12704605342319795, y_prev: 1843523782396, y: 1892978565506, lsp_prev: 154008891796766, lsp: 158140368924170, pn: 3228154545630996621941128050076000, pd: 3221068195600729397459675726451657},
                AmmStableSwapBacktestStepData { tag: 0, index: 68, x_prev: 12704605342319795, x: 13983328745735346, y_prev: 1892978565506, y: 1764688600865, lsp_prev: 158140368924170, lsp: 158140368924170, pn: 49639023562107193664066130919325000, pd: 49579528128354611515475551956941073},
                AmmStableSwapBacktestStepData { tag: 2, index: 69, x_prev: 13983328745735346, x: 13575350938166016, y_prev: 1764688600865, y: 1713202019987, lsp_prev: 158140368924170, lsp: 153526463167176, pn: 731011570259124515452480656633125, pd: 730135407769819879059613033452624},
                AmmStableSwapBacktestStepData { tag: 0, index: 69, x_prev: 13575350938166016, x: 13713572817740543, y_prev: 1713202019987, y: 1699348570886, lsp_prev: 153526463167176, lsp: 153526463167176, pn: 31250091555065141677462484888180000, pd: 31215754225417473552872589740152509},
                AmmStableSwapBacktestStepData { tag: 1, index: 70, x_prev: 13713572817740543, x: 14192118990397558, y_prev: 1699348570886, y: 1758648708452, lsp_prev: 153526463167176, lsp: 158883892797437, pn: 50203709366335617631414722967420000, pd: 50148545965773669321745536005274793},
                AmmStableSwapBacktestStepData { tag: 0, index: 70, x_prev: 14192118990397558, x: 14485349023735925, y_prev: 1758648708452, y: 1729267904184, lsp_prev: 158883892797437, lsp: 158883892797437, pn: 4030170425905131089280804029942400, pd: 4026546534024562149041119201180783},
                AmmStableSwapBacktestStepData { tag: 2, index: 71, x_prev: 14485349023735925, x: 13980421507470322, y_prev: 1729267904184, y: 1668989415459, lsp_prev: 158883892797437, lsp: 153345548555033, pn: 9385253844102845188258684249095000, pd: 9376814710863166530564573599058241},
                AmmStableSwapBacktestStepData { tag: 0, index: 71, x_prev: 13980421507470322, x: 13290600831633931, y_prev: 1668989415459, y: 1738126970224, lsp_prev: 153345548555033, lsp: 153345548555033, pn: 6197012517522209093127641672480000, pd: 6188348829161510999945673735476977},
                AmmStableSwapBacktestStepData { tag: 2, index: 72, x_prev: 13290600831633931, x: 13282881643138328, y_prev: 1738126970224, y: 1737117465095, lsp_prev: 153345548555033, lsp: 153256485373522, pn: 967158773623867937061154465793750, pd: 965806644321836059514866163120103},
                AmmStableSwapBacktestStepData { tag: 0, index: 72, x_prev: 13282881643138328, x: 14263453047872712, y_prev: 1737117465095, y: 1638858870493, lsp_prev: 153256485373522, lsp: 153256485373522, pn: 2937821317219013199655869251716250, pd: 2935766280822479024731695725297529},
                AmmStableSwapBacktestStepData { tag: 2, index: 73, x_prev: 14263453047872712, x: 13815863818040290, y_prev: 1638858870493, y: 1587431240930, lsp_prev: 153256485373522, lsp: 148447274586700, pn: 1102534283882068541471835063310000, pd: 1101763049747257850133754047500743},
                AmmStableSwapBacktestStepData { tag: 0, index: 73, x_prev: 13815863818040290, x: 12994934542407892, y_prev: 1587431240930, y: 1669685224709, lsp_prev: 148447274586700, lsp: 148447274586700, pn: 21825254747475504807150276044832500, pd: 21796918753096836691737182152325501},
                AmmStableSwapBacktestStepData { tag: 2, index: 74, x_prev: 12994934542407892, x: 12630224001599323, y_prev: 1669685224709, y: 1622824519156, lsp_prev: 148447274586700, lsp: 144281013831835, pn: 9163274927231136095594347340440000, pd: 9151378135654907123410193170261377},
                AmmStableSwapBacktestStepData { tag: 0, index: 74, x_prev: 12630224001599323, x: 14138504953371879, y_prev: 1622824519156, y: 1471776652181, lsp_prev: 144281013831835, lsp: 144281013831835, pn: 41829961996271660965293448775570000, pd: 41821597676736851558872061719488063},
                AmmStableSwapBacktestStepData { tag: 1, index: 75, x_prev: 14138504953371879, x: 14489456549800733, y_prev: 1471776652181, y: 1508309677941, lsp_prev: 144281013831835, lsp: 147862414574391, pn: 87864751027505057834362129815930000, pd: 87847181591187954733598871623182609},
                AmmStableSwapBacktestStepData { tag: 0, index: 75, x_prev: 14489456549800733, x: 12566092852034215, y_prev: 1508309677941, y: 1700978184641, lsp_prev: 147862414574391, lsp: 147862414574391, pn: 8602462076143593293608955798534000, pd: 8588720123945453522420785040512841},
                AmmStableSwapBacktestStepData { tag: 1, index: 76, x_prev: 12566092852034215, x: 13028864348051008, y_prev: 1700978184641, y: 1763620107510, lsp_prev: 147862414574391, lsp: 153307743651865, pn: 361239637089746413701458380584375, pd: 360662576966606757413416345792378},
                AmmStableSwapBacktestStepData { tag: 0, index: 76, x_prev: 13028864348051008, x: 15176767248801255, y_prev: 1763620107510, y: 1548480862039, lsp_prev: 153307743651865, lsp: 153307743651865, pn: 9447861782992393974458080462738000, pd: 9446917091283403326306971943076221},
                AmmStableSwapBacktestStepData { tag: 2, index: 77, x_prev: 15176767248801255, x: 14644695574323959, y_prev: 1548480862039, y: 1494193753879, lsp_prev: 153307743651865, lsp: 147933034628662, pn: 21992555096785546820337084208910000, pd: 21990356061179718841974571481753111},
                AmmStableSwapBacktestStepData { tag: 0, index: 77, x_prev: 14644695574323959, x: 14496376808826696, y_prev: 1494193753879, y: 1509030056488, lsp_prev: 147933034628662, lsp: 147933034628662, pn: 10993587578420067164487611797370000, pd: 10991389300560113536699088836610829},
                AmmStableSwapBacktestStepData { tag: 1, index: 78, x_prev: 14496376808826696, x: 14838144981152371, y_prev: 1509030056488, y: 1544607114893, lsp_prev: 147933034628662, lsp: 151420720106094, pn: 92144561871031624364116059560030000, pd: 92126136643704250015233076569176141},
                AmmStableSwapBacktestStepData { tag: 0, index: 78, x_prev: 14838144981152371, x: 13525479767184884, y_prev: 1544607114893, y: 1676040592656, lsp_prev: 151420720106094, lsp: 151420720106094, pn: 22799046362744826990993604180440000, pd: 22773994968280125335006787172668691},
                AmmStableSwapBacktestStepData { tag: 1, index: 79, x_prev: 13525479767184884, x: 13549275467904096, y_prev: 1676040592656, y: 1678989291040, lsp_prev: 151420720106094, lsp: 151687118208058, pn: 571983468705105047250814452550000, pd: 571354978229063795082190279859397},
                AmmStableSwapBacktestStepData { tag: 0, index: 79, x_prev: 13549275467904096, x: 15925732806720847, y_prev: 1678989291040, y: 1441207731415, lsp_prev: 151687118208058, lsp: 151687118208058, pn: 5124919058179901965428895067450000, pd: 5127482799579709133451928618054841},
                AmmStableSwapBacktestStepData { tag: 1, index: 80, x_prev: 15925732806720847, x: 16162291958171800, y_prev: 1441207731415, y: 1462615278694, lsp_prev: 151687118208058, lsp: 153940262625652, pn: 39587248670575449687436886037300, pd: 39607052196673881262559404133981},
                AmmStableSwapBacktestStepData { tag: 0, index: 80, x_prev: 16162291958171800, x: 16462436082638413, y_prev: 1462615278694, y: 1432636545062, lsp_prev: 153940262625652, lsp: 153940262625652, pn: 94784055502288297218184929615860000, pd: 94850450817862874317314430430181239},
                AmmStableSwapBacktestStepData { tag: 2, index: 81, x_prev: 16462436082638413, x: 16408609077032501, y_prev: 1432636545062, y: 1427952272640, lsp_prev: 153940262625652, lsp: 153436926221627, pn: 94165240524248706952333063718400000, pd: 94231202365906871376980685761022631},
                AmmStableSwapBacktestStepData { tag: 0, index: 81, x_prev: 16408609077032501, x: 16109446329800979, y_prev: 1427952272640, y: 1457832985208, lsp_prev: 153436926221627, lsp: 153436926221627, pn: 23597277662399528876270572266640000, pd: 23609082203501758116734995161939357},
                AmmStableSwapBacktestStepData { tag: 2, index: 82, x_prev: 16109446329800979, x: 15666584542534660, y_prev: 1457832985208, y: 1417755970260, lsp_prev: 153436926221627, lsp: 149218820273848, pn: 4554631521794572057048215330000, pd: 4556909976783054327633499924153},
                AmmStableSwapBacktestStepData { tag: 0, index: 82, x_prev: 15666584542534660, x: 13887670930538879, y_prev: 1417755970260, y: 1595681818323, lsp_prev: 149218820273848, lsp: 149218820273848, pn: 89121982153171369914826098468630000, pd: 89059640404889352512121295582439899},
                AmmStableSwapBacktestStepData { tag: 2, index: 83, x_prev: 13887670930538879, x: 13635258037577540, y_prev: 1595681818323, y: 1566679787240, lsp_prev: 149218820273848, lsp: 146506720145757, pn: 715931512048348293005783888740000, pd: 715430710550972075329247017969529},
                AmmStableSwapBacktestStepData { tag: 0, index: 83, x_prev: 13635258037577540, x: 13777009661781827, y_prev: 1566679787240, y: 1552486361095, lsp_prev: 146506720145757, lsp: 146506720145757, pn: 43006297189239002232748801181650000, pd: 42980508883909430397598821825924289},
                AmmStableSwapBacktestStepData { tag: 1, index: 84, x_prev: 13777009661781827, x: 13971532579860609, y_prev: 1552486361095, y: 1574406515370, lsp_prev: 146506720145757, lsp: 148575305086928, pn: 126009446791484588881737126100000, pd: 125933886459611187584698970674677},
                AmmStableSwapBacktestStepData { tag: 0, index: 84, x_prev: 13971532579860609, x: 15744586404821344, y_prev: 1574406515370, y: 1397101194858, lsp_prev: 148575305086928, lsp: 148575305086928, pn: 2762662824990991473549173520223125, pd: 2764321417841738368673157648128411},
                AmmStableSwapBacktestStepData { tag: 2, index: 85, x_prev: 15744586404821344, x: 15325216712036212, y_prev: 1397101194858, y: 1359888283461, lsp_prev: 148575305086928, lsp: 144617882614993, pn: 20939610863154456518574874043197500, pd: 20952182172458186979863369615026567},
                AmmStableSwapBacktestStepData { tag: 0, index: 85, x_prev: 15325216712036212, x: 16268284868677491, y_prev: 1359888283461, y: 1265756884288, lsp_prev: 144617882614993, lsp: 144617882614993, pn: 6364949969613145474332883630720000, pd: 6373235175341237047040213693497479},
                AmmStableSwapBacktestStepData { tag: 1, index: 86, x_prev: 16268284868677491, x: 16825263703098719, y_prev: 1265756884288, y: 1309092724529, lsp_prev: 144617882614993, lsp: 149569178977530, pn: 5900479552828648278291617827770000, pd: 5908160161038146318292086690117287},
                AmmStableSwapBacktestStepData { tag: 0, index: 86, x_prev: 16825263703098719, x: 16280018014560571, y_prev: 1309092724529, y: 1363499605466, lsp_prev: 149569178977530, lsp: 149569178977530, pn: 17841086235005053813773520200940000, pd: 17857157676914655260166642773716009},
                AmmStableSwapBacktestStepData { tag: 1, index: 87, x_prev: 16280018014560571, x: 16576471896474043, y_prev: 1363499605466, y: 1388328493903, lsp_prev: 149569178977530, lsp: 152292785529024, pn: 3853492305270725537075577778870000, pd: 3856963572486037466920214866023797},
                AmmStableSwapBacktestStepData { tag: 0, index: 87, x_prev: 16576471896474043, x: 17131646333320373, y_prev: 1388328493903, y: 1332930881195, lsp_prev: 152292785529024, lsp: 152292785529024, pn: 1223465553865253687783126189050000, pd: 1225058129433561546649978597237079},
                AmmStableSwapBacktestStepData { tag: 1, index: 88, x_prev: 17131646333320373, x: 17301993196727829, y_prev: 1332930881195, y: 1346184750107, lsp_prev: 152292785529024, lsp: 153807094068297, pn: 46796900308028580151468090561670000, pd: 46857815468138874970507524406288449},
                AmmStableSwapBacktestStepData { tag: 0, index: 88, x_prev: 17301993196727829, x: 16299001242628277, y_prev: 1346184750107, y: 1446297382831, lsp_prev: 153807094068297, lsp: 153807094068297, pn: 94740862594816805641966870344530000, pd: 94797741239562368586144391834128551},
                AmmStableSwapBacktestStepData { tag: 2, index: 89, x_prev: 16299001242628277, x: 15889737203879253, y_prev: 1446297382831, y: 1409981200059, lsp_prev: 153807094068297, lsp: 149945034573387, pn: 500237531872881388360897142730000, pd: 500537854585642277303470262205371},
                AmmStableSwapBacktestStepData { tag: 0, index: 89, x_prev: 15889737203879253, x: 16734302206279641, y_prev: 1409981200059, y: 1325673927784, lsp_prev: 149945034573387, lsp: 149945034573387, pn: 5571574784559105611676787135840000, pd: 5578268707007575198646515025134941},
                AmmStableSwapBacktestStepData { tag: 1, index: 90, x_prev: 16734302206279641, x: 16804610344318843, y_prev: 1325673927784, y: 1331243664984, lsp_prev: 149945034573387, lsp: 150575019382993, pn: 89895846235698929570068203659280000, pd: 90003850856727872158812953536714381},
                AmmStableSwapBacktestStepData { tag: 0, index: 90, x_prev: 16804610344318843, x: 15956496954180364, y_prev: 1331243664984, y: 1415905149061, lsp_prev: 150575019382993, lsp: 150575019382993, pn: 945843368153384795393969687192500, pd: 946411214882330924505770889895187},
                AmmStableSwapBacktestStepData { tag: 1, index: 91, x_prev: 15956496954180364, x: 15960917590222786, y_prev: 1415905149061, y: 1416297415694, lsp_prev: 150575019382993, lsp: 150616735140511, pn: 9085128185745324874020929305670000, pd: 9090582535266645332094613361319233},
                AmmStableSwapBacktestStepData { tag: 0, index: 91, x_prev: 15960917590222786, x: 15061679318812006, y_prev: 1416297415694, y: 1506167931875, lsp_prev: 150616735140511, lsp: 150616735140511, pn: 22798845482130202069612832103125000, pd: 22798845482130669026856752270561009},
                AmmStableSwapBacktestStepData { tag: 2, index: 92, x_prev: 15061679318812006, x: 14735445093159159, y_prev: 1506167931875, y: 1473544509310, lsp_prev: 150616735140511, lsp: 147354394141287, pn: 87287603521239042215080563862900000, pd: 87287603521240785683473092768487281},
                AmmStableSwapBacktestStepData { tag: 0, index: 92, x_prev: 14735445093159159, x: 16176489417191196, y_prev: 1473544509310, y: 1329580789257, lsp_prev: 147354394141287, lsp: 147354394141287, pn: 800288158321213780726692337002500, pd: 801089247568800268912816985271807},
                AmmStableSwapBacktestStepData { tag: 1, index: 93, x_prev: 16176489417191196, x: 16254987223359509, y_prev: 1329580789257, y: 1336032694388, lsp_prev: 147354394141287, lsp: 148069444012161, pn: 7272665436729696316311619576760000, pd: 7279945382111983149713224330367143},
                AmmStableSwapBacktestStepData { tag: 0, index: 93, x_prev: 16254987223359509, x: 14806950107803525, y_prev: 1336032694388, y: 1480695010775, lsp_prev: 148069444012161, lsp: 148069444012161, pn: 141018880225061919137690511710000, pd: 141018880225064455272104971713881},
                AmmStableSwapBacktestStepData { tag: 1, index: 94, x_prev: 14806950107803525, x: 14828219671745161, y_prev: 1480695010775, y: 1482821967169, lsp_prev: 148069444012161, lsp: 148282139569596, pn: 29463397216783166282435566376030000, pd: 29463397216783711575385774118335307},
                AmmStableSwapBacktestStepData { tag: 0, index: 94, x_prev: 14828219671745161, x: 15125971346805384, y_prev: 1482821967169, y: 1453052720504, lsp_prev: 148282139569596, lsp: 148282139569596, pn: 2760831346667568134852489866730000, pd: 2761383623392283936911407673380783},
                AmmStableSwapBacktestStepData { tag: 1, index: 95, x_prev: 15125971346805384, x: 15243944547062689, y_prev: 1453052720504, y: 1464385631009, lsp_prev: 148282139569596, lsp: 149438648341472, pn: 89730074726516364093718100770490000, pd: 89748024331383974087861437538081129},
                AmmStableSwapBacktestStepData { tag: 0, index: 95, x_prev: 15243944547062689, x: 13485250912671302, y_prev: 1464385631009, y: 1640391457674, lsp_prev: 149438648341472, lsp: 149438648341472, pn: 22245995803636907873285410346970000, pd: 22223772031605718677823757882922031},
                AmmStableSwapBacktestStepData { tag: 2, index: 96, x_prev: 13485250912671302, x: 13358010039506705, y_prev: 1640391457674, y: 1624913448199, lsp_prev: 149438648341472, lsp: 148028611240743, pn: 436563391442609164945532523742000, pd: 436127264178438142059556170546739},
                AmmStableSwapBacktestStepData { tag: 0, index: 96, x_prev: 13358010039506705, x: 14654157222957438, y_prev: 1624913448199, y: 1495159122957, lsp_prev: 148028611240743, lsp: 148028611240743, pn: 2446775798671429612090612999095000, pd: 2446531145556920296773945264236473},
                AmmStableSwapBacktestStepData { tag: 1, index: 97, x_prev: 14654157222957438, x: 15013457723278163, y_prev: 1495159122957, y: 1531818441727, lsp_prev: 148028611240743, lsp: 151658076468363, pn: 92456283986100452574367704686690000, pd: 92447039282173894335298601319563561},
                AmmStableSwapBacktestStepData { tag: 0, index: 97, x_prev: 15013457723278163, x: 15165813491736389, y_prev: 1531818441727, y: 1516581349169, lsp_prev: 151658076468363, lsp: 151658076468363, pn: 30820254447967379678256340390470000, pd: 30820254447967848696204385112723107},
                AmmStableSwapBacktestStepData { tag: 1, index: 98, x_prev: 15165813491736389, x: 15323475143604635, y_prev: 1516581349169, y: 1532347514356, lsp_prev: 151658076468363, lsp: 153234692379429, pn: 3775726958853813466301381609624000, pd: 3775726958853868183366424313363329},
                AmmStableSwapBacktestStepData { tag: 0, index: 98, x_prev: 15323475143604635, x: 15477445483617490, y_prev: 1532347514356, y: 1516952012131, lsp_prev: 153234692379429, lsp: 153234692379429, pn: 629194405002352085457121945103000, pd: 629257330735429092284339690933737},
                AmmStableSwapBacktestStepData { tag: 1, index: 99, x_prev: 15477445483617490, x: 15752144792297990, y_prev: 1516952012131, y: 1543875425912, lsp_prev: 153234692379429, lsp: 155954357204401, pn: 407329340248317599375297290168000, pd: 407370077256045919971253926686611},
                AmmStableSwapBacktestStepData { tag: 0, index: 99, x_prev: 15752144792297990, x: 14365424420481979, y_prev: 1543875425912, y: 1682642621193, lsp_prev: 155954357204401, lsp: 155954357204401, pn: 97218842314798635424628515378410000, pd: 97141129411271484478534159847477923},
                AmmStableSwapBacktestStepData { tag: 2, index: 100, x_prev: 14365424420481979, x: 13905496285990562, y_prev: 1682642621193, y: 1628770583784, lsp_prev: 155954357204401, lsp: 150961271412062, pn: 11386664426883686193843478838520000, pd: 11377562376982307093000459453705111},
                AmmStableSwapBacktestStepData { tag: 0, index: 100, x_prev: 13905496285990562, x: 15550201931599521, y_prev: 1628770583784, y: 1464219929140, lsp_prev: 150961271412062, lsp: 150961271412062, pn: 45759267959316338625010210443800000, pd: 45772999859275486657309354942068507}
            ]
        };
        test_utils_backtest(admin, guy, &s);
    }

    #[test_only]
    fun test_backtest2_impl(admin: &signer, guy: &signer) {
        let s = AmmStableSwapBacktestData {
            x_decimal: 6,
            y_decimal: 10,
            amp: 100,
            data: vector[
                AmmStableSwapBacktestStepData { tag: 1, index: 1, x_prev: 0, x: 127243912000000, y_prev: 0, y: 1272439120000000000, lsp_prev: 0, lsp: 12724390830921408, pn: 1, pd: 1},
                AmmStableSwapBacktestStepData { tag: 0, index: 1, x_prev: 127243912000000, x: 99554141964535, y_prev: 1272439120000000000, y: 1549963930764810239, lsp_prev: 12724390830921408, lsp: 12724390830921408, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 2, x_prev: 99554141964535, x: 97641413160505, y_prev: 1549963930764810239, y: 1520184550448938359, lsp_prev: 12724390830921408, lsp: 12479917739438030, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 2, x_prev: 97641413160505, x: 118577060448182, y_prev: 1520184550448938359, y: 1310243820628728147, lsp_prev: 12479917739438030, lsp: 12479917739438030, pn: 312372967364966263821958950039491441853, pd: 312216858935494050576517994113226180000},
                AmmStableSwapBacktestStepData { tag: 2, index: 3, x_prev: 118577060448182, x: 116089579476667, y_prev: 1310243820628728147, y: 1282757841810054215, lsp_prev: 12479917739438030, lsp: 12218117035443574, pn: 14970233134007346647315100917859817709, pd: 14962751758128068709871665133175342000},
                AmmStableSwapBacktestStepData { tag: 0, index: 3, x_prev: 116089579476667, x: 108036858288449, y_prev: 1282757841810054215, y: 1363419367177311297, lsp_prev: 12218117035443574, lsp: 12218117035443574, pn: 4357496773450686376686564455650701327, pd: 4352274044597229069709351127854090000},
                AmmStableSwapBacktestStepData { tag: 1, index: 4, x_prev: 108036858288449, x: 110902710508949, y_prev: 1363419367177311297, y: 1399586268758859873, lsp_prev: 12218117035443574, lsp: 12542222330535256, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 4, x_prev: 110902710508949, x: 98986169411710, y_prev: 1399586268758859873, y: 1519160965754953696, lsp_prev: 12542222330535256, lsp: 12542222330535256, pn: 64377735273603489468054436500681277, pd: 64223598636875869470750678945278125},
                AmmStableSwapBacktestStepData { tag: 2, index: 5, x_prev: 98986169411710, x: 96894982793796, y_prev: 1519160965754953696, y: 1487067097480979129, lsp_prev: 12542222330535256, lsp: 12277254733017331, pn: 290172700368859437591973637689846044851, pd: 289477953280989049040085358184325240000},
                AmmStableSwapBacktestStepData { tag: 0, index: 5, x_prev: 96894982793796, x: 108559774465303, y_prev: 1487067097480979129, y: 1370018541338609831, lsp_prev: 12277254733017331, lsp: 12277254733017331, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 6, x_prev: 108559774465303, x: 105079957533076, y_prev: 1370018541338609831, y: 1326103437967248461, lsp_prev: 12277254733017331, lsp: 11883714868812139, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 6, x_prev: 105079957533076, x: 110600701982107, y_prev: 1326103437967248461, y: 1270792850221931784, lsp_prev: 11883714868812139, lsp: 11883714868812139, pn: 70656444951355074685357058500879714761, pd: 70607020037327931801050546391315623750},
                AmmStableSwapBacktestStepData { tag: 1, index: 7, x_prev: 110600701982107, x: 113990746613440, y_prev: 1270792850221931784, y: 1309744180568173192, lsp_prev: 11883714868812139, lsp: 12247965032412605, pn: 6254519714491621466943363524614237071, pd: 6250144613262248187763300569357200000},
                AmmStableSwapBacktestStepData { tag: 0, index: 7, x_prev: 113990746613440, x: 106154210386585, y_prev: 1309744180568173192, y: 1388270541064022663, lsp_prev: 12247965032412605, lsp: 12247965032412605, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 8, x_prev: 106154210386585, x: 105530296683362, y_prev: 1388270541064022663, y: 1380111081244228608, lsp_prev: 12247965032412605, lsp: 12175978502698002, pn: 18314233333035342891545205194600011296, pd: 18288629252082677397696389449978799375},
                AmmStableSwapBacktestStepData { tag: 0, index: 8, x_prev: 105530296683362, x: 98710280023332, y_prev: 1380111081244228608, y: 1448541611549769455, lsp_prev: 12175978502698002, lsp: 12175978502698002, pn: 14393280616232661470204075220321479617, pd: 14363118068289449625250119571740168000},
                AmmStableSwapBacktestStepData { tag: 2, index: 9, x_prev: 98710280023332, x: 95740563763992, y_prev: 1448541611549769455, y: 1404961980581909403, lsp_prev: 12175978502698002, lsp: 11809662032677876, pn: 30089465418198414615832247036061179853, pd: 30026409957288519902558077237755920000},
                AmmStableSwapBacktestStepData { tag: 0, index: 9, x_prev: 95740563763992, x: 97529535781895, y_prev: 1404961980581909403, y: 1387003291045907997, lsp_prev: 11809662032677876, lsp: 11809662032677876, pn: 11113761433635599983463180842331503107, pd: 11092685331505581343901006878447450000},
                AmmStableSwapBacktestStepData { tag: 1, index: 10, x_prev: 97529535781895, x: 97678872951497, y_prev: 1387003291045907997, y: 1389127069694626472, lsp_prev: 11809662032677876, lsp: 11827744980451339, pn: 11380068558095761620507202620369114049, pd: 11358487431974847817968583260205646250},
                AmmStableSwapBacktestStepData { tag: 0, index: 10, x_prev: 97678872951497, x: 112380486858549, y_prev: 1389127069694626472, y: 1241773391152720855, lsp_prev: 11827744980451339, lsp: 11827744980451339, pn: 8633174929128736360700367497843678489, pd: 8628860498879173840340522209631982000},
                AmmStableSwapBacktestStepData { tag: 2, index: 11, x_prev: 112380486858549, x: 108178788312174, y_prev: 1241773391152720855, y: 1195345780822990414, lsp_prev: 11827744980451339, lsp: 11385527472052269, pn: 64997449826409164522325158105635414967, pd: 64964967342736871928036785338360470000},
                AmmStableSwapBacktestStepData { tag: 0, index: 11, x_prev: 108178788312174, x: 92302118037625, y_prev: 1195345780822990414, y: 1354503895441055309, lsp_prev: 11385527472052269, lsp: 11385527472052269, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 12, x_prev: 92302118037625, x: 93376745343796, y_prev: 1354503895441055309, y: 1370273705531034443, lsp_prev: 11385527472052269, lsp: 11518083462930411, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 12, x_prev: 93376745343796, x: 105009637318157, y_prev: 1370273705531034443, y: 1253610079727310481, lsp_prev: 11518083462930411, lsp: 11518083462930411, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 13, x_prev: 105009637318157, x: 108066001103463, y_prev: 1253610079727310481, y: 1290097096980442209, lsp_prev: 11518083462930411, lsp: 11853323675841263, pn: 389422609373158309876880381529941811, pd: 389072444173396698880107435968345000},
                AmmStableSwapBacktestStepData { tag: 0, index: 13, x_prev: 108066001103463, x: 117342455217510, y_prev: 1290097096980442209, y: 1197241436409261308, lsp_prev: 11853323675841263, lsp: 11853323675841263, pn: 141196956001802554361009137917285069247, pd: 141182837718028724168331419276147775000},
                AmmStableSwapBacktestStepData { tag: 1, index: 14, x_prev: 117342455217510, x: 121300883058215, y_prev: 1197241436409261308, y: 1237629153072797724, lsp_prev: 11853323675841263, lsp: 12253183439780635, pn: 37720976400645736836700824875349029049, pd: 37717204680177176949127541776187462500},
                AmmStableSwapBacktestStepData { tag: 0, index: 14, x_prev: 121300883058215, x: 102151738219151, y_prev: 1237629153072797724, y: 1429464946372532251, lsp_prev: 12253183439780635, lsp: 12253183439780635, pn: 293895003566961932417986784400576245353, pd: 293366943069440955543739589974262530000},
                AmmStableSwapBacktestStepData { tag: 2, index: 15, x_prev: 102151738219151, x: 100928350307630, y_prev: 1429464946372532251, y: 1412345412570927580, lsp_prev: 12253183439780635, lsp: 12106437072472430, pn: 462738186976882126296971578667094257, pd: 461906754818215667711787679334645000},
                AmmStableSwapBacktestStepData { tag: 0, index: 15, x_prev: 100928350307630, x: 99980438422956, y_prev: 1412345412570927580, y: 1421858476209152463, lsp_prev: 12106437072472430, lsp: 12106437072472430, pn: 31793797549806235911429522512159717921, pd: 31733503892411091861543400940512520000},
                AmmStableSwapBacktestStepData { tag: 2, index: 16, x_prev: 99980438422956, x: 97715505441714, y_prev: 1421858476209152463, y: 1389648033764381301, lsp_prev: 12106437072472430, lsp: 11832180737500344, pn: 60739231406744873357161436159358767597, pd: 60624045719877942925039999159042580000},
                AmmStableSwapBacktestStepData { tag: 0, index: 16, x_prev: 97715505441714, x: 113589606865350, y_prev: 1389648033764381301, y: 1230558923128024361, lsp_prev: 11832180737500344, lsp: 11832180737500344, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 17, x_prev: 113589606865350, x: 113626683395139, y_prev: 1230558923128024361, y: 1230960587116748005, lsp_prev: 11832180737500344, lsp: 11836042853178813, pn: 14060076600018600833574309740876405041, pd: 14054454818091164498588293311700098000},
                AmmStableSwapBacktestStepData { tag: 0, index: 17, x_prev: 113626683395139, x: 98674141053276, y_prev: 1230960587116748005, y: 1380801033913627869, lsp_prev: 11836042853178813, lsp: 11836042853178813, pn: 7617367159468996415964459211167292751, pd: 7603680534506987587930050611090040000},
                AmmStableSwapBacktestStepData { tag: 2, index: 18, x_prev: 98674141053276, x: 95008680676576, y_prev: 1380801033913627869, y: 1329508249158751937, lsp_prev: 11836042853178813, lsp: 11396367922825622, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 18, x_prev: 95008680676576, x: 94116365907871, y_prev: 1329508249158751937, y: 1338463350700644032, lsp_prev: 11396367922825622, lsp: 11396367922825622, pn: 31695320837888525500954167370041315572, pd: 31635213931419263660866763541720175625},
                AmmStableSwapBacktestStepData { tag: 1, index: 19, x_prev: 94116365907871, x: 94852435964901, y_prev: 1338463350700644032, y: 1348931272888030694, lsp_prev: 11396367922825622, lsp: 11485497216184681, pn: 257544226049875696865271419319177485099, pd: 257055819991894624519908788284947585000},
                AmmStableSwapBacktestStepData { tag: 0, index: 19, x_prev: 94852435964901, x: 89861183579395, y_prev: 1348931272888030694, y: 1399053726699869093, lsp_prev: 11485497216184681, lsp: 11485497216184681, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 20, x_prev: 89861183579395, x: 91056565470465, y_prev: 1399053726699869093, y: 1417664693336579289, lsp_prev: 11485497216184681, lsp: 11638283489804519, pn: 131009273814821548990476491780405249, pd: 130682567396332485248529408190650000},
                AmmStableSwapBacktestStepData { tag: 0, index: 20, x_prev: 91056565470465, x: 88051990673164, y_prev: 1417664693336579289, y: 1447863741221248152, lsp_prev: 11638283489804519, lsp: 11638283489804519, pn: 64217529887219975650295935011002855031, pd: 64031837558301774866890421533889795000},
                AmmStableSwapBacktestStepData { tag: 1, index: 21, x_prev: 88051990673164, x: 90899898123881, y_prev: 1447863741221248152, y: 1494692687446358000, lsp_prev: 11638283489804519, lsp: 12014706033017673, pn: 45625829434873921384100043901211521, pd: 45493897133188295282829063627997095},
                AmmStableSwapBacktestStepData { tag: 0, index: 21, x_prev: 90899898123881, x: 102106987923839, y_prev: 1494692687446358000, y: 1382146073596402635, lsp_prev: 12014706033017673, lsp: 12014706033017673, pn: 22719206514767497987713618792753742233, pd: 22682913852603005063194882334357362000},
                AmmStableSwapBacktestStepData { tag: 1, index: 22, x_prev: 102106987923839, x: 104821708640467, y_prev: 1382146073596402635, y: 1418893221423321619, lsp_prev: 12014706033017673, lsp: 12334141284563431, pn: 24940977201185485612015054970811489503, pd: 24901135384569813161035427231246290000},
                AmmStableSwapBacktestStepData { tag: 0, index: 22, x_prev: 104821708640467, x: 94085386404723, y_prev: 1418893221423321619, y: 1526703532848075282, lsp_prev: 12334141284563431, lsp: 12334141284563431, pn: 10718024283655228538878251301603371827, pd: 10688097610346403378817032562886405000},
                AmmStableSwapBacktestStepData { tag: 2, index: 23, x_prev: 94085386404723, x: 93733420056963, y_prev: 1526703532848075282, y: 1520992249862452938, lsp_prev: 12334141284563431, lsp: 12288000190536239, pn: 31913950899777435212911504455978803073, pd: 31824841344014625605279370200092355000},
                AmmStableSwapBacktestStepData { tag: 0, index: 23, x_prev: 93733420056963, x: 92967565115319, y_prev: 1520992249862452938, y: 1528691919524296393, lsp_prev: 12288000190536239, lsp: 12288000190536239, pn: 3579382877835961281771228655726726369, pd: 3569032683055150333571819237696445000},
                AmmStableSwapBacktestStepData { tag: 2, index: 24, x_prev: 92967565115319, x: 90278926904660, y_prev: 1528691919524296393, y: 1484481882377882328, lsp_prev: 12288000190536239, lsp: 11932629080150700, pn: 33753438343258982824293938681698831701, pd: 33655836417648267122651085494321575000},
                AmmStableSwapBacktestStepData { tag: 0, index: 24, x_prev: 90278926904660, x: 101409456880452, y_prev: 1484481882377882328, y: 1372704116562575869, lsp_prev: 11932629080150700, lsp: 11932629080150700, pn: 280123249557785919954234657072043576859, pd: 279675768328456360828575988746309720000},
                AmmStableSwapBacktestStepData { tag: 1, index: 25, x_prev: 101409456880452, x: 101925016890466, y_prev: 1372704116562575869, y: 1379682867557329261, lsp_prev: 11932629080150700, lsp: 11993293899362888, pn: 188652501095823602721115009542473804077, pd: 188351139272984110074327974229705620000},
                AmmStableSwapBacktestStepData { tag: 0, index: 25, x_prev: 101925016890466, x: 102925812821999, y_prev: 1379682867557329261, y: 1369644660639619679, lsp_prev: 11993293899362888, lsp: 11993293899362888, pn: 47275509525490597792769111455523531449, pd: 47204702471782244304973510269260690000},
                AmmStableSwapBacktestStepData { tag: 2, index: 26, x_prev: 102925812821999, x: 102196517702250, y_prev: 1369644660639619679, y: 1359939853464348988, lsp_prev: 11993293899362888, lsp: 11908313752296632, pn: 8738986630427236382097726094822629139, pd: 8725897783751483706941821155770625000},
                AmmStableSwapBacktestStepData { tag: 0, index: 26, x_prev: 102196517702250, x: 93169250583970, y_prev: 1359939853464348988, y: 1450557204470442299, lsp_prev: 11908313752296632, lsp: 11908313752296632, pn: 2249523042535619786801515384391722387, pd: 2243913259387182803020000283526100000},
                AmmStableSwapBacktestStepData { tag: 2, index: 27, x_prev: 93169250583970, x: 89582896407596, y_prev: 1450557204470442299, y: 1394721058363045198, lsp_prev: 11908313752296632, lsp: 11449928281860323, pn: 251640657952577878165585950011736610087, pd: 251013125139732030287259824199035740000},
                AmmStableSwapBacktestStepData { tag: 0, index: 27, x_prev: 89582896407596, x: 86626947965822, y_prev: 1394721058363045198, y: 1424431361670498259, lsp_prev: 11449928281860323, lsp: 11449928281860323, pn: 124311487045375786783904828666124966983, pd: 123952026169485973272346825152264140000},
                AmmStableSwapBacktestStepData { tag: 1, index: 28, x_prev: 86626947965822, x: 90009729780284, y_prev: 1424431361670498259, y: 1480055398062836531, lsp_prev: 11449928281860323, lsp: 11897047914703116, pn: 89473183719459640206853391814880835507, pd: 89214461780297997770235894162291480000},
                AmmStableSwapBacktestStepData { tag: 0, index: 28, x_prev: 90009729780284, x: 101107070320126, y_prev: 1480055398062836531, y: 1368610935424218855, lsp_prev: 11897047914703116, lsp: 11897047914703116, pn: 111382070399272924459887100725656163693, pd: 111204143769240544222345724250793316000},
                AmmStableSwapBacktestStepData { tag: 1, index: 29, x_prev: 101107070320126, x: 101405256622941, y_prev: 1368610935424218855, y: 1372647260812091276, lsp_prev: 11897047914703116, lsp: 11932134845032191, pn: 35012505662926670398758414676813600123, pd: 34956575142697852045212481123843492500},
                AmmStableSwapBacktestStepData { tag: 0, index: 29, x_prev: 101405256622941, x: 90275187660287, y_prev: 1372647260812091276, y: 1484420396927049853, lsp_prev: 11932134845032191, lsp: 11932134845032191, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 30, x_prev: 90275187660287, x: 89867869311511, y_prev: 1484420396927049853, y: 1477722746325188991, lsp_prev: 11932134845032191, lsp: 11878297488517989, pn: 66893532212811187275555719798112900081, pd: 66700101917252061953167233457874510000},
                AmmStableSwapBacktestStepData { tag: 0, index: 30, x_prev: 89867869311511, x: 88437202291871, y_prev: 1477722746325188991, y: 1492109921301758666, lsp_prev: 11878297488517989, lsp: 11878297488517989, pn: 29548204674022499449032001538408759577, pd: 29456888320230186048253118247239495000},
                AmmStableSwapBacktestStepData { tag: 2, index: 31, x_prev: 88437202291871, x: 88145675819157, y_prev: 1492109921301758666, y: 1487191295079009429, lsp_prev: 11878297488517989, lsp: 11839141589428685, pn: 3669214870473779457162834015022382419, pd: 3657875456558497963625045427782520000},
                AmmStableSwapBacktestStepData { tag: 0, index: 31, x_prev: 88145675819157, x: 99647289844731, y_prev: 1487191295079009429, y: 1371657210320877624, lsp_prev: 11839141589428685, lsp: 11839141589428685, pn: 169796631811922798365973344779820251, pd: 169508467417310946636955243720558750},
                AmmStableSwapBacktestStepData { tag: 1, index: 32, x_prev: 99647289844731, x: 100385325637036, y_prev: 1371657210320877624, y: 1381816363846949252, lsp_prev: 11839141589428685, lsp: 11926827970631603, pn: 69790060622141099030313663159801271909, pd: 69671618870061000759514100623720870000},
                AmmStableSwapBacktestStepData { tag: 0, index: 32, x_prev: 100385325637036, x: 99430993964022, y_prev: 1381816363846949252, y: 1391392089184229749, lsp_prev: 11926827970631603, lsp: 11926827970631603, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 33, x_prev: 99430993964022, x: 98139913786745, y_prev: 1391392089184229749, y: 1373325300615094705, lsp_prev: 11926827970631603, lsp: 11771961861415629, pn: 5425278295713930472555162520215891193, pd: 5415530341100025612907373798838770000},
                AmmStableSwapBacktestStepData { tag: 0, index: 33, x_prev: 98139913786745, x: 99081853763200, y_prev: 1373325300615094705, y: 1363873913058980966, lsp_prev: 11771961861415629, lsp: 11771961861415629, pn: 13597884681009146585875134484193122019, pd: 13574807508244933945681509184208000000},
                AmmStableSwapBacktestStepData { tag: 1, index: 34, x_prev: 99081853763200, x: 100585454201816, y_prev: 1363873913058980966, y: 1384571158175055266, lsp_prev: 11771961861415629, lsp: 11950605339973226, pn: 93424807276242422603889390967099976407, pd: 93266254643347385415924326219805320000},
                AmmStableSwapBacktestStepData { tag: 0, index: 34, x_prev: 100585454201816, x: 89687013110111, y_prev: 1384571158175055266, y: 1494037737052833547, lsp_prev: 11950605339973226, lsp: 11950605339973226, pn: 270012110918203568184565499562421693027, pd: 269204497425929456822972959351867510000},
                AmmStableSwapBacktestStepData { tag: 2, index: 35, x_prev: 89687013110111, x: 88897182295503, y_prev: 1494037737052833547, y: 1480880458178312910, lsp_prev: 11950605339973226, lsp: 11845362049741794, pn: 1179010291169894402840049440507508853, pd: 1175483839650957653531911742120449000},
                AmmStableSwapBacktestStepData { tag: 0, index: 35, x_prev: 88897182295503, x: 100667817959318, y_prev: 1480880458178312910, y: 1362665104113824095, lsp_prev: 11845362049741794, lsp: 11845362049741794, pn: 22083277983596757000952656611808368693, pd: 22048001181705710570916895654186292000},
                AmmStableSwapBacktestStepData { tag: 2, index: 36, x_prev: 100667817959318, x: 100036874367688, y_prev: 1362665104113824095, y: 1354124491707515709, lsp_prev: 11845362049741794, lsp: 11771120296743334, pn: 136295800332200788828120427400316781307, pd: 136078075411540371237714675729760240000},
                AmmStableSwapBacktestStepData { tag: 0, index: 36, x_prev: 100036874367688, x: 101019130735405, y_prev: 1354124491707515709, y: 1344272240759335318, lsp_prev: 11771120296743334, lsp: 11771120296743334, pn: 22770096233237614762288388992476936419, pd: 22735992244869980905557347862263025000},
                AmmStableSwapBacktestStepData { tag: 2, index: 37, x_prev: 101019130735405, x: 97000997834735, y_prev: 1344272240759335318, y: 1290802521917648923, lsp_prev: 11771120296743334, lsp: 11302912686978955, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 37, x_prev: 97000997834735, x: 86940003807433, y_prev: 1290802521917648923, y: 1391813226192007106, lsp_prev: 11302912686978955, lsp: 11302912686978955, pn: 243757201299524800006446076524578568361, pd: 243100829061063193116088494035975605000},
                AmmStableSwapBacktestStepData { tag: 1, index: 38, x_prev: 86940003807433, x: 90326235218426, y_prev: 1391813226192007106, y: 1446023042828388650, lsp_prev: 11302912686978955, lsp: 11743150509617387, pn: 438525359579539081882055788408987007, pd: 437344529350299136087551113356586800},
                AmmStableSwapBacktestStepData { tag: 0, index: 38, x_prev: 90326235218426, x: 96980253511986, y_prev: 1446023042828388650, y: 1379191746471584149, lsp_prev: 11743150509617387, lsp: 11743150509617387, pn: 5177476385178287019614228477309242271, pd: 5167657835291159338036730319887940000},
                AmmStableSwapBacktestStepData { tag: 2, index: 39, x_prev: 96980253511986, x: 95658882871088, y_prev: 1379191746471584149, y: 1360400050059579589, lsp_prev: 11743150509617387, lsp: 11583148305528100, pn: 104776874942169670881465696865965516163, pd: 104578176406994873847141323932598560000},
                AmmStableSwapBacktestStepData { tag: 0, index: 39, x_prev: 95658882871088, x: 88356778065516, y_prev: 1360400050059579589, y: 1433746625043599556, lsp_prev: 11583148305528100, lsp: 11583148305528100, pn: 3544715632099548695167653415834419131, pd: 3534818141303945924553075326244410000},
                AmmStableSwapBacktestStepData { tag: 1, index: 40, x_prev: 88356778065516, x: 88471821779239, y_prev: 1433746625043599556, y: 1435613414891458871, lsp_prev: 11583148305528100, lsp: 11598229982642687, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 40, x_prev: 88471821779239, x: 85677076215411, y_prev: 1435613414891458871, y: 1463718009528509143, lsp_prev: 11598229982642687, lsp: 11598229982642687, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 41, x_prev: 85677076215411, x: 88744665276001, y_prev: 1463718009528509143, y: 1516125089136704951, lsp_prev: 11598229982642687, lsp: 12013493959759630, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 41, x_prev: 88744665276001, x: 96513398940925, y_prev: 1516125089136704951, y: 1438043847545473675, lsp_prev: 12013493959759630, lsp: 12013493959759630, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 42, x_prev: 96513398940925, x: 94745027211478, y_prev: 1438043847545473675, y: 1411695214986564922, lsp_prev: 12013493959759630, lsp: 11793376097126539, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 42, x_prev: 94745027211478, x: 92269991846016, y_prev: 1411695214986564922, y: 1436556595548066617, lsp_prev: 11793376097126539, lsp: 11793376097126539, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 43, x_prev: 92269991846016, x: 89516367048892, y_prev: 1436556595548066617, y: 1393685259105603470, lsp_prev: 11793376097126539, lsp: 11441424913289245, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 43, x_prev: 89516367048892, x: 92755276859569, y_prev: 1393685259105603470, y: 1361153855411276785, lsp_prev: 11441424913289245, lsp: 11441424913289245, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 44, x_prev: 92755276859569, x: 89889224069400, y_prev: 1361153855411276785, y: 1319095452512462483, lsp_prev: 11441424913289245, lsp: 11087895400937203, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 44, x_prev: 89889224069400, x: 93324226122259, y_prev: 1319095452512462483, y: 1284619459873668800, lsp_prev: 11087895400937203, lsp: 11087895400937203, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 45, x_prev: 93324226122259, x: 95531094884814, y_prev: 1284619459873668800, y: 1314997280034233784, lsp_prev: 11087895400937203, lsp: 11350094521353710, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 45, x_prev: 95531094884814, x: 81949527727386, y_prev: 1314997280034233784, y: 1451466235632984171, lsp_prev: 11350094521353710, lsp: 11350094521353710, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 46, x_prev: 81949527727386, x: 84653360298457, y_prev: 1451466235632984171, y: 1499355732894882251, lsp_prev: 11350094521353710, lsp: 11724578134653608, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 46, x_prev: 84653360298457, x: 98683036001044, y_prev: 1499355732894882251, y: 1358384137472331315, lsp_prev: 11724578134653608, lsp: 11724578134653608, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 47, x_prev: 98683036001044, x: 100638704976493, y_prev: 1358384137472331315, y: 1385304161643142027, lsp_prev: 11724578134653608, lsp: 11956932089673082, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 47, x_prev: 100638704976493, x: 86981447973706, y_prev: 1385304161643142027, y: 1522523365499313034, lsp_prev: 11956932089673082, lsp: 11956932089673082, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 48, x_prev: 86981447973706, x: 86095004545965, y_prev: 1522523365499313034, y: 1507007058719303901, lsp_prev: 11956932089673082, lsp: 11835076865211381, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 48, x_prev: 86095004545965, x: 86753361079704, y_prev: 1507007058719303901, y: 1500382517079671778, lsp_prev: 11835076865211381, lsp: 11835076865211381, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 49, x_prev: 86753361079704, x: 87859481075421, y_prev: 1500382517079671778, y: 1519512647402130986, lsp_prev: 11835076865211381, lsp: 11985976092728699, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 49, x_prev: 87859481075421, x: 100883161567276, y_prev: 1519512647402130986, y: 1388669136705464178, lsp_prev: 11985976092728699, lsp: 11985976092728699, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 50, x_prev: 100883161567276, x: 101965262394193, y_prev: 1388669136705464178, y: 1403564387784020224, lsp_prev: 11985976092728699, lsp: 12114541003263346, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 50, x_prev: 101965262394193, x: 90196100444061, y_prev: 1403564387784020224, y: 1521786000094727807, lsp_prev: 12114541003263346, lsp: 12114541003263346, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 51, x_prev: 90196100444061, x: 93199128881722, y_prev: 1521786000094727807, y: 1572453009109752655, lsp_prev: 12114541003263346, lsp: 12517887832703885, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 51, x_prev: 93199128881722, x: 107427850164180, y_prev: 1572453009109752655, y: 1429553746986926539, lsp_prev: 12517887832703885, lsp: 12517887832703885, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 52, x_prev: 107427850164180, x: 106606707073013, y_prev: 1429553746986926539, y: 1418626709156442987, lsp_prev: 12517887832703885, lsp: 12422205222522908, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 52, x_prev: 106606707073013, x: 93226280255643, y_prev: 1418626709156442987, y: 1552996091150845196, lsp_prev: 12422205222522908, lsp: 12422205222522908, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 53, x_prev: 93226280255643, x: 90926897298096, y_prev: 1552996091150845196, y: 1514692162952294218, lsp_prev: 12422205222522908, lsp: 12115817293008818, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 53, x_prev: 90926897298096, x: 102966282040117, y_prev: 1514692162952294218, y: 1393777696593276156, lsp_prev: 12115817293008818, lsp: 12115817293008818, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 54, x_prev: 102966282040117, x: 106145845471531, y_prev: 1393777696593276156, y: 1436817073249433564, lsp_prev: 12115817293008818, lsp: 12489949570520175, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 54, x_prev: 106145845471531, x: 107188085478331, y_prev: 1436817073249433564, y: 1426363172992117757, lsp_prev: 12489949570520175, lsp: 12489949570520175, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 55, x_prev: 107188085478331, x: 103179454953112, y_prev: 1426363172992117757, y: 1373019903264055053, lsp_prev: 12489949570520175, lsp: 12022849212458813, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 55, x_prev: 103179454953112, x: 90229189590252, y_prev: 1373019903264055053, y: 1503069503117777972, lsp_prev: 12022849212458813, lsp: 12022849212458813, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 56, x_prev: 90229189590252, x: 91355426103153, y_prev: 1503069503117777972, y: 1521830746164809452, lsp_prev: 12022849212458813, lsp: 12172917852481686, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 56, x_prev: 91355426103153, x: 89229799677630, y_prev: 1521830746164809452, y: 1543212041264779259, lsp_prev: 12172917852481686, lsp: 12172917852481686, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 57, x_prev: 89229799677630, x: 89699187683909, y_prev: 1543212041264779259, y: 1551330015595462753, lsp_prev: 12172917852481686, lsp: 12236952756314457, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 57, x_prev: 89699187683909, x: 88352788368034, y_prev: 1551330015595462753, y: 1564878928489153685, lsp_prev: 12236952756314457, lsp: 12236952756314457, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 58, x_prev: 88352788368034, x: 89652547307364, y_prev: 1564878928489153685, y: 1587899881351448069, lsp_prev: 12236952756314457, lsp: 12416970716459926, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 58, x_prev: 89652547307364, x: 102544965846007, y_prev: 1587899881351448069, y: 1458329561074442238, lsp_prev: 12416970716459926, lsp: 12416970716459926, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 59, x_prev: 102544965846007, x: 99886451109861, y_prev: 1458329561074442238, y: 1420521848172211724, lsp_prev: 12416970716459926, lsp: 12095056331334631, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 59, x_prev: 99886451109861, x: 102789844992292, y_prev: 1420521848172211724, y: 1391389399985530497, lsp_prev: 12095056331334631, lsp: 12095056331334631, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 60, x_prev: 102789844992292, x: 106309000326259, y_prev: 1391389399985530497, y: 1439025578724308753, lsp_prev: 12095056331334631, lsp: 12509147645571353, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 60, x_prev: 106309000326259, x: 97034586805183, y_prev: 1439025578724308753, y: 1532140710805235483, lsp_prev: 12509147645571353, lsp: 12509147645571353, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 61, x_prev: 97034586805183, x: 94793653095727, y_prev: 1532140710805235483, y: 1496757185409627219, lsp_prev: 12509147645571353, lsp: 12220259203228571, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 61, x_prev: 94793653095727, x: 102855067793871, y_prev: 1496757185409627219, y: 1415812668636945984, lsp_prev: 12220259203228571, lsp: 12220259203228571, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 62, x_prev: 102855067793871, x: 105441975450199, y_prev: 1415812668636945984, y: 1451421770949367268, lsp_prev: 12220259203228571, lsp: 12527610924181185, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 62, x_prev: 105441975450199, x: 108577926387278, y_prev: 1451421770949367268, y: 1419967574202497502, lsp_prev: 12527610924181185, lsp: 12527610924181185, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 63, x_prev: 108577926387278, x: 107832243699052, y_prev: 1419967574202497502, y: 1410215635911199948, lsp_prev: 12527610924181185, lsp: 12441574812589965, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 63, x_prev: 107832243699052, x: 98191835520992, y_prev: 1410215635911199948, y: 1506970161244360929, lsp_prev: 12441574812589965, lsp: 12441574812589965, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 64, x_prev: 98191835520992, x: 101405280155314, y_prev: 1506970161244360929, y: 1556287552583875665, lsp_prev: 12441574812589965, lsp: 12848740149829084, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 64, x_prev: 101405280155314, x: 113613048125303, y_prev: 1556287552583875665, y: 1433790584369811321, lsp_prev: 12848740149829084, lsp: 12848740149829084, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 65, x_prev: 113613048125303, x: 110878004248694, y_prev: 1433790584369811321, y: 1399274477084353725, lsp_prev: 12848740149829084, lsp: 12539428247289710, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 65, x_prev: 110878004248694, x: 99841192511753, y_prev: 1399274477084353725, y: 1510012417571326132, lsp_prev: 12539428247289710, lsp: 12539428247289710, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 66, x_prev: 99841192511753, x: 98269311808568, y_prev: 1510012417571326132, y: 1486239069907525298, lsp_prev: 12539428247289710, lsp: 12342009879229156, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 66, x_prev: 98269311808568, x: 109132362085358, y_prev: 1486239069907525298, y: 1377244566446737872, lsp_prev: 12342009879229156, lsp: 12342009879229156, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 67, x_prev: 109132362085358, x: 105603524712146, y_prev: 1377244566446737872, y: 1332710827734755593, lsp_prev: 12342009879229156, lsp: 11942926189568761, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 67, x_prev: 105603524712146, x: 95946475165325, y_prev: 1332710827734755593, y: 1429596717332850952, lsp_prev: 11942926189568761, lsp: 11942926189568761, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 68, x_prev: 95946475165325, x: 96958802491256, y_prev: 1429596717332850952, y: 1444680333687947714, lsp_prev: 11942926189568761, lsp: 12068935514168193, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 68, x_prev: 96958802491256, x: 106717743171934, y_prev: 1444680333687947714, y: 1346772205040750505, lsp_prev: 12068935514168193, lsp: 12068935514168193, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 69, x_prev: 106717743171934, x: 108034840398014, y_prev: 1346772205040750505, y: 1363393901514999569, lsp_prev: 12068935514168193, lsp: 12217888827975053, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 69, x_prev: 108034840398014, x: 109134832491734, y_prev: 1363393901514999569, y: 1352369102453015671, lsp_prev: 12217888827975053, lsp: 12217888827975053, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 70, x_prev: 109134832491734, x: 112378278326733, y_prev: 1352369102453015671, y: 1392560999325768791, lsp_prev: 12217888827975053, lsp: 12580999850613768, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 70, x_prev: 112378278326733, x: 114700178694207, y_prev: 1392560999325768791, y: 1369296226801814606, lsp_prev: 12580999850613768, lsp: 12580999850613768, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 71, x_prev: 114700178694207, x: 113049031831742, y_prev: 1369296226801814606, y: 1349584756476238687, lsp_prev: 12580999850613768, lsp: 12399892212713776, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 71, x_prev: 113049031831742, x: 107470976871355, y_prev: 1349584756476238687, y: 1405491036733549387, lsp_prev: 12399892212713776, lsp: 12399892212713776, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 72, x_prev: 107470976871355, x: 108073642749927, y_prev: 1405491036733549387, y: 1413372620349302034, lsp_prev: 12399892212713776, lsp: 12469427189989725, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 72, x_prev: 108073642749927, x: 116051875676287, y_prev: 1413372620349302034, y: 1333426381761369115, lsp_prev: 12469427189989725, lsp: 12469427189989725, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 73, x_prev: 116051875676287, x: 114440925472320, y_prev: 1333426381761369115, y: 1314916698146553691, lsp_prev: 12469427189989725, lsp: 12296335405320062, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 73, x_prev: 114440925472320, x: 107640923150026, y_prev: 1314916698146553691, y: 1383050129042206546, lsp_prev: 12296335405320062, lsp: 12296335405320062, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 74, x_prev: 107640923150026, x: 106031390748288, y_prev: 1383050129042206546, y: 1362369667273783057, lsp_prev: 12296335405320062, lsp: 12112470851966860, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 74, x_prev: 106031390748288, x: 118693488184650, y_prev: 1362369667273783057, y: 1235564193336974302, lsp_prev: 12112470851966860, lsp: 12112470851966860, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 75, x_prev: 118693488184650, x: 122014477540961, y_prev: 1235564193336974302, y: 1270134712729982154, lsp_prev: 12112470851966860, lsp: 12451372230578562, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 75, x_prev: 122014477540961, x: 105817995920390, y_prev: 1270134712729982154, y: 1432379218605462665, lsp_prev: 12451372230578562, lsp: 12451372230578562, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 76, x_prev: 105817995920390, x: 107455525166191, y_prev: 1432379218605462665, y: 1454545229605228405, lsp_prev: 12451372230578562, lsp: 12644056716809703, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 76, x_prev: 107455525166191, x: 125170348809765, y_prev: 1454545229605228405, y: 1277109192295885258, lsp_prev: 12644056716809703, lsp: 12644056716809703, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 77, x_prev: 125170348809765, x: 121123136604732, y_prev: 1277109192295885258, y: 1235815611512824088, lsp_prev: 12644056716809703, lsp: 12235228418798187, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 77, x_prev: 121123136604732, x: 119896423901940, y_prev: 1235815611512824088, y: 1248086399239463191, lsp_prev: 12235228418798187, lsp: 12235228418798187, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 78, x_prev: 119896423901940, x: 122471125181853, y_prev: 1248086399239463191, y: 1274888279937691483, lsp_prev: 12235228418798187, lsp: 12497972354311001, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 78, x_prev: 122471125181853, x: 111636645134219, y_prev: 1274888279937691483, y: 1383370882909272657, lsp_prev: 12497972354311001, lsp: 12497972354311001, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 79, x_prev: 111636645134219, x: 113131338110896, y_prev: 1383370882909272657, y: 1401892710937492329, lsp_prev: 12497972354311001, lsp: 12665306579360757, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 79, x_prev: 113131338110896, x: 132973860269261, y_prev: 1401892710937492329, y: 1203354079982733743, lsp_prev: 12665306579360757, lsp: 12665306579360757, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 80, x_prev: 132973860269261, x: 132616711587261, y_prev: 1203354079982733743, y: 1200122043830848407, lsp_prev: 12665306579360757, lsp: 12631289385734927, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 80, x_prev: 132616711587261, x: 135079488951242, y_prev: 1200122043830848407, y: 1175523545784851098, lsp_prev: 12631289385734927, lsp: 12631289385734927, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 81, x_prev: 135079488951242, x: 139652330164575, y_prev: 1175523545784851098, y: 1215318503251330730, lsp_prev: 12631289385734927, lsp: 13058895983369261, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 81, x_prev: 139652330164575, x: 137106180485017, y_prev: 1215318503251330730, y: 1240749733387450858, lsp_prev: 13058895983369261, lsp: 13058895983369261, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 82, x_prev: 137106180485017, x: 138408018485590, y_prev: 1240749733387450858, y: 1252530786192004782, lsp_prev: 13058895983369261, lsp: 13182891611987465, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 82, x_prev: 138408018485590, x: 122692027075710, y_prev: 1252530786192004782, y: 1409721168057521902, lsp_prev: 13182891611987465, lsp: 13182891611987465, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 83, x_prev: 122692027075710, x: 120385948945699, y_prev: 1409721168057521902, y: 1383224522492562043, lsp_prev: 13182891611987465, lsp: 12935110409236978, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 83, x_prev: 120385948945699, x: 121637476693937, y_prev: 1383224522492562043, y: 1370693119932930512, lsp_prev: 12935110409236978, lsp: 12935110409236978, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 84, x_prev: 121637476693937, x: 125602915195915, y_prev: 1370693119932930512, y: 1415378355272491288, lsp_prev: 12935110409236978, lsp: 13356801044707748, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 84, x_prev: 125602915195915, x: 141542521530633, y_prev: 1415378355272491288, y: 1255982347648321570, lsp_prev: 13356801044707748, lsp: 13356801044707748, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 85, x_prev: 141542521530633, x: 137874586736129, y_prev: 1255982347648321570, y: 1223434804306543391, lsp_prev: 13356801044707748, lsp: 13010672723936269, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 85, x_prev: 137874586736129, x: 146358977841475, y_prev: 1223434804306543391, y: 1138748708157457282, lsp_prev: 13010672723936269, lsp: 13010672723936269, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 86, x_prev: 146358977841475, x: 147755891870552, y_prev: 1138748708157457282, y: 1149617423349913344, lsp_prev: 13010672723936269, lsp: 13134852268804908, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 86, x_prev: 147755891870552, x: 142967660053546, y_prev: 1149617423349913344, y: 1197396390491330336, lsp_prev: 13134852268804908, lsp: 13134852268804908, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 87, x_prev: 142967660053546, x: 142031095019753, y_prev: 1197396390491330336, y: 1189552381639927546, lsp_prev: 13134852268804908, lsp: 13048807331408615, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 87, x_prev: 142031095019753, x: 146787959669584, y_prev: 1189552381639927546, y: 1142086409129319887, lsp_prev: 13048807331408615, lsp: 13048807331408615, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 88, x_prev: 146787959669584, x: 148846641957589, y_prev: 1142086409129319887, y: 1158104024382905995, lsp_prev: 13048807331408615, lsp: 13231815178872617, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 88, x_prev: 148846641957589, x: 140218041623960, y_prev: 1158104024382905995, y: 1244229530434287960, lsp_prev: 13231815178872617, lsp: 13231815178872617, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 89, x_prev: 140218041623960, x: 137914133060874, y_prev: 1244229530434287960, y: 1223785719948755637, lsp_prev: 13231815178872617, lsp: 13014404552232014, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 89, x_prev: 137914133060874, x: 145244490298460, y_prev: 1223785719948755637, y: 1150611669195083046, lsp_prev: 13014404552232014, lsp: 13014404552232014, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 90, x_prev: 145244490298460, x: 143629828364364, y_prev: 1150611669195083046, y: 1137820486139815603, lsp_prev: 13014404552232014, lsp: 12869725304280913, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 90, x_prev: 143629828364364, x: 136380961645078, y_prev: 1137820486139815603, y: 1210181071583586547, lsp_prev: 12869725304280913, lsp: 12869725304280913, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 91, x_prev: 136380961645078, x: 132552910893135, y_prev: 1210181071583586547, y: 1176212733883199508, lsp_prev: 12869725304280913, lsp: 12508487481683854, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 91, x_prev: 132552910893135, x: 125084878445197, y_prev: 1176212733883199508, y: 1250848784448499731, lsp_prev: 12508487481683854, lsp: 12508487481683854, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 92, x_prev: 125084878445197, x: 129271625928968, y_prev: 1250848784448499731, y: 1292716259286098467, lsp_prev: 12508487481683854, lsp: 12927162217916408, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 92, x_prev: 129271625928968, x: 141913669764104, y_prev: 1292716259286098467, y: 1166419265555060824, lsp_prev: 12927162217916408, lsp: 12927162217916408, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 93, x_prev: 141913669764104, x: 139538138214444, y_prev: 1166419265555060824, y: 1146894255948418274, lsp_prev: 12927162217916408, lsp: 12710770930542280, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 93, x_prev: 139538138214444, x: 127107712992456, y_prev: 1146894255948418274, y: 1271077129921088645, lsp_prev: 12710770930542280, lsp: 12710770930542280, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 94, x_prev: 127107712992456, x: 126862178544247, y_prev: 1271077129921088645, y: 1268621785439003292, lsp_prev: 12710770930542280, lsp: 12686217486433585, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 94, x_prev: 126862178544247, x: 129409579850315, y_prev: 1268621785439003292, y: 1243152837926929817, lsp_prev: 12686217486433585, lsp: 12686217486433585, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 95, x_prev: 129409579850315, x: 132005046893747, y_prev: 1243152837926929817, y: 1268085785120797049, lsp_prev: 12686217486433585, lsp: 12940655059215563, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 95, x_prev: 132005046893747, x: 116775626781478, y_prev: 1268085785120797049, y: 1420498156671581809, lsp_prev: 12940655059215563, lsp: 12940655059215563, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 96, x_prev: 116775626781478, x: 113631344859294, y_prev: 1420498156671581809, y: 1382250049616868735, lsp_prev: 12940655059215563, lsp: 12592217042778612, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 96, x_prev: 113631344859294, x: 124657159868438, y_prev: 1382250049616868735, y: 1271873141421314002, lsp_prev: 12592217042778612, lsp: 12592217042778612, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 97, x_prev: 124657159868438, x: 122789353885110, y_prev: 1271873141421314002, y: 1252815974820625112, lsp_prev: 12592217042778612, lsp: 12403541010365428, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 97, x_prev: 122789353885110, x: 124035413701222, y_prev: 1252815974820625112, y: 1240354137015784790, lsp_prev: 12403541010365428, lsp: 12403541010365428, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 2, index: 98, x_prev: 124035413701222, x: 120657988196394, y_prev: 1240354137015784790, y: 1206579881967399690, lsp_prev: 12403541010365428, lsp: 12065798469678554, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 98, x_prev: 120657988196394, x: 121870360148274, y_prev: 1206579881967399690, y: 1194457368578490476, lsp_prev: 12065798469678554, lsp: 12065798469678554, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 99, x_prev: 121870360148274, x: 126570859787022, y_prev: 1194457368578490476, y: 1240527195751169020, lsp_prev: 12065798469678554, lsp: 12531172341380642, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 99, x_prev: 126570859787022, x: 115428352397937, y_prev: 1240527195751169020, y: 1352028730610454811, lsp_prev: 12531172341380642, lsp: 12531172341380642, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 1, index: 100, x_prev: 115428352397937, x: 116384750070389, y_prev: 1352028730610454811, y: 1363231152755288829, lsp_prev: 12531172341380642, lsp: 12635001113180792, pn: 0, pd: 0},
                AmmStableSwapBacktestStepData { tag: 0, index: 100, x_prev: 116384750070389, x: 130150433190196, y_prev: 1363231152755288829, y: 1225507288607698904, lsp_prev: 12635001113180792, lsp: 12635001113180792, pn: 0, pd: 0},
            ]
        };
        test_utils_backtest(admin, guy, &s);
    }

    #[test]
    fun test_swaps_does_not_result_in_more_tokens(
    ) {
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13972565209009, 16761968003494, 444480, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 342876743349, 10564466746490, 84336, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8138730043267, 15591903712419, 200351, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13700070794213, 15644264573032, 632939, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10873209828575, 3865332557645, 190878, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5410636146667, 8584343535964, 382700, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1138991275044, 14666241923254, 974430, false);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13324830927109, 8682861563150, 65104, false);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4895889560269, 14120686709792, 745669, false);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6222842105588, 8578817899103, 966455, false);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15779805061182, 4980619347655, 132952, false);

        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15515767772181, 13180706102868, 151799, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13811185156921, 17250357094755, 850350, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8527220094674, 15839278602930, 733898, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10390906114528, 11054417126046, 296169, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8487945220072, 3792592316393, 662828, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14913871978382, 11193903915176, 124457, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7927131278931, 2475163659027, 696142, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13287040264750, 16940089846009, 621244, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11887446964283, 13682714299472, 466464, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12012350848998, 7749200930977, 943732, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15749014038172, 2793565137362, 733482, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12919565318170, 4781810484545, 675245, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2672505979726, 4898769451804, 197015, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16251709307313, 3186883589149, 439764, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9082563747286, 9270441815995, 861521, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3759066648682, 4778862065576, 763243, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17064529890447, 8038504232040, 565834, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1885524788057, 5692272446977, 248925, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5403771410283, 149321438392, 881130, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9836588614577, 15844777145285, 788882, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9726141109595, 15061195930666, 266274, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11185219215731, 2336619704504, 143553, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13310375901994, 15100741008048, 676701, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16011271951013, 17512728305042, 41389, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8341434900286, 11345518875173, 613401, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14208799074597, 11423403791031, 632431, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17472754354460, 7052228049651, 9961, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16279609137358, 3542704928283, 943857, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16033567075358, 16747978286230, 204264, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1527767565719, 17247419907890, 920722, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14461447075155, 8446683454968, 707733, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10879539903245, 4514037683957, 415247, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8398414782755, 7390761740545, 523213, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 118107692308, 15962090869870, 655018, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3881648795543, 4850578095121, 16114, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11030620202105, 5188466321050, 593568, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9043596718663, 16411530042363, 384089, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2231262605076, 3805229062449, 526701, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 882582096537, 17389352518833, 575459, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9890824374254, 12727137391671, 677533, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5920873560124, 3473363426954, 809135, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15940803346964, 3510925570000, 118072, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14856762532229, 15353716057406, 586350, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5949847980993, 11035744123354, 381066, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13184362258389, 14912987062212, 450685, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 117991765924, 15002557381745, 636150, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15190960536978, 9941583214473, 165964, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13940951727796, 8219487064678, 893360, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15583259420553, 4599621088573, 884667, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9726999030057, 3946311776488, 53607, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17127526996741, 5194032259704, 669936, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6840451338245, 2522758327880, 902203, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8403532183082, 12711096723654, 735659, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17209778516181, 16147373639703, 820636, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 175695340576, 13774169513547, 198241, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3279243590108, 8058211213260, 844981, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16515264878284, 11868804735869, 666502, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9023352421309, 7697311990317, 266321, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6533388263777, 9393403870190, 506939, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2538429263547, 226901708204, 669652, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9215414488369, 9659295709201, 702866, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6297464004300, 1862033443530, 795521, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17531648030139, 9012853112744, 473313, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17121941784523, 11524839565214, 249303, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9657347506483, 9251876052314, 227547, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8827868683020, 4908676865856, 312032, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 290242222943, 12261234997160, 5896, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7884248156741, 6846918483643, 345916, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11086033132822, 276609525266, 752386, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10334368754588, 1899010441336, 906494, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15024616512021, 5868233956053, 683623, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13358473436671, 51515699611, 683445, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14435191619884, 2542085556768, 157682, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10120947385601, 1411330019329, 119146, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16192911737221, 3130384830269, 747477, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14150643792257, 179807067358, 503200, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6667350626197, 4162492337495, 373342, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4385820142384, 15095464273714, 349747, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 869978704401, 5104320292856, 252291, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10952363289427, 14469782549668, 298226, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12361001881367, 16868768277011, 358538, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7055413216287, 4904000280199, 766252, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8285325408560, 13311757557936, 153873, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6854969776059, 5036312178822, 18600, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11077193199060, 8996235659175, 272782, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1820891903881, 7502609502406, 608553, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11133903051881, 4475102191219, 735826, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14191190801301, 14030854008761, 272183, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 837585114354, 611379054939, 517178, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14282629207194, 12398307108894, 236251, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2712282512483, 1108418719586, 407645, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13457900533556, 12545970322326, 28275, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9204775011421, 2656106023002, 750308, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5079041818367, 1720521944503, 56546, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9852838696786, 1867162518464, 325107, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12107982262905, 14455152943994, 407004, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15475030720685, 8227352993627, 297161, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13853412287647, 16751761407002, 573459, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10863499009249, 14833035454205, 750801, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17557728854114, 10499341740325, 443844, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15261048841164, 6584921016828, 115901, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5855821097131, 13202865641023, 98470, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6145980525980, 7436692031694, 546064, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7597350241168, 3255482249006, 713737, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2061084854647, 2224316117218, 604627, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6556452080102, 6472858867856, 31238, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1719461648224, 15791649742798, 176001, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12483395043478, 452579723539, 350098, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17043228998807, 1059958009288, 130755, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12947394567831, 6773348596183, 826033, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5186847450819, 5736013529965, 256270, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3851841265657, 4275678751388, 222454, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 347777809571, 4729363596864, 664864, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16526057362781, 11539082003713, 591941, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11336169982651, 14054819883103, 49773, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11596094625105, 447772489342, 508364, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15451926482114, 12203573250077, 797595, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 547430525483, 540698170984, 628523, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4709138963100, 1717563381524, 696089, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3832734927868, 360596754446, 31304, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8912107731798, 9932533782697, 670902, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15381140989754, 16914162315751, 296498, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10690370455483, 13794030666920, 508448, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9999608583286, 3177383637274, 314424, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2605835673427, 4963026473767, 905284, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13961005319852, 11911333785114, 278141, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11453225653015, 17231460004900, 643150, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5717099037892, 4848733876147, 793990, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16291769466514, 7416489667396, 425525, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6720133166289, 1596942160515, 548639, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1859879282902, 6865374515086, 12766, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 95965816095, 5904847022324, 258891, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2262752177202, 16420914251850, 248727, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16886785079383, 14723242816540, 764474, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17542753874038, 5602326648365, 621112, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8837081024590, 11129605098321, 766664, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6738819249001, 10179032353925, 545510, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10920536326091, 16849916058294, 820759, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12356464006603, 8778596274411, 208139, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12040333336858, 2814433242038, 687335, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17116179474452, 11715249544571, 643871, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16775509012079, 7466698780643, 295450, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8185000249251, 4696963485888, 14567, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4286014089528, 11393666470422, 993407, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14157404746822, 16599974452113, 712946, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9875518437907, 10565315439958, 138715, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6072007481176, 5692461684427, 54824, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9782611064568, 13235925530290, 376252, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17466985300753, 1226281436069, 830233, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12030202492151, 16267595858579, 146317, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5832985658715, 3338411784591, 845595, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12242392711248, 8196816552696, 405422, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16049056694047, 13816434514042, 466593, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 693161312005, 13571980688041, 605943, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6383545929924, 7256969840162, 936100, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2446443497975, 241614594594, 867636, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14225752618285, 10317680806244, 153983, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1668399570236, 3219737767452, 123455, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1815658106293, 16026962728723, 794159, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14833723708583, 541007255953, 26473, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7668184107563, 4316897353281, 104976, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11323665695045, 6159547642152, 907706, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5527987587722, 12871347906208, 149668, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3976909920488, 1758301789313, 415150, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10022576388054, 2917805658685, 743996, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14369140482480, 10585481831044, 245972, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17137457648974, 14828146487157, 333186, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6088203829578, 16172526652793, 39551, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11774273620776, 14795371446537, 277169, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3149567504428, 13223093648008, 406276, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15953192386038, 15110828150271, 353213, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12098225250823, 197786550314, 14582, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13532287341273, 15372091786412, 395762, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17332180746001, 13670035715663, 896586, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6129563522789, 4478632333710, 981524, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12129003085521, 2273539787686, 821922, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13058829200761, 3110709927372, 336065, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5785336808305, 904843831520, 795722, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2575959357844, 4300273083593, 135030, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13821356619489, 8289737890138, 611996, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4208039261716, 4971517231115, 934831, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5785781497986, 75140950242, 293878, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 279970184092, 8910333162279, 795230, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7788220682422, 17212684828348, 985129, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12678848705459, 6311369179866, 836218, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4587356724878, 1738575646610, 749374, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7539914814665, 4142680494728, 57133, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 747843151324, 4639846009929, 43692, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17584785988421, 9998831393491, 486690, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9496091552563, 15714633179635, 271688, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11493296073045, 2495592982692, 806830, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16007461644379, 304241273558, 377035, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12349639637441, 17513352559034, 222283, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13453936169131, 9009529427941, 885509, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3402128535159, 4385232973784, 60251, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8417110117956, 5155335285744, 643054, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12132577599543, 8273900059812, 934143, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 11424311732972, 2396084316470, 952671, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 80414030941, 10470063543848, 827853, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4246218198086, 17040582148597, 591752, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 14455355084763, 15686141384674, 566424, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10098670518034, 2678286071076, 458029, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10273029302212, 2575997507211, 764212, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15217344617989, 11356420930359, 220010, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1832537923107, 10253726555258, 995508, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9087684472839, 10325843344326, 711443, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2679366960801, 493310030994, 113494, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15251476424064, 14442503434896, 399594, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 17431479582278, 15276250882764, 900810, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9876368362671, 977505640789, 408353, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5915112364029, 290106097632, 432710, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13678521326129, 14650133769507, 564486, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1646811286793, 9293920261370, 645663, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7697602380906, 10317415326331, 708716, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 16047065281066, 2905758505115, 895835, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 733739116968, 12051634291338, 253323, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3715213587821, 14674989870268, 761171, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7777926443741, 8319057434104, 353467, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1904241485573, 7127530739435, 932518, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12802164774739, 11128222839716, 431865, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3417839091381, 9459875773372, 197116, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13943058890605, 7732143076062, 602145, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 13532259948373, 10306686791156, 809121, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9211568712857, 15945393322620, 825920, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 12656885358421, 1316948153263, 127692, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 9743420775025, 4875069020418, 580666, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3111011771701, 1234811301403, 439178, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5119494076952, 3814764689549, 319711, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1717535869768, 7307665125181, 417306, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 6638111333135, 6842125047793, 115284, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15077159062646, 739721079205, 594498, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7227809856619, 1517446616081, 875312, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15616680760272, 12525715984128, 59444, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2770542078040, 7621581648331, 130398, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2587966052101, 12611551131255, 357493, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 15573324885773, 10872765840363, 611480, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 5192419594451, 5698643533813, 499874, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 2709892402667, 4093827785620, 709791, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7742276914630, 15085723595792, 689816, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 10292566691140, 2155977855833, 64620, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 4719445482273, 12267489871250, 185580, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 1704521096488, 14754901153674, 860033, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 3992260653638, 12911546993870, 661659, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 8338921395703, 10822503153575, 471413, true);
        // check_swaps_does_not_result_in_more_tokens(1152921504606846975, 1152921504606846975, 7081358155868, 16900601342163, 510058, true);
    }

    #[test]
    fun test_withdraw_one() {
        check_withdraw_one(1035133858339476284, 1514493601419284180, 668266365010822675, 846227236408461505, 275148, 668266203823519868);
        check_withdraw_one(549256152074497929, 1152921504606846975, 255542825394813894, 10927591245884986, 794249, 126947765420983792);
        check_withdraw_one(486966262337048995, 1098512304148995858, 885493441740400850, 1044329034977142354, 794248, 855477306852517527);
        check_withdraw_one(606741306958588344, 1002731438221695955, 38700001273816106, 434195875590700235, 405343, 38699982579241436);
        check_withdraw_one(612339456408931323, 612844562857420712, 77257958512261365, 774064262770194452, 889204, 77257958512261283);
        check_withdraw_one(25707202511163293, 38612831529013057, 155152024224954732, 1049246113795117824, 52125, 155151793700782984);
        check_withdraw_one(483123676682535056, 586279347816152928, 523066219049763155, 1077402372457517993, 612871, 523066213737671402);
        check_withdraw_one(5359796924597696, 11764485296543977, 422932644473303140, 744814318016639151, 971274, 422932237484216188);
        check_withdraw_one(152220328115074951, 317080062630144471, 267494339518412853, 450178938460324980, 533794, 267493988720457899);
        check_withdraw_one(344682790443992391, 530531098812020377, 254371088459721391, 719695223515536888, 396000, 254371042419428957);
        check_withdraw_one(171324120642000574, 386139377982820538, 634812182911539327, 902977379667508636, 675291, 634809479941887248);
        check_withdraw_one(111467934544185622, 150736234114722774, 837408173052968732, 196191420408351893, 843826, 764336598926410208);
        check_withdraw_one(361781004118726170, 1014750380837260765, 1125526901648846698, 119974710861191340, 486681, 444049680704427593);
        check_withdraw_one(21138095692695391, 148286673897913382, 1081636028088334256, 437648198287462969, 916865, 216572297983285461);
        check_withdraw_one(151917748138548013, 218911461404514670, 454775098913306603, 250680935969000530, 752660, 454774907291772964);
        check_withdraw_one(46102395607238941, 50629234477984069, 131874565730021970, 620091490624580749, 303103, 131874565364405973);
        check_withdraw_one(94654287456611685, 284970080707195735, 308939484247863855, 676533006229357456, 317653, 308930472732017122);
        check_withdraw_one(555801691519210684, 605360513458717352, 862970040395163683, 432673687113878857, 785654, 862970039051550269);
        check_withdraw_one(399774802498158099, 453655227289720676, 1094463890539596424, 957350674680027569, 329385, 1094463882501103814);
        check_withdraw_one(311100831209519592, 574034503667742366, 254312728373806625, 892242455105728496, 259619, 254312515437394001);
        check_withdraw_one(470895439733186551, 808064496941892075, 876676078372908637, 376306168367955663, 632128, 730168955166607423);
        check_withdraw_one(116631996875530051, 635363871809491539, 767191285254360807, 137182640641463773, 618923, 166013605053124310);
        check_withdraw_one(55574218544569389, 98148969474804534, 39738150466134607, 215360531182754740, 682551, 39738139461766080);
        check_withdraw_one(9153901535485833, 77809966027826060, 710683589995263585, 256746138075503724, 255675, 113812781101958447);
        check_withdraw_one(11914086958177526, 143859177309514442, 1151182959610233318, 291050850034862661, 489113, 119442623530173302);
        check_withdraw_one(288486036735773790, 731056859142221057, 852725530201459423, 817388662083672241, 820751, 659051812146649207);
        check_withdraw_one(284683443194232952, 862567843041969147, 42361679843100743, 705291001057314329, 831014, 42361548713781917);
        check_withdraw_one(257096221288061617, 1028407107343262101, 1050095779784141860, 993974458494381039, 551921, 511006384287252231);
        check_withdraw_one(252773313262553279, 560972391174477302, 587042055258969071, 1150376999455159810, 700802, 587041366668283748);
        check_withdraw_one(17125128982668728, 18898000757275471, 10570355409345797, 1063604996119236680, 256475, 10570354922402552);
        check_withdraw_one(918153193490158680, 965269490121114350, 530522884138222903, 707752457279101193, 794557, 530522884062398260);
        check_withdraw_one(269778247050579606, 304598168099948426, 308696242570383859, 434082609743006276, 370641, 308696241208236282);
        check_withdraw_one(462510921484376322, 787758233327173016, 617280950792421461, 352370338597262615, 228122, 569303373865636592);
        check_withdraw_one(404868318270099343, 523374354482102711, 862596792018443943, 122218751926649716, 716503, 761827007326271505);
        check_withdraw_one(236154429836211158, 252790600483051147, 209407338992188402, 503000739175446141, 615513, 209407338900968125);
        check_withdraw_one(88316164581765943, 139466597562115701, 301900253285790882, 944488551662394135, 804690, 301900221050858774);
        check_withdraw_one(6071733231737356, 105968927726966382, 776618552080767265, 329374260726504648, 271806, 63370473975637804);
        check_withdraw_one(191492007773275775, 629830791282861241, 835632672340711172, 898436525735151345, 29727, 527215243219133628);
        check_withdraw_one(257178844320553788, 337064746971150364, 789367466930304030, 217160895473813466, 241846, 767975707518614071);
        check_withdraw_one(606876325452480340, 624119686143352599, 859427713404607523, 395738257533366174, 914243, 859427713364702627);
        check_withdraw_one(270664601338901298, 979592320989300068, 434627189090001661, 337959119129630284, 615597, 213468141194798882);
        check_withdraw_one(570320124778557116, 624772735802867701, 864674727684427171, 618619724141859952, 366306, 864674725248851478);
        check_withdraw_one(169404126104288090, 928525995827081168, 217113479688003215, 618023024708933952, 668380, 152364936876209474);
        check_withdraw_one(4752951060374792, 116437321182446027, 15462382271805734, 818960015629830063, 954385, 15457976155762530);
        check_withdraw_one(352947492265242195, 874656905932491944, 1047360640639708435, 467463895434167103, 177080, 611272715133665388);
        check_withdraw_one(65449409402898687, 84518004083648487, 846159603275461952, 508189380531590699, 48202, 846158884798689629);
        check_withdraw_one(654058354161225053, 820637219814353469, 920426510297346876, 919472776427498049, 93515, 920426371594193701);
        check_withdraw_one(163730078385997969, 756876922924867896, 632670580987152024, 568713730571677447, 263071, 259887286934507236);
        check_withdraw_one(12198280652716570, 92341256458610745, 821417946185822667, 436587894519579632, 945375, 166182616236676536);
        check_withdraw_one(49785462592550390, 1088739584002106827, 13469893772724765, 57170101344657225, 73768, 3230051906144716);
        check_withdraw_one(68365940744168600, 626815499535547607, 1106521182226220285, 323604100782461518, 103494, 155982548430686802);
        check_withdraw_one(432178573033958772, 867848692010638062, 471904280579089193, 667003152304530894, 165234, 471902055386475842);
        check_withdraw_one(269296053707759962, 311507353538797428, 527828057601526897, 991256219768400120, 448433, 527828054478638087);
        check_withdraw_one(92371656703500030, 220829220016903753, 927105880172381016, 104028654893157964, 75195, 431321981210406073);
        check_withdraw_one(117588333382925567, 787180156389456409, 199874955910827, 855937559129111350, 785310, 199315790273237);
        check_withdraw_one(6588093076181896, 628960011331241220, 537274020070843228, 992166604286856321, 681468, 16020239627150193);
        check_withdraw_one(195740980980324148, 519059242549287886, 181172272614999268, 246272377049073247, 62061, 161186929783566179);
        check_withdraw_one(88525494516438314, 107429663079196610, 856276920845629306, 12978191184627586, 592445, 716295923560261077);
        check_withdraw_one(344796974353759714, 604578386255064407, 472867975266055289, 287925034419329497, 247737, 433886834588927978);
        check_withdraw_one(324430094123018352, 552583657639608640, 482635302053827573, 183403156372546400, 846643, 391041117859687570);
        check_withdraw_one(794566995215271791, 949072322916853051, 385131497514341665, 91077256500522602, 749512, 385131434559695340);
        check_withdraw_one(94676079059725373, 113068197180656741, 967313856040530623, 538430321816380659, 974334, 967313844111871964);
        check_withdraw_one(40824380913353105, 1082811612697944565, 539936136677550548, 365348619591994729, 648877, 34131235729839484);
        check_withdraw_one(34811779006128140, 61424456786637563, 632293534165016143, 944018340853300096, 122906, 632292219653031773);
        check_withdraw_one(653736129532084468, 988837112043143521, 500983749228866905, 347881915669996999, 213084, 500983082602646768);
        check_withdraw_one(155564239786595337, 387626498865548031, 298467072309853125, 54083647578041619, 628536, 141487552564397066);
        check_withdraw_one(432708084092724500, 578669218407272444, 162422674644340166, 646280279720121441, 254078, 162422660036223356);
        check_withdraw_one(89689885799555780, 310088758794010591, 758240829426176768, 593481450627997357, 229369, 390971246684545401);
        check_withdraw_one(210099838241403884, 233875606359948234, 927678192369488759, 311404603428139697, 834828, 927678187187041387);
        check_withdraw_one(355275078099756286, 358262164404602233, 410792227549145833, 279500282885522202, 242231, 410792227547859978);
        check_withdraw_one(39142406123197285, 958539774860622460, 667681975001408035, 76104573813327978, 468898, 30372935677312222);
        check_withdraw_one(50500300055440455, 245367292660276412, 933910178767015456, 789386864524103074, 600365, 354680577246358519);
        check_withdraw_one(87156218737827132, 90230173493759990, 874027633289126514, 359919673210269871, 846922, 874027633193291936);
        check_withdraw_one(402726595215917134, 801807956985121706, 782403279192522656, 301375950763444439, 284735, 544353409260115677);
        check_withdraw_one(228293784336481698, 312006958715866070, 450367174789611872, 432484628092059728, 916582, 450367153364298674);
        check_withdraw_one(66954625713365604, 118367724593135022, 536662739523206569, 748665176374774235, 740946, 536662533568614804);
        check_withdraw_one(225091430581048042, 544194542705196817, 204033722568031215, 1137938248295027401, 613452, 204033474016722660);
        check_withdraw_one(401776380699720834, 1128929562848662367, 1142282501928020242, 852492519221923546, 107093, 709922788728337406);
        check_withdraw_one(245628263073832183, 572817841160738745, 480441758121915684, 241524542162291599, 40029, 309584634384914972);
        check_withdraw_one(275307817793932127, 573271892550173392, 513483748799874549, 622871914523259211, 955947, 513482407196249519);
        check_withdraw_one(40621684933218575, 242231667779188389, 257787177354692122, 1099882805027870675, 868309, 227672871540022688);
        check_withdraw_one(49841287668027735, 118692186677284423, 749739623278721748, 735351933977313343, 772567, 623619897711593883);
        check_withdraw_one(501613444280137339, 798711157266163028, 989168570842823961, 366247988811903923, 11645, 851240566527667447);
        check_withdraw_one(10020539924778342, 1024030069997356647, 648391882411164064, 93271671433580392, 528573, 7257484930015203);
        check_withdraw_one(577552901128479015, 599541918511647625, 717758820077557130, 913357100925839942, 597333, 717758820020086564);
        check_withdraw_one(562673667531225705, 887552511715143782, 861203044339001640, 919010282524287199, 348944, 861202640975496144);
        check_withdraw_one(555897590319151000, 869871490735228152, 210176941402344149, 1019922001510534281, 564127, 210176908385686724);
        check_withdraw_one(146088338687628550, 227720973857574953, 19852591496204207, 154588395434960962, 657262, 19852588228285024);
        check_withdraw_one(58993329616385491, 262826084186832814, 1067831335136781184, 287842454745229768, 376713, 304291707069217690);
        check_withdraw_one(448527178315640227, 768793242214477364, 92041242611316720, 863480380706800160, 468930, 92041200778191574);
        check_withdraw_one(49893598687586151, 110277821981674478, 465968085945966475, 266782663690229562, 416867, 331522412572991256);
        check_withdraw_one(400525717595218830, 624656947232642785, 211518048759716664, 737489626482461151, 743258, 211518026079998985);
        check_withdraw_one(1019509963389296054, 1035208708538513285, 1133157425042605466, 899340105737729403, 519257, 1133157425033580903);
        check_withdraw_one(280390049032867895, 451469445278310334, 369682805395356883, 713117431868510388, 78494, 369682295946284579);
        check_withdraw_one(546856440736769550, 746037850723179554, 972293959675166590, 199214090655031589, 668961, 858732358514947571);
        check_withdraw_one(510890775687961, 257107208587290466, 670211834926128270, 487761857988799905, 741506, 2300978615722700);
        check_withdraw_one(670749382125433964, 829090345167971443, 415334898524275539, 920143847148047046, 668590, 415334893455564152);
        check_withdraw_one(117230687546531443, 1109183667542804134, 901946700202170263, 940533112303049901, 981185, 194733444860190085);
        check_withdraw_one(322086248642379871, 948147634829971832, 1098940145557288867, 1077475334785062355, 972871, 739329234212056238);
        check_withdraw_one(577680687643941328, 1038101160926385161, 450600538380269236, 82387767819397381, 41493, 296598697480319089);
        check_withdraw_one(22801789224047138, 73155225200209772, 341102678678389791, 716579818001587070, 82746, 329603887363359003);
        check_withdraw_one(985853553725882502, 1099119890676792757, 1040260472908901381, 323952252054952524, 299148, 1040260453364053479);
        check_withdraw_one(418674117402824628, 528620263032037108, 86834187225368769, 479020953050198402, 349140, 86834183853476940);
        check_withdraw_one(190545579814340326, 542634301623766513, 1078613902154420584, 174261271504600375, 6041, 439986643974198604);
        check_withdraw_one(524940830988137465, 598051333761468431, 425858650963145331, 192526587295610732, 433633, 425858645431294031);
        check_withdraw_one(828739611946528738, 997594405859503852, 820117131807787589, 79487825913596435, 495969, 747336373408650710);
        check_withdraw_one(85903905087148630, 198326814950158896, 904175661579640066, 969645378624578831, 666444, 811631076135092604);
        check_withdraw_one(303797288861465782, 918016329692053430, 639173617725473934, 360158776303303656, 576310, 330707095264257029);
        check_withdraw_one(204868542157758124, 428850835931826814, 370839302884615475, 163471855321999010, 349687, 255248594671204903);
        check_withdraw_one(398475920973022284, 678301618778722267, 959596194579123039, 185255550659149987, 435548, 672556475065227524);
        check_withdraw_one(82229872705556597, 703073364448793340, 921553796164661464, 1041998281128402258, 170201, 229652418722376568);
        check_withdraw_one(63577262826331120, 480962796824051722, 276929262307584038, 1148206836739569909, 144668, 188375908107158208);
        check_withdraw_one(512299545880467383, 757096827787626964, 768056699857723037, 593650209176122375, 255318, 768056240873445780);
        check_withdraw_one(825587553242246701, 890195745841150423, 781959957331015253, 789791836512464577, 681598, 781959956820907824);
        check_withdraw_one(496416180632757945, 733339458935980640, 991203170578268386, 70263886598613069, 535115, 718534923681726219);
        check_withdraw_one(1086794657518179576, 1274458917818801438, 663778654284658098, 610680263534143340, 846186, 663778650505299596);
        check_withdraw_one(643934046976596955, 761743152811828351, 21228720038898951, 12583776121167172, 460894, 21228719619824504);
        check_withdraw_one(29546553037365700, 1148584790146796127, 488669471309039393, 199710093353020754, 822709, 17708097887922306);
        check_withdraw_one(44618757958722703, 61128666689361209, 358783681186590255, 30404055881487551, 612575, 284074333846399444);
        check_withdraw_one(62991267136928, 219737961447499, 705234874217426644, 1109173270027284291, 803561, 520127212386366781);
        check_withdraw_one(775953904548661802, 1096869462450494620, 973946600178088383, 748799167382304690, 452319, 973946407108398026);
        check_withdraw_one(508337525269740683, 574788276477022801, 223198700304324747, 958125054246111851, 327018, 223198699067347323);
        check_withdraw_one(981835553257695495, 1151254075906174787, 1050782285582666449, 982347305950949645, 251018, 1050782265708603485);
        check_withdraw_one(9741483877525672, 14922150674515371, 256999215790710361, 477943368671449592, 814794, 256999191856460561);
        check_withdraw_one(14417632326066571, 89887979615537342, 964579794084407853, 138408791239174900, 631709, 176914693981909426);
        check_withdraw_one(429086081397381327, 861029698669953708, 350143581388911590, 183546498618164169, 192021, 265959413929530031);
        check_withdraw_one(8125066587121728, 273805011447421200, 1096154014760519504, 215619452448747670, 611061, 38926457431099906);
        check_withdraw_one(305378375797596880, 357658350030468209, 465321890686894356, 375915483039438642, 249590, 465321880893905498);
        check_withdraw_one(240498414382594106, 336664738900864103, 761738163845495402, 160017763698820172, 42361, 658463864393286779);
        check_withdraw_one(356629660223235544, 632420001434368800, 110195782950504016, 557299918986630022, 78220, 110195517290484034);
        check_withdraw_one(142093745196385644, 242503422081053154, 338675092581926988, 680190836156421928, 297984, 338674913338693905);
        check_withdraw_one(184031285927069496, 1152921504606846975, 66420182629322015, 406703610735219725, 741874, 66417322307653547);
        check_withdraw_one(309816830168060676, 356642418165002550, 701432111467670092, 517239350274789067, 734372, 701432107694024422);
        check_withdraw_one(560379640038520318, 820383930192263124, 574051711576200525, 18918424872033760, 662471, 405040859417606182);
        check_withdraw_one(197401513823612176, 456302424308373588, 668759270664505581, 674467496130782945, 225866, 581092412132830303);
        check_withdraw_one(156986236006755342, 716529286711349630, 850565705112644630, 224066382631201056, 96543, 235444927704929873);
        check_withdraw_one(238785854037856154, 443804704410028806, 342896373705878235, 199808781263129852, 177841, 291998181826192269);
        check_withdraw_one(215413639525229044, 635516850943945949, 731315520451189807, 857756295467713924, 287628, 538627691478227875);
        check_withdraw_one(477011755697986873, 693761012357986837, 1137521062490161459, 611098442824067233, 755474, 1137520381036336023);
        check_withdraw_one(844761869717411025, 1145960696540556124, 1051861996135010588, 72730244774579756, 763572, 829010335828485070);
        check_withdraw_one(19847922502915064, 210624411730250854, 902253710975505909, 698715979711393964, 608602, 150865352596496976);
        check_withdraw_one(244248435736357591, 556796051707416568, 145078663035492013, 1748062156400159, 291494, 64409441557143098);
        check_withdraw_one(264819842176387943, 427405286746977520, 239652859127049009, 46528143347106580, 562426, 177317510937653588);
        check_withdraw_one(39477427233920780, 622567544034942600, 679613485046424127, 766419966021435010, 209148, 91693909433289844);
        check_withdraw_one(1011922842259949, 94194375051571675, 556630575652424194, 166994782426074425, 485478, 7773858716155206);
        check_withdraw_one(767837423626720634, 844336417939212979, 746496191898574377, 103055964259923553, 327335, 746496127117848909);
        check_withdraw_one(342384878561623424, 1036028932876496315, 560200442370593203, 930167156135617846, 902238, 492532262296672369);
        check_withdraw_one(155052628782023744, 440857334599048241, 754313313697064447, 1151599454555331308, 642071, 670320149889295709);
        check_withdraw_one(19310857640872117, 77394702572190337, 963706895723915654, 995115848774194958, 640925, 488748366823288402);
        check_withdraw_one(552835807668762733, 706600905339880131, 1046243591680351161, 754255279468078815, 661428, 1046243550099203002);
        check_withdraw_one(123254829778197421, 352283726163773842, 377423075972901011, 148154087703918987, 157620, 183885890584512613);
        check_withdraw_one(83504771026893292, 816073616213700721, 1067804364465539813, 207469045174600025, 606498, 130492553428788791);
        check_withdraw_one(88082199548074359, 865929673776905514, 438751997108128449, 390255668082404275, 85921, 84326504775065804);
        check_withdraw_one(319572262303240885, 970176711332176963, 939969018604947229, 166885741394287940, 89717, 364595598503271046);
        check_withdraw_one(178588445263144658, 336444720295794059, 835411708191399377, 658138656871850174, 855323, 792791083117661504);
        check_withdraw_one(518936785968102013, 774598934794009811, 1115421039903030979, 379977897692565327, 873009, 1001831352220085582);
        check_withdraw_one(490424686138294384, 636414173128325716, 788400799593644846, 1060163532867026, 648170, 608383518025823317);
        check_withdraw_one(713867727906818314, 747219395314830868, 438825826352540657, 705020226968276890, 476090, 438825826276757013);
        check_withdraw_one(343460355597713258, 453496377857181476, 882395996841889848, 1016336156715028587, 172484, 882395871351090894);
        check_withdraw_one(157421296087451449, 260980317278545684, 691358604794383421, 314164777310142411, 89949, 606523146856642589);
        check_withdraw_one(6789249506433185, 976587328487590696, 364817792436763329, 617650226865913442, 882906, 6830129221334766);
        check_withdraw_one(76443237880224819, 96315359035107393, 538477966491654502, 664101316460779547, 315286, 538477944569448217);
        check_withdraw_one(77248319704756513, 1018997321005977986, 784062332955567517, 234934988050410469, 649409, 77248373371454907);
        check_withdraw_one(659550631417475607, 941678881793153452, 585005394631220606, 810362976499503844, 718154, 585005354629165619);
        check_withdraw_one(35592810089153078, 84927719631015462, 880124833936844381, 253453668448067478, 993760, 475077575865913049);
        check_withdraw_one(347461860931635175, 951996218424816924, 615927450975593957, 194828204663704467, 209201, 295911919143113865);
        check_withdraw_one(485051232618470049, 671868559311647080, 169256028412863210, 87323317569079448, 98095, 169255696820564105);
        check_withdraw_one(153826951501006069, 761732182881319601, 329579573834110957, 429263006608978530, 938285, 153243352217838695);
        check_withdraw_one(177699985515506148, 1008823219591123611, 574983589146426055, 771051343131183304, 922633, 237098321398401698);
        check_withdraw_one(474891931480821008, 542264648006737287, 964021490039111385, 423348041455467135, 491576, 964021477782161075);
        check_withdraw_one(116987689820265455, 965603897069208456, 820422950201724193, 319133549952700248, 386412, 138063023038117877);
        check_withdraw_one(169122045597380289, 262074576562140659, 1063911245164938341, 1051994248184324775, 912337, 1063911062601338994);
        check_withdraw_one(510160043119654137, 704655225294004063, 817351143394947653, 221613733726332067, 231321, 752195366351333988);
        check_withdraw_one(267707377283464803, 1063162567519352170, 398614451174592748, 774848949355551572, 49304, 295469897191824211);
        check_withdraw_one(185458112379817159, 298033877669640394, 169617098667242511, 57666159546325554, 585836, 141432002460212614);
        check_withdraw_one(892965130126367174, 901078738825339153, 529310579991194662, 989580217993849122, 324659, 529310579990174760);
        check_withdraw_one(355857065265053735, 532789316897998559, 162323944056137465, 593125937394547234, 667825, 162323929497315776);
        check_withdraw_one(287296475104182025, 853192008949382712, 387088284918650482, 1033080319118683067, 505133, 387086088095842391);
        check_withdraw_one(525968575954617977, 1152921504606846975, 112422017026117847, 408360740388578569, 990918, 112421960968965773);
        check_withdraw_one(12567481545225981, 361992391543424489, 1012520653219168198, 886040519203900724, 743416, 65913357726521459);
        check_withdraw_one(527502673272893646, 1026580909622928839, 918289036650853751, 919274118539468774, 917423, 918284962537595326);
        check_withdraw_one(768127246282262124, 1016023249174090995, 168403261296490157, 52457227536858126, 428402, 166972979376221801);
        check_withdraw_one(1534227109489087, 4956564342054462, 569822926045478848, 193393900544413323, 138818, 236242318814544036);
        check_withdraw_one(706204561041354287, 956983882477104056, 986371134279945669, 802144616077100182, 31133, 986369588958198774);
        check_withdraw_one(841460727499932739, 975064572990512302, 892799421156502955, 797329383591447109, 119025, 892799392241242860);
        check_withdraw_one(363256516204931265, 656388738405942021, 829814902618769452, 1041450236782321650, 114135, 829811920258630770);
        check_withdraw_one(701075750569276077, 1142126356911414047, 719240538781803559, 588757714481991346, 450434, 719239812678582980);
        check_withdraw_one(38313053974107980, 240168766809357264, 1032805067846685130, 290380827683481548, 617211, 211082101642982948);
        check_withdraw_one(350288048619848175, 573365505017612284, 500244733150728899, 416121045222812573, 861088, 500244467862016374);
        check_withdraw_one(894294230919060635, 1130759216878840697, 3971352119492830, 430634761889297466, 361459, 3971350345270538);
        check_withdraw_one(2610920113891748, 15141487662377265, 322790865614122840, 1063285522795205376, 713958, 239006028503777901);
        check_withdraw_one(176335111493091288, 497646639564687093, 1110507781620377067, 867509090094930919, 388440, 700886311177136773);
        check_withdraw_one(851322768014356799, 1024523228614563647, 898709342140132340, 843826187008948741, 740565, 898709332829991462);
        check_withdraw_one(31917791322351389, 105291180509878206, 1137184558943202488, 641355010292662243, 438326, 539143610289731857);
        check_withdraw_one(196658233566787961, 305949068874429910, 308631314862978672, 845910193472633804, 280239, 308631229530778506);
        check_withdraw_one(193014131993171227, 957508012748009606, 976329487875162949, 143784768136486740, 13732, 225804662554125516);
        check_withdraw_one(891438761556094226, 1000978197929785042, 794056844706291551, 876076281591904980, 760512, 794056843054232242);
        check_withdraw_one(44663835449673151, 236573005138019281, 1010237809433530003, 414119856217108804, 243391, 268912112976523328);
        check_withdraw_one(387912296870459976, 681940894130838821, 431177804228298772, 866088467085459509, 72692, 431176671622923216);
        check_withdraw_one(286837712901179791, 348116659021076452, 325124098720021305, 29885494502165541, 801028, 292517371885165727);
        check_withdraw_one(675306762720026749, 1072304863498605602, 274464341098254763, 197858124431149463, 124347, 274463159533330929);
        check_withdraw_one(242878831162686766, 252604166199581737, 380761263519821243, 343496569171730436, 516761, 380761263471446849);
        check_withdraw_one(203493538148141098, 518749951011594313, 912140447407167958, 1049039877345867004, 442003, 769323577654500470);
        check_withdraw_one(14815801285122739, 81340321285150484, 915272017391285353, 1050066233400865328, 566019, 357978049345046763);
        check_withdraw_one(20554770618278595, 741394765255826365, 605965920608735941, 1075814354257197170, 318615, 46626385329197814);
        check_withdraw_one(533007087768922440, 885057852516259232, 814806065976931604, 444452224572129938, 543022, 758360618503683270);
        check_withdraw_one(657681662710900639, 882275567129887910, 514259104170279565, 977858677821082644, 830272, 514259090061596005);
        check_withdraw_one(155003313199813072, 427384389598335254, 319854834861105061, 92219941643527499, 592685, 149450914857549428);
        check_withdraw_one(829132938393028730, 951219931617927111, 112308950272558664, 933819052323952637, 402865, 112308949266649682);
        check_withdraw_one(26091622468699904, 30585269661616765, 1042385602004450523, 730159715806498394, 385437, 1042385585303605449);
        check_withdraw_one(47697024219895662, 86847605448536041, 736894015173026613, 902332283942927843, 718615, 736893539052873249);
        check_withdraw_one(350993504714232572, 687029249002084720, 208343214810969167, 455741728167579780, 42887, 208341540982866689);
        check_withdraw_one(527771650461374645, 953954337701415723, 711155008990438960, 919294905398677358, 864957, 711154690707369280);
        check_withdraw_one(43202607743557240, 660270518771638195, 262850046215485940, 815695895550390372, 622790, 70570857466123458);
        check_withdraw_one(3085314555052408, 8938588768182585, 812888286074413579, 598147910441851305, 159650, 487044295340360254);
        check_withdraw_one(103328984538666428, 1053272010285201562, 783991733665282930, 972047264406221367, 759791, 172272383126549294);
        check_withdraw_one(626822532757475011, 766680897940965000, 1101714746464522408, 714186712780486299, 814702, 1101714726071611455);
        check_withdraw_one(1293175299283903400, 1782963232080627788, 908133382881780399, 874829849198847389, 294356, 908133234756681388);
        check_withdraw_one(147917979649295136, 295068253673603979, 842514946702786159, 515879819593232911, 460878, 680964280407324165);
        check_withdraw_one(550515225466304680, 725245359735772190, 826931287899255411, 954839199849522947, 608262, 826931255505147608);
        check_withdraw_one(87606872444561779, 958914135527414937, 534942846906404568, 536927611936812816, 820039, 97926612020383605);
        check_withdraw_one(117375756196386982, 629379413161353851, 710860624312412686, 381865887569378583, 688097, 203787461525863964);
        check_withdraw_one(270781121115480292, 651321157810331630, 417121715114513525, 270085262983361453, 426716, 285700298447495691);
        check_withdraw_one(48263815458527892, 225617677021103257, 813845998773528961, 992058850228242119, 389318, 386316295310953819);
        check_withdraw_one(393641455773956433, 697223658403727512, 30887121522875100, 397803324506561312, 26244, 30886752817695580);
        check_withdraw_one(432131069709590937, 1058742455438737944, 159401432877261395, 75244360723633433, 750652, 95771876378880114);
        check_withdraw_one(123073158738987155, 462756300995837357, 827935887225518950, 987874485529951585, 124267, 482925429339474178);
        check_withdraw_one(8046784692748640, 21913785839331071, 692559206294537822, 833835281598286171, 613832, 560494145681580095);
        check_withdraw_one(290940267466722598, 915841062314169538, 481101966214336043, 1098196491762494896, 954077, 481094723086726904);
        check_withdraw_one(79022083884557231, 231536240617663800, 991942647106987898, 331224441240316467, 708125, 451590036170281122);
        check_withdraw_one(314599508245955938, 1056713629041409444, 642960608597961228, 209996237213839679, 847847, 253938143530684798);
        check_withdraw_one(868251910298784949, 872931851482963269, 270633798070496173, 910538277271730235, 793060, 270633798070447559);
        check_withdraw_one(173084030098767070, 488602523017343563, 178244736966844793, 980019534848533427, 372999, 178244120390300526);
        check_withdraw_one(369508074922661540, 480930238045897708, 656691580897053233, 1021098426015063583, 214053, 656691527781892086);
        check_withdraw_one(105685749738835962, 437442523748475657, 512662563996130744, 58911453669834619, 749454, 138091973468371595);
        check_withdraw_one(801537099566107702, 1076167417430005169, 79632706511398520, 70122758143200627, 560432, 79632700947155036);
        check_withdraw_one(365263599818616966, 619874199149119407, 658142970565910911, 554023569638562075, 520092, 658142016695275182);
        check_withdraw_one(431870362638904624, 1152921504606846975, 427481669039810677, 440667204850600412, 261024, 325197341055163169);
        check_withdraw_one(577410922645622764, 920153800656899704, 890460283913843172, 800345520277846143, 402137, 890459715039220311);
        check_withdraw_one(413743247748587613, 541638577427328299, 496731613487513761, 514318282022393005, 907146, 496731600259269663);
        check_withdraw_one(788877189558420918, 846063296268509911, 398453030959238074, 834753330870349742, 915845, 398453030833221142);
        check_withdraw_one(599420592031278132, 1145586807771744091, 1141287234760198294, 760640309606690829, 949113, 995170409523307741);
        check_withdraw_one(25929995599046588, 47213395892164637, 752686279433584622, 260428243677586419, 937309, 556411119183803618);
        check_withdraw_one(257051310510769568, 311903008266612769, 275753379787748543, 334677313272589193, 936183, 275753377616576963);
        check_withdraw_one(39620292982619201, 565046894334156939, 1115111179357924937, 17454143619839989, 609814, 79414868366769747);
        check_withdraw_one(573607433434300854, 953316235110671644, 346773815994344338, 1010603400316503334, 280043, 346773667473258516);
        check_withdraw_one(336986194471764394, 604221164441204780, 865722212891820108, 975770037068383298, 138575, 865719116976685986);
        check_withdraw_one(239473334543960564, 833549379349398636, 199899294763198516, 594663410534916497, 858955, 199897728580521842);
        check_withdraw_one(2774356818327076, 14463146638616657, 1003272857209140386, 296086186611693484, 613033, 249246448065760913);
        check_withdraw_one(118900037941668699, 549174849025972881, 1149278316875297080, 1034577552058048467, 838293, 472819398065783248);
        check_withdraw_one(145847520909769395, 327871833663539229, 578485124645520884, 1030161747238816623, 561949, 578484002752791025);
        check_withdraw_one(507141146156843558, 982221969407635790, 986533714388683277, 587308722964243925, 897315, 812606657980623939);
        check_withdraw_one(202428015385309652, 395483615626700017, 619904792559306376, 581826894142481583, 860439, 615095394006102970);
        check_withdraw_one(133888096625396516, 214833393670012943, 262393470574865539, 65221185431337243, 730368, 204175487905416333);
        check_withdraw_one(891567761538147805, 947605665626703566, 1133611901947069502, 490159201961642880, 816223, 1133611901245201375);
        check_withdraw_one(183810831989781439, 1029709956013051193, 46844449320956326, 294371067629096640, 666135, 46843451245573202);
        check_withdraw_one(14974913604539931, 16355377404338176, 525160218187326510, 549061438751283393, 461736, 525160217385587954);
        check_withdraw_one(364133628526551180, 412624684087495642, 183166074610545901, 125903672679011283, 585984, 183166073704286524);
        check_withdraw_one(269110586629522676, 470677586238326506, 1130072335991785628, 649019762246246682, 613131, 1017197904511686993);
        check_withdraw_one(246691988734129336, 951225966420268766, 669769358434822673, 851690145293067430, 192498, 394575986554126022);
        check_withdraw_one(502004228516220463, 1128961103614714469, 1109845569564308056, 1007813304943707684, 949737, 941638273568618498);
        check_withdraw_one(5859363994604366, 132906212853024830, 924253163457411635, 1029321054608023929, 855126, 86126156724206675);
        check_withdraw_one(20107228774349006, 70081913746159045, 1036638361954897691, 546097416207417780, 396061, 454103479579466689);
        check_withdraw_one(9958566919596125, 232663699994005961, 349088986780215909, 155947387311759429, 351919, 21616792340170887);
        check_withdraw_one(98941860396283141, 1152921504606846975, 571273004572119163, 109145361978396013, 112619, 58392758998257418);
        check_withdraw_one(404343805162204545, 723952137450303108, 487113726631625605, 236838410818677503, 653444, 404343764324871134);
        check_withdraw_one(124933854153616044, 1152921504606846975, 503732685508559116, 72451055687567059, 36235, 62438400483346063);
        check_withdraw_one(1077939069927012366, 1412897071643421210, 561656614729412219, 851240456914008991, 333104, 561656582640051955);
        check_withdraw_one(330921609499364102, 1152921504606846975, 517371942263502324, 572847658759235388, 904864, 312924237654103967);
        check_withdraw_one(28439681098906291, 603586831054062552, 25189512093546367, 578397318960516185, 448192, 25161561370165994);
        check_withdraw_one(176990511373436090, 1152921504606846975, 45507792639851465, 284913783588091464, 781436, 45505439035977743);
        check_withdraw_one(12253215378617027, 153389525401541523, 127815479160167545, 25574046241373978, 176194, 12253261228036442);
        check_withdraw_one(360914092116435205, 1152921504606846975, 418390878174672226, 113942865769260104, 226699, 166643650254485998);
        check_withdraw_one(117827238633703332, 1132677015285565680, 789172651653375115, 343504363632190565, 351214, 117827334935227275);
        check_withdraw_one(222496740011723996, 1152921504606846975, 122252695077134506, 469823084272055996, 47645, 114193900462564510);
        check_withdraw_one(546286434148570952, 1444607897571281034, 305020324315122008, 1139587573256159026, 878585, 305019949190903885);
        check_withdraw_one(82325743282492911, 1152921504606846975, 476064967644985185, 454940930208393666, 89336, 66479582271562274);
        check_withdraw_one(184695074219410929, 511738323688718939, 439643653803269488, 72094669885449451, 20707, 184699896763694174);
        check_withdraw_one(318448525753824113, 1152921504606846975, 234699368756196395, 520652624829195236, 128293, 208626582874252515);
        check_withdraw_one(322420590889226669, 520117303741016071, 22928243172575940, 497189060568440131, 963263, 22928236438903974);
        check_withdraw_one(128635752694254700, 1152921504606846975, 153340957299495395, 558111970887454587, 19822, 79364461957457751);
        check_withdraw_one(448117301791522796, 1014357778526373784, 799603486479167431, 214754292047206353, 243194, 448117809437473069);
        check_withdraw_one(115339150427117139, 1152921504606846975, 170458493746600372, 301391834257945426, 303632, 47204177238059846);
        check_withdraw_one(1015754832035243818, 1605099908868817929, 670039162647851729, 935060746220966200, 496076, 670039003092681334);
        check_withdraw_one(188550924047911494, 1152921504606846975, 285111325326605184, 359754329042920326, 849084, 105462491205482374);
        check_withdraw_one(429726779814139140, 605748126064963445, 216004122675141913, 389744003389821532, 819370, 216004112686748658);
        check_withdraw_one(279882709555347706, 1089504572537771298, 891710272951923921, 197794299585847377, 713912, 279882895760951374);
        check_withdraw_one(338739973968792935, 1152921504606846975, 41238612402508215, 464730545337326772, 255996, 41238166223637253);
        check_withdraw_one(1535893045637262329, 2166009746959606517, 1088311614217747377, 1077698132741859140, 239828, 1088311343882688683);
        check_withdraw_one(233987644521734122, 1152921504606846975, 369116736805922325, 246216877279206684, 408021, 124883169546434856);
        check_withdraw_one(21118492864323291, 704849240855406318, 388759469589594612, 316089771265811706, 382662, 21118497354955908);
        check_withdraw_one(95775586614800432, 1152921504606846975, 88263521923851539, 295220457025531502, 124296, 31856181693173694);
        check_withdraw_one(304478954698053206, 428364622742225135, 386387510534617778, 41977112207607357, 326252, 304479279814240281);
        check_withdraw_one(447891703218133279, 1152921504606846975, 1473480349921427, 270444789892923990, 643130, 1473448633169532);
        check_withdraw_one(166214706617147306, 464414530106794172, 147849346677444096, 316565183429350076, 268920, 147847226945867061);
        check_withdraw_one(480712919758410923, 1152921504606846975, 476209508167421332, 154927250322429741, 272668, 263153948409701238);
        check_withdraw_one(66310570961023775, 807792427618250199, 428472616797735799, 379319810820514400, 406692, 66310573860398837);
        check_withdraw_one(102224675739712059, 1152921504606846975, 275524684427721495, 371324883875785571, 390336, 57353378886254555);
        check_withdraw_one(234454808445823445, 757098934789413831, 528831454083837288, 228267480705576543, 252335, 234454985360258279);
        check_withdraw_one(319756940433606751, 1152921504606846975, 153228012206734525, 108538052184788395, 234383, 72599495403276336);
        check_withdraw_one(303819444456251323, 1163306622715123009, 629216904203486386, 534089718511636623, 699121, 303819410083636697);
        check_withdraw_one(275497387139595531, 1152921504606846975, 140444771697697600, 506592071231471368, 6041, 140109922749611824);
        check_withdraw_one(423312332509335569, 594756030254965477, 172309586545271788, 422446443709693689, 401012, 172309571731479038);
        check_withdraw_one(565971168270293879, 1152921504606846975, 35332255393514237, 344054789459756752, 718861, 35332231262796489);
        check_withdraw_one(491015699298522963, 1621820185440824425, 823190349908099698, 798629835532724727, 943909, 491015576614454049);
        check_withdraw_one(177481539307293563, 1152921504606846975, 485740848407158604, 461603446026596158, 688168, 145834827046450563);
        check_withdraw_one(729736362208869978, 964282192612022452, 619819020045065290, 344463172566957162, 821239, 619818968175370510);
        check_withdraw_one(1199752169422201, 1152921504606846975, 35168747905019649, 575313579588635349, 302225, 635203971340785);
        check_withdraw_one(323367201278396701, 742335092219117569, 81887093830592412, 660447998388525157, 108581, 81886562995857731);
        check_withdraw_one(142536476123606552, 1152921504606846975, 519212997219733627, 355027134194073537, 197844, 108082967226682423);
        check_withdraw_one(1164193745059275810, 1516825820789276438, 451303890760645447, 1065521930028630991, 496389, 451303876223874307);
        check_withdraw_one(398821050860807467, 675931253008882668, 536740373557006077, 139190879451876591, 187865, 398821440894901165);
        check_withdraw_one(438374025906983518, 1152921504606846975, 15539002090037186, 362599982224123013, 226113, 15538849068215935);
        check_withdraw_one(19929751630045832, 1119449162167831160, 33939176464409317, 1085509985703421843, 636545, 19919943560217907);
        check_withdraw_one(281460426811872647, 1152921504606846975, 571212749635661120, 406096267781929068, 680841, 238588511186024443);
        check_withdraw_one(417469147592494172, 1152921504606846975, 448993633669019507, 197404537987032347, 631406, 234058744830261282);
        check_withdraw_one(184219724300822392, 532173857770461561, 56877488262779768, 475296369507681793, 400301, 56877270920052952);
        check_withdraw_one(262045697246787412, 1152921504606846975, 458494590739651494, 474482507172663719, 739570, 212054828406733897);
        check_withdraw_one(1183877149022927838, 1437861891176911775, 461407338263693341, 976454552913218434, 511482, 461407332587849475);
        check_withdraw_one(50984871129723952, 1152921504606846975, 14300093669173628, 325550985503438562, 194942, 14217446426755320);
        check_withdraw_one(12165707698783362, 1371714084922582801, 230888726972817591, 1140825357949765210, 662887, 12165639976339571);
        check_withdraw_one(321098460314930402, 1152921504606846975, 541811827707449502, 117978613870363171, 731109, 183757376144477775);
        check_withdraw_one(807661703755142346, 1516838684549250712, 1019024318342772881, 497814366206477831, 460999, 807661656773033182);
        check_withdraw_one(429353050037453790, 1152921504606846975, 298590931572273201, 149800371082477124, 112308, 166983047242874628);
        check_withdraw_one(1676045238074624871, 1844444328462488545, 916162269881317374, 928282058581171171, 159332, 916162264570036642);
        check_withdraw_one(387728713250717688, 1152921504606846975, 222748408174592424, 502338840787654968, 597029, 222746206866225255);
        check_withdraw_one(357206363644465845, 637311501673084395, 161489868972378497, 475821632700705898, 659768, 161489824261897672);
        check_withdraw_one(445054079374290308, 1152921504606846975, 454607058387706441, 224039189167712791, 257291, 261973079871773892);
        check_withdraw_one(829579487264623164, 877522403588821248, 674849072039159391, 202673331549661857, 330169, 674849070708785628);
        check_withdraw_one(498219064624747379, 1152921504606846975, 27263884891701028, 14545742282088798, 71888, 18067459485384437);
        check_withdraw_one(545051088470583550, 1130661334547212512, 150377716285481651, 980283618261730861, 607606, 150377609497625367);
        check_withdraw_one(202677202256279341, 1152921504606846975, 450648425098289714, 246037279566764687, 98280, 122473695291017689);
        check_withdraw_one(1169480758030654622, 1272829140878220961, 856761696948158255, 416067443930062706, 537723, 856761694975989616);
        check_withdraw_one(60099246943741535, 1152921504606846975, 24464979413446846, 250937525833991478, 817593, 14355544195358349);
        check_withdraw_one(220068682434984853, 970373980072565463, 840901207276758596, 129472772795806867, 465432, 220069013943787141);
        check_withdraw_one(449980908389287915, 1152921504606846975, 345214825550946393, 25011214064182571, 283876, 144498393874255557);
        check_withdraw_one(369657636036540595, 476623095404980009, 153511599643992707, 323111495760987302, 470420, 153511594987544681);
        check_withdraw_one(399841696905171750, 1152921504606846975, 350250021261297191, 26459199084830909, 515034, 130645833365069610);
        check_withdraw_one(453911475820497123, 686418841123952871, 32215461069547560, 654203380054405311, 233783, 32215436709435858);
        check_withdraw_one(445084688845332357, 1152921504606846975, 518829557919317040, 194320406192542595, 399402, 275311272747114289);
        check_withdraw_one(112010358044755124, 510254815139643529, 127524626340373432, 382730188799270097, 926389, 112009209505692234);
        check_withdraw_one(301343676057455969, 1152921504606846975, 258857287243443087, 313206579416582307, 239099, 149522346484385928);
        check_withdraw_one(627747525313931611, 1601325068340016982, 530577046544455153, 1070748021795561829, 214021, 530571866796433735);
        check_withdraw_one(560563627626954462, 1152921504606846975, 300348040041658302, 18124983958290801, 778482, 154845451106925424);
        check_withdraw_one(60693259672098372, 1003940089278608354, 621556570474765539, 382383518803842815, 555217, 60693279241021106);
        check_withdraw_one(469649554124236925, 1152921504606846975, 51561604396676951, 345428191692038389, 857643, 51561554512781955);
        check_withdraw_one(120504786312277698, 345695109550726185, 107762132176122421, 237932977374603764, 637981, 107761394264109689);
        check_withdraw_one(302773530743865233, 1152921504606846975, 393090802459665786, 386006914577951819, 57669, 204601437582200011);
        check_withdraw_one(849937718228551240, 1441261529727885608, 876743044629221453, 564518485098664155, 288000, 849932865915958658);
        check_withdraw_one(218057312771514897, 1152921504606846975, 69755716818130229, 255841929289505508, 467530, 61579837783804549);
        check_withdraw_one(1000306260248951597, 1056844602265379855, 930466925681320717, 126377676584059138, 437532, 930466919831320249);
        check_withdraw_one(176382171141319770, 1152921504606846975, 140860697496815982, 391994574661389101, 33111, 81513849693581405);
        check_withdraw_one(808075857902034224, 871230176857786075, 492839068364341405, 378391108493444670, 535411, 492839067871333402);
        check_withdraw_one(184247137269872575, 1152921504606846975, 470786828453252257, 391268969593750332, 536032, 137764205053544751);
        check_withdraw_one(293896513872595002, 550292487846331622, 92147903581058955, 458144584265272667, 175977, 92147774051594099);
        check_withdraw_one(513062480510284999, 1152921504606846975, 156025077529157104, 417516384893863888, 69385, 156023674860058668);
        check_withdraw_one(180002658080248011, 1990505284418277057, 926096745352133369, 1064408539066143688, 404910, 180002597615499064);
        check_withdraw_one(121576119122939401, 1152921504606846975, 255960335237065342, 94459155125770445, 203232, 36951964768355332);
        check_withdraw_one(1389959230902672419, 2128384472388652466, 1130076380391508328, 998308091997144138, 830020, 1130076146670525411);
        check_withdraw_one(758111093968269207, 1529699178572875711, 1081084980735486293, 448614197837389418, 804399, 758111179799634773);
        check_withdraw_one(23129977351168212, 1152921504606846975, 37791045962589684, 83300281094558705, 129700, 2429327166191522);
        check_withdraw_one(795333940957280879, 1030564197888335484, 367405165053273008, 663159032835062476, 698833, 367405156849253244);
        check_withdraw_one(26911439673722435, 1152921504606846975, 514364476153388791, 528329557776368462, 134754, 24338510548901059);
        check_withdraw_one(955793406931413502, 1340212819998335733, 524706927549030605, 815505892449305128, 739156, 524706900221651033);
        check_withdraw_one(490757386206412393, 1152921504606846975, 367288544184553712, 138900531340071046, 7852, 215471252012895977);
        check_withdraw_one(1071486687481155222, 1467935548460833761, 347366814890441334, 1120568733570392427, 749004, 347366802074872985);
        check_withdraw_one(392146922053753990, 1152921504606846975, 350208788884529842, 418395268053422111, 715518, 261427528642759992);
        check_withdraw_one(295399756713440785, 1493117378016781307, 867431050138416304, 625686327878365003, 439568, 295399790647992750);
        check_withdraw_one(251251493637563408, 1152921504606846975, 364791149253938391, 15017628615706956, 961442, 82770394352879851);
        check_withdraw_one(582038775603925667, 1114490328193372515, 763151544744185343, 351338783449187172, 294802, 582038815591521361);
        check_withdraw_one(441072446156454839, 1152921504606846975, 434357820615847268, 540911039134161817, 747030, 373107292057316787);
        check_withdraw_one(624411014124997415, 1848253108358844027, 861307938707865452, 986945169650978575, 320164, 624409873300867206);
        check_withdraw_one(522716392459768210, 1152921504606846975, 505512658204711191, 230125720225144824, 21801, 333528122731913963);
        check_withdraw_one(393539596040937582, 1037027012922729405, 348253127725119109, 688773885197610296, 842819, 348251860848268294);
        check_withdraw_one(534746442568895285, 1152921504606846975, 353655179574131859, 271332000084980510, 552610, 289880497709872157);
        check_withdraw_one(867550086306959306, 1778445491302202090, 1130808719811700185, 647636771490501905, 125688, 867549590062934296);
        check_withdraw_one(218942386043797502, 1152921504606846975, 392591628522078249, 29476693167452038, 92248, 80152974111506437);
        check_withdraw_one(559140284180821176, 861033591234342948, 492051870178276907, 368981721056066041, 13589, 492041649257012894);
        check_withdraw_one(563736910510434615, 1152921504606846975, 562721998731979887, 344821367839240771, 751438, 443755800148087112);
        check_withdraw_one(366374095588590372, 1443320313627455771, 739604564561418291, 703715749066037480, 869851, 366374031615691718);
        check_withdraw_one(95808472136358554, 1152921504606846975, 339453337621345445, 363946739320110988, 667183, 58452962935852555);
        check_withdraw_one(208249665920032563, 843095644136701378, 619962029518988164, 223133614617713214, 193938, 208249973313597426);
        check_withdraw_one(71610211068878698, 1152921504606846975, 243756525715984151, 318592973143043373, 862692, 34928619637313767);
        check_withdraw_one(574262099112919020, 1048725723710983745, 585840068117056528, 462885655593927217, 945816, 574259720031372936);
        check_withdraw_one(512960354504827075, 1152921504606846975, 16854872383313910, 249074662094494713, 472357, 16854838704559556);
        check_withdraw_one(1058714942852463861, 1545848624288634808, 574260314712020748, 971588309576614060, 516379, 574260255262284573);
        check_withdraw_one(111827764384916765, 1152921504606846975, 120321943554914588, 87174284290533843, 145283, 20126136122354786);
        check_withdraw_one(95996394693672649, 308592605791256702, 16863008247391768, 291729597543864934, 588105, 16862919782302754);
        check_withdraw_one(333429753570901106, 1152921504606846975, 37493835921575152, 421045386244453616, 396911, 37493563664227440);
        check_withdraw_one(75594003965962466, 1274765885120909601, 293057986687758706, 981707898433150895, 778289, 75593794523684871);
        check_withdraw_one(429592472973267378, 1152921504606846975, 568047696055201913, 10223560738886611, 356559, 215473531339032782);
        check_withdraw_one(706172515526933803, 1253828433512914670, 623410822591741629, 630417610921173041, 923109, 623410396288253122);
        check_withdraw_one(575274632638352371, 1152921504606846975, 177076486288129353, 64572414581267253, 780428, 120575864418393397);
        check_withdraw_one(817386587516412528, 1360058428581079695, 686970554740065122, 673087873841014573, 524264, 686970120663923479);
        check_withdraw_one(308498413462113338, 1152921504606846975, 151409110075110797, 557729314884637466, 33867, 151384950039747941);
        check_withdraw_one(90916990624198491, 552488395148931722, 486792919512443089, 65695475636488633, 225271, 90917337129543254);
        check_withdraw_one(136577356024841765, 1152921504606846975, 237003588907282793, 111893943978016586, 910526, 41331101468360378);
        check_withdraw_one(159670815662148893, 213023499957249774, 199871998088871407, 13151501868378367, 966190, 159670897659660001);
        check_withdraw_one(445331180510931926, 1152921504606846975, 376130911288447106, 25323233910442845, 903098, 155067180718202018);
        check_withdraw_one(64042085155926888, 880119722694733738, 835728604573287598, 44391118121446140, 656144, 64042308758495349);
        check_withdraw_one(503857018798480537, 1152921504606846975, 453400068905918930, 322006134016433447, 97913, 338872318883240484);
        check_withdraw_one(136695862783608449, 616111370913352276, 552961337622161275, 63150033291191001, 696573, 136696045780875220);
        check_withdraw_one(418421915687414920, 1152921504606846975, 244899753384970988, 571866705943194172, 408311, 244898289634379891);
        check_withdraw_one(1525539336548301109, 1892367386945695065, 1030690073144558711, 861677313801136354, 375797, 1030690034638749868);
        check_withdraw_one(225834131230014332, 1152921504606846975, 361065993616088213, 433091816761768273, 471668, 155559447346420654);
        check_withdraw_one(134581214158860006, 575988408860283892, 11443215131590165, 564545193728693727, 222431, 11442520011131571);
        check_withdraw_one(235604041673665100, 1152921504606846975, 463590966604540313, 511012356413687822, 384176, 199163909147676733);
        check_withdraw_one(35217461527418741, 1152921504606846975, 313930546840572673, 516154878486466765, 359382, 25355994009071152);
        check_withdraw_one(934879620866487049, 1105427644062102967, 336371189940635195, 769056454121467772, 714434, 336371188054993355);
        check_withdraw_one(81840724813859542, 1152921504606846975, 565635010351315983, 355813295384488867, 64746, 65409648844993002);
        check_withdraw_one(695494869551343718, 1736518285691168357, 992749902476920591, 743768383214247766, 765871, 695494730596238864);
        check_withdraw_one(98479816674065327, 1152921504606846975, 5937653208487369, 28818273182047765, 67857, 2968490600420829);
        check_withdraw_one(1478346956875513704, 2109219654558254720, 1063582358226004610, 1045637296332250110, 863900, 1063582274456003567);
        check_withdraw_one(291506668685961638, 1152921504606846975, 539609233175629515, 31432839985711238, 500799, 144383753027209969);
        check_withdraw_one(312462409137766788, 834856270376653104, 605868456086414828, 228987814290238276, 42643, 312463882265567980);
        check_withdraw_one(206756497117954107, 1152921504606846975, 572997138162825178, 258461824044070848, 421307, 149107844251596399);
        check_withdraw_one(175555437977631356, 1046807812884706535, 580111961899782681, 466695850984923854, 811457, 175555441609485563);
        check_withdraw_one(229872947164650955, 1152921504606846975, 226169918443155870, 88967554135437556, 950729, 62833072778542261);
        check_withdraw_one(1593900587917123662, 1822938960863221723, 819865740003400283, 1003073220859821440, 311486, 819865733793239448);
        check_withdraw_one(183155544250503581, 1152921504606846975, 71669354924987197, 135154957416800472, 343384, 32856461200467570);
        check_withdraw_one(771589236969702137, 1441050728849691871, 848160207264346559, 592890521585345312, 513184, 771588300570957647);
        check_withdraw_one(647571538187575972, 1189858401621172189, 1071360783124418933, 118497618496753256, 539493, 647572203591149396);
        check_withdraw_one(571278488753978580, 1152921504606846975, 529204098060536535, 305414358703602171, 616251, 413557643669538305);
        check_withdraw_one(41192994919372342, 276621265411076237, 173474444738200583, 103146820672875654, 405119, 41193010479458552);
        check_withdraw_one(496621153612000064, 1152921504606846975, 547030791247100040, 259306999105234022, 294528, 347330254239347582);
        check_withdraw_one(146244751569638790, 521028443240708590, 408301290088749492, 112727153151959098, 158280, 146245089949744228);
        check_withdraw_one(393399899565181540, 1152921504606846975, 404685576345484903, 414657398489210127, 2566, 279533798996975807);
        check_withdraw_one(1153741737889469003, 2005697612663980135, 1112475244711281881, 893222367952698254, 520481, 1112471216166850887);
        check_withdraw_one(111836147640929818, 1152921504606846975, 428109166872163595, 522544448663635975, 280612, 92215617234322358);
        check_withdraw_one(902681699108014113, 1804462423423366275, 1086700711261832173, 717761712161534102, 277586, 902680894124983094);
        check_withdraw_one(365751126336022729, 1152921504606846975, 447241430344661237, 200576050757011060, 186874, 205512857436514457);
        check_withdraw_one(899052618006549147, 1415215674601050474, 772675461174104489, 642540213426945985, 188438, 772674337799119322);
        check_withdraw_one(324706043786719375, 1152921504606846975, 456114049143799676, 463920071699902895, 99182, 259115551195786104);
        check_withdraw_one(513067324147586922, 543534988401850698, 131214260120217442, 412320728281633256, 473775, 131214260072823442);
        check_withdraw_one(507424065393447204, 810265911883970188, 367643888253434090, 442622023630536098, 520437, 367643780430873516);
        check_withdraw_one(189838722085530256, 1152921504606846975, 210044673072204915, 239671591902159728, 139385, 74049655059089482);
        check_withdraw_one(1498504409741996213, 1728450353497607667, 894174700393824019, 834275653103783648, 450477, 894174693702209032);
        check_withdraw_one(213220690012580822, 1152921504606846975, 13243867526294509, 153322803906821518, 312033, 13243495256634854);
        check_withdraw_one(1737140527988769993, 1926087598271065608, 1100149080564346469, 825938517706719139, 495651, 1100149077330845242);
        check_withdraw_one(185889983912566493, 1152921504606846975, 519996084656374129, 512984243961494427, 404664, 166551367670216440);
        check_withdraw_one(137187659793945645, 1673027501466870614, 652595009700013938, 1020432491766856676, 480881, 137187547307736674);
        check_withdraw_one(423305499532500253, 1152921504606846975, 69681435818619052, 178315234323077929, 581974, 69681217962164898);
        check_withdraw_one(371740923758296040, 846591496598964407, 421071708155441588, 425519788443522819, 590629, 371740246257192919);
        check_withdraw_one(55427784748869304, 1152921504606846975, 510709538917523977, 293210801106528689, 133739, 38649286460698263);
        check_withdraw_one(564396869038479118, 1366294941163980014, 732987026606357063, 633307914557622951, 305253, 564396211872054212);
        check_withdraw_one(552491737393654941, 1152921504606846975, 444047275556525735, 211649682260710606, 138514, 314216768094270032);
        check_withdraw_one(235655493447707993, 1037065358620854509, 431845860611554678, 605219498009299831, 340355, 235655112585043090);
        check_withdraw_one(479733645664146845, 1152921504606846975, 485053449402006900, 411301112250233581, 288074, 372975036502830846);
        check_withdraw_one(1457351245419833403, 1498900997841503768, 564777735573971945, 934123262267531823, 286622, 564777735536452410);
        check_withdraw_one(187741057272022958, 1152921504606846975, 511972567155956970, 148094920123868086, 299997, 107485149418202092);
        check_withdraw_one(60551559039294512, 1865987799674127908, 903088566047276882, 962899233626851026, 298556, 60551548650754562);
        check_withdraw_one(137689988564198672, 1152921504606846975, 235544105011966280, 275161216682869209, 624990, 60992001866459644);
        check_withdraw_one(195996335725785626, 1152921504606846975, 290395648867146558, 351251235313754682, 847329, 109079759414303534);
        check_withdraw_one(616783823649762549, 1322680377940405674, 742161913097413546, 580518464842992128, 589342, 616783406608459785);
        check_withdraw_one(45791646398283418, 1152921504606846975, 70485031251821480, 78482333706160326, 905180, 5916673656437118);
        check_withdraw_one(350712911808849937, 1152921504606846975, 126752917255980370, 563932692097207031, 819841, 126752557220233778);
        check_withdraw_one(158570695951769310, 1152921504606846975, 83932394978425852, 215303540254853285, 564357, 41156228120021382);
        check_withdraw_one(383819828749595956, 1152921504606846975, 227697935314256605, 472604217650803927, 17606, 227430300422578695);
        check_withdraw_one(37638012142137112, 1152921504606846975, 453541078958815882, 393632570463809300, 27149, 27656689927501340);
        check_withdraw_one(46278952269260585, 1152921504606846975, 193496700566980683, 523134310627919346, 897928, 28765953431097315);
        check_withdraw_one(219410239588473129, 1152921504606846975, 275605917628104955, 567411640468888204, 837976, 160432761638037798);
        check_withdraw_one(545930003095896152, 1152921504606846975, 366596292905603011, 121240268032619825, 466395, 230999873499372045);
        check_withdraw_one(507334557104861146, 1152921504606846975, 415297374742785075, 538264680539547969, 500586, 415281054730191054);
        check_withdraw_one(203506315162319388, 1152921504606846975, 33841723505928807, 24443549786846749, 640095, 10288143891523381);
        check_withdraw_one(305127089745360417, 1152921504606846975, 339285979175659700, 359255937801468299, 687582, 184872933895299351);
        check_withdraw_one(3780556219568288, 1152921504606846975, 242711426709164958, 28906211705188127, 469321, 890666253651614);
        check_withdraw_one(227138982612161905, 1152921504606846975, 227943287150832267, 375702328885669780, 30233, 118922257812819272);
        check_withdraw_one(276278446946939944, 1152921504606846975, 447439982341590001, 103309448038142681, 706391, 131978020676989338);
        check_withdraw_one(505122472636699334, 1152921504606846975, 566255978852987051, 366273534358277226, 853770, 408563429576323689);
        check_withdraw_one(254802559499781196, 1152921504606846975, 518006482498132117, 429752949782030163, 28890, 209460270270231315);
        check_withdraw_one(257934031285309082, 1152921504606846975, 496641802151128575, 152689352726765256, 975636, 145269789072614673);
        check_withdraw_one(14579928729571926, 1152921504606846975, 161524820077729027, 366332587558988351, 103284, 6675272779145091);
        check_withdraw_one(105574165444407715, 1152921504606846975, 575754794203616327, 525106304708753085, 150939, 100806941143031724);
        check_withdraw_one(90748812363222485, 1152921504606846975, 427839764339210473, 470808339496491408, 645118, 70734421470159805);
        check_withdraw_one(68188079707737838, 1152921504606846975, 316099843495366748, 438153336897900411, 530121, 44609326378017305);
        check_withdraw_one(195974130442725276, 1152921504606846975, 424946973146591559, 38883840947834073, 658395, 78842322926259085);
        check_withdraw_one(86683626833314796, 1152921504606846975, 448711532428366882, 437636276381642677, 42845, 66640957955296764);
        check_withdraw_one(139932193901437350, 1152921504606846975, 546777347431770826, 418468352844721455, 697103, 117153648750424050);
        check_withdraw_one(196110061956172039, 1152921504606846975, 385918655560381887, 259717776445811296, 591139, 109821718516044167);
        check_withdraw_one(144662643172139938, 1152921504606846975, 533523256340917954, 413521933349960431, 315427, 118830366588099950);
        check_withdraw_one(565972675259843904, 1152921504606846975, 514941457289835424, 480754616103669435, 605502, 488788513062048386);
        check_withdraw_one(245618543103334660, 1152921504606846975, 167826170712015316, 345579805884291430, 802448, 109375851573178541);
        check_withdraw_one(4759504817196220, 1152921504606846975, 351978480695951887, 159775742815065314, 991733, 2112630789290567);
        check_withdraw_one(504639050767335004, 1152921504606846975, 202803278566957238, 574581041668436751, 584756, 202803052518497200);
        check_withdraw_one(272644705057274404, 1152921504606846975, 399310042544906672, 130711551065784059, 500137, 125340428503382489);
        check_withdraw_one(198257232083841142, 1152921504606846975, 397538465965132027, 212343762761657591, 833555, 104875820679696038);
        check_withdraw_one(488535006296020089, 1152921504606846975, 448009818676994657, 478864612472778096, 136002, 392747267759602998);
        check_withdraw_one(510094164233210434, 1152921504606846975, 327455139422394325, 497690493570003014, 762195, 327454286444146303);
        check_withdraw_one(224924372277662871, 1152921504606846975, 402705699870071751, 163031922427398058, 880879, 110370236055858898);
        check_withdraw_one(297235240359178649, 1152921504606846975, 305118655482301737, 268904603830266157, 518019, 147989180200028422);
        check_withdraw_one(449494302449352813, 1152921504606846975, 162022919290489595, 404250401655448407, 512127, 162022495465809882);
        check_withdraw_one(279873647995174068, 1152921504606846975, 425716941940204144, 535940442820690711, 604473, 233443794372565750);
        check_withdraw_one(528438748274830865, 1152921504606846975, 35769164222206917, 563272685464915062, 363204, 35769076818537348);
        check_withdraw_one(330610003190968166, 1152921504606846975, 310546494189656376, 290488113778367900, 986337, 172351731627665947);
        check_withdraw_one(382879535607960730, 1152921504606846975, 261307932415232766, 464035243152049778, 23247, 240829848611235000);
        check_withdraw_one(179365618830084188, 1152921504606846975, 302556418012415856, 550909595346102628, 146247, 132777139546327646);
        check_withdraw_one(47833247498985191, 1152921504606846975, 63812711211362491, 179776769089257853, 233913, 10106158728053630);
        check_withdraw_one(198569915799701182, 1152921504606846975, 427074233407668663, 491187290109818614, 620740, 158153916060090152);
        check_withdraw_one(175412635958592905, 1152921504606846975, 68629702562193527, 138067157912872859, 275370, 31448026450356698);
        check_withdraw_one(89525355792875297, 1152921504606846975, 224438036897330147, 568477141931238656, 61264, 61569284897285096);
        check_withdraw_one(428881560111411633, 1152921504606846975, 224973588281609853, 35381001148830757, 990767, 96850778067796589);
        check_withdraw_one(89902835914278055, 1152921504606846975, 406332815669314153, 75158626555095472, 596310, 37545919239999901);
        check_withdraw_one(508921958315976036, 1152921504606846975, 428972917028340163, 145992618076495517, 454190, 253801071304044149);
        check_withdraw_one(506165377782249674, 1152921504606846975, 510853008356726020, 33903335003901541, 507441, 239164076994071776);
        check_withdraw_one(277718927633311256, 1152921504606846975, 463691603934544140, 231184225564194503, 477208, 167383676952516221);
        check_withdraw_one(318977813609443170, 1152921504606846975, 398667451180366676, 163684872576433788, 247082, 155585681382829084);
        check_withdraw_one(101198116932283772, 1152921504606846975, 291915118557275349, 278326843593679279, 859176, 50053200508128659);
        check_withdraw_one(213380075643335009, 1152921504606846975, 90378355849277782, 264773021734900285, 607210, 65730154151050681);
        check_withdraw_one(102751341364915224, 1152921504606846975, 189134996363615530, 296830211160719722, 607705, 43310444914530840);
        check_withdraw_one(491746812133950899, 1152921504606846975, 207188307779415070, 104115998573330001, 357405, 132778274057809923);
        check_withdraw_one(213890339388281582, 1152921504606846975, 298447451321919372, 563640388072449466, 448566, 159934420426213526);
        check_withdraw_one(53767490534713929, 1152921504606846975, 291339534439723143, 447782230143203856, 907905, 34469569578978470);
        check_withdraw_one(165454568011102412, 1152921504606846975, 357307589177412601, 118724013057358647, 152230, 68314967299498882);
        check_withdraw_one(371137530904733138, 1152921504606846975, 347281243971811520, 54063879817354930, 671358, 129197323414441323);
        check_withdraw_one(218593561111889497, 1152921504606846975, 330097962969133138, 277713038353636937, 727512, 115240775014906662);
        check_withdraw_one(541784887195761358, 1152921504606846975, 212048921131351841, 380066759622567449, 41201, 212045193217859221);
        check_withdraw_one(283213672506144094, 1152921504606846975, 286760836551945723, 88053212942617338, 892271, 92072620867931902);
        check_withdraw_one(358816363268769298, 1152921504606846975, 229807451064213737, 59142698407875832, 946963, 89928136849150537);
        check_withdraw_one(383559673791499212, 1152921504606846975, 396645813674213083, 302578204341483370, 744492, 232621307615479858);
        check_withdraw_one(543375849678205025, 1152921504606846975, 192915281995740678, 334314160223780673, 9102, 192899281298658312);
        check_withdraw_one(312723993686529677, 1152921504606846975, 187571930342501773, 187110805572531244, 878008, 101630729018268021);
        check_withdraw_one(298204327595026307, 1152921504606846975, 453626360723563979, 1190057220005274, 52066, 117718478930017649);
        check_withdraw_one(20311307514166905, 1152921504606846975, 373175166011172442, 400207808672732028, 606916, 13624880941600699);
        check_withdraw_one(427531906783470500, 1152921504606846975, 485247458037619595, 295757065975473489, 841040, 289615865868524589);
        check_withdraw_one(483182378047729182, 1152921504606846975, 448192042669785041, 473639992521069575, 494749, 386333406806299787);
        check_withdraw_one(476426100305938367, 1152921504606846975, 62183493172023367, 522548969222058293, 275633, 62183297840403665);
        check_withdraw_one(437356840047095839, 1152921504606846975, 322432331688111004, 451954653330892744, 129094, 293754681930517126);
        check_withdraw_one(119860605582785175, 1152921504606846975, 38660102910021550, 482106263763260204, 384180, 38655675230142191);
        check_withdraw_one(54463948201024916, 1152921504606846975, 174762903779737808, 224761223751324055, 527367, 18873491246310769);
        check_withdraw_one(428007583234895755, 1152921504606846975, 232879533963758591, 121260834527260169, 231883, 131470199192541544);
        check_withdraw_one(352148043104158350, 1152921504606846975, 476460204187795594, 168354490387934750, 495212, 196952135922741926);
        check_withdraw_one(298205134466105383, 1152921504606846975, 472666579547087885, 441826751093851289, 62509, 236534732665604936);
        check_withdraw_one(353907774087724501, 1152921504606846975, 239869068276406163, 346612972784785683, 4202, 179983872773202850);
        check_withdraw_one(177783598614705090, 1152921504606846975, 499022380287499167, 220453405929737338, 710441, 110945142762918262);
        check_withdraw_one(379921812084749129, 1152921504606846975, 482472578664361546, 302091980851005979, 804495, 258537290253255761);
        check_withdraw_one(336594001225193554, 1152921504606846975, 282405839533422008, 94441519680731639, 877594, 110020154603195981);
        check_withdraw_one(429686867278910563, 1152921504606846975, 547145187894479987, 241386419564320533, 980707, 293881002384630252);
        check_withdraw_one(174229926058720277, 1152921504606846975, 1891964209698761, 254885700470986098, 178968, 1891196047884419);
        check_withdraw_one(466099779450652511, 1152921504606846975, 371550898165935943, 95207371949689176, 693145, 188699772867319889);
        check_withdraw_one(181668097831046065, 1152921504606846975, 278863838256423351, 338878616706699453, 656302, 97338851477526188);
        check_withdraw_one(68901308032045242, 1152921504606846975, 235586161990594839, 416137360918448558, 109674, 38948355695406884);
        check_withdraw_one(315520023805555110, 1152921504606846975, 36620431712629715, 408754987503432908, 686881, 36620254959978387);
        check_withdraw_one(368808217233084227, 1152921504606846975, 145908915652992038, 57177091235314664, 310116, 64965256167048223);
        check_withdraw_one(301392221558478103, 1152921504606846975, 182453297840989754, 333563926986709787, 295080, 134894428804774643);
        check_withdraw_one(379110107398088895, 1152921504606846975, 261120666511154462, 524947367797592480, 519407, 258454614173640368);
        check_withdraw_one(932241868029103, 1152921504606846975, 401110807699377968, 189978649610045219, 814336, 477949749008035);
        check_withdraw_one(268635493888040032, 1152921504606846975, 461326632251892742, 46292490370478624, 3308, 118314393110620427);
        check_withdraw_one(568915882811092604, 1152921504606846975, 529000427680769899, 38815877616994204, 949782, 280192558416451228);
        check_withdraw_one(524858375924629724, 1152921504606846975, 158073260695134955, 512151540378983009, 650246, 158073136454158120);
        check_withdraw_one(401432111321965566, 1152921504606846975, 37029729680731800, 85597667776171294, 21402, 37023590825742691);
        check_withdraw_one(17711856913370693, 1152921504606846975, 71288284583050922, 439453309108678447, 160848, 7846021204111629);
        check_withdraw_one(210253679602147967, 1152921504606846975, 543864524408511312, 478845442965310756, 238265, 186507492082143585);
        check_withdraw_one(294847384995685338, 1152921504606846975, 81660620251029328, 68934519812387818, 710077, 38513097927408904);
        check_withdraw_one(433148040285742926, 1152921504606846975, 294765586456085881, 145520394823600944, 71815, 165413940119617845);
        check_withdraw_one(90727284997203781, 1152921504606846975, 520392366469533440, 270975054318240197, 702213, 62275394320474134);
        check_withdraw_one(249102022743999372, 1152921504606846975, 275918180960057154, 404192677044602250, 581714, 146945665688045779);
        check_withdraw_one(512171051167905354, 1152921504606846975, 289089272801353872, 207029651703906795, 314997, 220394532069885981);
        check_withdraw_one(570430325498551888, 1152921504606846975, 49362049136328157, 182034040431585053, 933486, 49362031088155729);
        check_withdraw_one(79019531573954881, 1152921504606846975, 19439485083437291, 278499688377110933, 639342, 19424431751914048);
        check_withdraw_one(175555324162171164, 1152921504606846975, 300905887203860685, 81381416105071157, 468682, 58210932835616269);
        check_withdraw_one(221734939199636362, 1152921504606846975, 182546063429838309, 556289239934797646, 605836, 142094771536408650);
        check_withdraw_one(510947667560866567, 1152921504606846975, 494149883145136535, 396557115748139222, 462035, 394740077942926534);
        check_withdraw_one(122498702280252982, 1152921504606846975, 532745940160204593, 401765130594191854, 72940, 99292550040183384);
        check_withdraw_one(99289065653581694, 1152921504606846975, 191555076735255793, 287149854334939291, 431621, 41225812912923714);
        check_withdraw_one(73339985114428414, 1152921504606846975, 114482071982202159, 75141368076993768, 424493, 12062386929894660);
        check_withdraw_one(30065718526440269, 1152921504606846975, 259561550980089087, 16158609209872145, 25590, 7190771219680338);
        check_withdraw_one(189628527833530477, 1152921504606846975, 60446032689541858, 214880391849741990, 285055, 45283685049953192);
        check_withdraw_one(371930330920634257, 1152921504606846975, 63612013664394296, 107860666651023842, 931260, 55316599137538286);
        check_withdraw_one(188400233050957301, 1152921504606846975, 228883345892914253, 489508986760790672, 654541, 117393088861837979);
        check_withdraw_one(19898223592636437, 1152921504606846975, 255847877419547708, 220941095289131176, 112534, 8228885206837716);
        check_withdraw_one(481690969708485821, 1152921504606846975, 461293879647564110, 413303463117396956, 842106, 365406855514592709);
        check_withdraw_one(46451963132658218, 1152921504606846975, 11475754407061468, 357096265906320007, 454623, 11465695169557057);
        check_withdraw_one(170869877848301575, 1152921504606846975, 9750719112423017, 426201624237165941, 252813, 9749636536577650);
        check_withdraw_one(302146946961447205, 1152921504606846975, 345266846137842975, 565166472622532492, 252821, 238596822146422867);
        check_withdraw_one(97736405781504837, 1152921504606846975, 53482279403200499, 243216802507198666, 27413, 25147148769156902);
        check_withdraw_one(351013710251079288, 1152921504606846975, 46294787443108982, 151305932603224603, 17780, 46286096668645163);
        check_withdraw_one(214390280512945277, 1152921504606846975, 6896258045956210, 67104063573142842, 792020, 6896183150191197);
        check_withdraw_one(55140809971965893, 1152921504606846975, 451980626371542208, 50758641178634128, 797028, 24044560502958839);
        check_withdraw_one(78701174720673254, 1152921504606846975, 273924351336248223, 311407325954208881, 160421, 39956109903677969);
        check_withdraw_one(486774643968906599, 1152921504606846975, 184097899393254378, 342591574972378889, 441786, 184097291309006007);
        check_withdraw_one(182789861643285133, 1152921504606846975, 128230646694042517, 143217989115555759, 447401, 43036788699303532);
        check_withdraw_one(362355280234286361, 1152921504606846975, 446260094484660686, 11872999397812327, 381958, 143989318293954014);
        check_withdraw_one(414692170842770454, 1152921504606846975, 518603924356049086, 458034908125926468, 800431, 351285281369821768);
        check_withdraw_one(232506599959655665, 1152921504606846975, 441601556502846544, 52779528046333496, 127476, 99701230209972704);
        check_withdraw_one(164498300615080241, 1152921504606846975, 322846640097827952, 246614217638771481, 234163, 81250427539384854);
        check_withdraw_one(227744938388997094, 1152921504606846975, 397647663778599642, 132652682255086829, 847037, 104754111784218920);
        check_withdraw_one(461444096953243175, 1152921504606846975, 5646728052362390, 76426327015523687, 819507, 5646719301636465);
        check_withdraw_one(495687073574128052, 1152921504606846975, 332806639978395962, 475604153275776102, 543053, 332803431918646805);
        check_withdraw_one(360598723214639184, 1152921504606846975, 223098946127315837, 353103562879061226, 118285, 180216021230340252);
        check_withdraw_one(402151549617327600, 1152921504606846975, 546881780580862315, 485443523149513290, 156549, 360085763914834596);
        check_withdraw_one(337144897959182656, 1152921504606846975, 214247268023027821, 489662091996556940, 379058, 205832697062813981);
        check_withdraw_one(444919224138880254, 1152921504606846975, 456504014134009933, 370585131325949867, 737662, 319178502318013808);
        check_withdraw_one(169733790565323744, 1152921504606846975, 280771575819632460, 410559635225927455, 296148, 101778047420364700);
        check_withdraw_one(556249087267113958, 1152921504606846975, 287921472283944553, 488755656877044450, 258528, 287920732156417479);
        check_withdraw_one(80503230999704598, 1152921504606846975, 189620985748365044, 217123476788549138, 625204, 28401098522852804);
        check_withdraw_one(290949690426909882, 1152921504606846975, 522643018571432251, 271447045001410249, 304547, 200395581061162987);
        check_withdraw_one(58839390186688630, 1152921504606846975, 481587112889469471, 565209762250602082, 942755, 53423309091193558);
        check_withdraw_one(318695430199985346, 1152921504606846975, 520860016215168105, 245612515347186407, 949756, 211871612759393895);
        check_withdraw_one(519716830471816420, 1152921504606846975, 142830254263656638, 117484021004777963, 363050, 117344980793187949);
        check_withdraw_one(307953623763742786, 1152921504606846975, 416739003424827397, 573551806347186514, 354710, 264513302105259090);
        check_withdraw_one(407347120811709172, 1152921504606846975, 481686258254610013, 63645369986389036, 992545, 192675232673416515);
        check_withdraw_one(106682935962881740, 1152921504606846975, 419142420817174859, 339509300050831206, 221510, 70200106647102917);
        check_withdraw_one(390385369079414478, 1152921504606846975, 536419121060750212, 19691504326777584, 708813, 188302642019939050);
        check_withdraw_one(561596689799822840, 1152921504606846975, 431525251499319743, 543538750848998071, 810902, 431524434858124317);
        check_withdraw_one(149506103961877555, 1152921504606846975, 334324843049701599, 346772672728756725, 941206, 88321906489243352);
        check_withdraw_one(347602570067615489, 1152921504606846975, 410143985295365875, 34984278794121692, 485, 134505848416829531);
        check_withdraw_one(215076480158833412, 1152921504606846975, 461099960582673976, 10603972074231565, 757266, 87996473890312327);
        check_withdraw_one(117922047253995095, 1152921504606846975, 207017879942646444, 229098049297808043, 631570, 44606396230350165);
        check_withdraw_one(86579912256303602, 1152921504606846975, 39233092478893431, 192606072085219498, 523298, 17410021845612543);
        check_withdraw_one(415087383276981527, 1152921504606846975, 145654328995655215, 513423460174158200, 425812, 145653860786154652);
        check_withdraw_one(297743221057297614, 1152921504606846975, 307701118165857592, 28562744853252663, 675152, 86840643726907373);
        check_withdraw_one(434043101411316727, 1152921504606846975, 556486753116399964, 374896546866268502, 766367, 350640066415079689);
    }

    #[test]
    fun test_compute_d() {
        // Use --instructions 100000000 for test
        check_d(0, 0, 1, 0);
        check_d(1098512304148995858, 511085650789627788, 794249, 1609597799242156845);
        check_d(1077587574037066906, 273700550809755760, 636274, 1351287543179933404);
        check_d(1046129065254161082, 1250710035549196829, 1188, 2296831376791770037);
        check_d(754878898244470000, 120885716480132307, 499821, 875763650012995345);
        check_d(903236260023114303, 906279987457020414, 863310, 1809516247477169523);
        check_d(862538457714585493, 492548187909826733, 9, 1349690409671689975);
        check_d(867139950084152027, 859870311905014324, 371562, 1727010261947987339);
        check_d(285461992898670106, 481571521111435071, 738333, 767033477680579831);
        check_d(842274085351741180, 596433745314710894, 575383, 1438707793064061574);
        check_d(74070093349070436, 585112780632264014, 23089, 659161371856618959);
        check_d(785594198032231554, 906223612524930044, 413991, 1691817800116105066);
        check_d(365854046765049234, 336512685712823896, 65535, 702366723109909301);
        check_d(467971633868208692, 937757774277178911, 794630, 1405729296937309688);
        check_d(907966694384959404, 596092259286676349, 384869, 1504058865883285302);
        check_d(745027730217739713, 255414713683344120, 466830, 1000442106435448245);
        check_d(562650885940788609, 108843632959299508, 700409, 671494115904590227);
        check_d(272802965083447436, 495381325865093118, 324792, 768184182569387688);
        check_d(1099481821339068262, 227880497875028273, 203243, 1327359843959453152);
        check_d(4766289146745791, 700352368988298188, 105552, 704997686688870927);
        check_d(551114207934254862, 229515885945697741, 562066, 780629951928393145);
        check_d(630949985641812281, 328559589247058252, 759576, 959509505239959207);
        check_d(974842651596563139, 86508868019235308, 179565, 1061344606181023111);
        check_d(231278785266782073, 293191801851952378, 630611, 524470581241876219);
        check_d(360206372162485991, 208510233084640767, 454602, 568716557335181440);
        check_d(230394608805613950, 875718280499989120, 962818, 1106112592902374941);
        check_d(1007401520058251841, 457890537840737153, 642370, 1465291871245291148);
        check_d(813477262781110107, 291430808847551652, 44593, 1104904511276546488);
        check_d(1127301777868477837, 186561853922024877, 273178, 1313861101988134231);
        check_d(907092956322380075, 814289356127256013, 577371, 1721382308104226448);
        check_d(350233118687010031, 580337487943047710, 554450, 930570551977814885);
        check_d(728409985428798536, 416426025765250093, 37406, 1144834783614075090);
        check_d(1005130829776268769, 127264010922262337, 486517, 1132393087883724776);
        check_d(939169424167416854, 1146233708601394149, 199593, 2085403080751752367);
        check_d(483537163592165366, 292405396274883028, 245709, 775942457874817231);
        check_d(752162799496855043, 77854290259895150, 936642, 830016229665586797);
        check_d(1142633981016844252, 813369391064219230, 315244, 1956003281606511678);
        check_d(947579287775585716, 659504378853711944, 972411, 1607083639196140460);
        check_d(491603869397198193, 1008927697032899840, 659026, 1500531412861847985);
        check_d(128006718930630763, 599481570009389282, 969086, 727488017120133364);
        check_d(142379855825130803, 277154506588979848, 592, 419493667277178850);
        check_d(870015806835883358, 637051156131857140, 923022, 1507066942982534634);
        check_d(214213849717113041, 706481937578875722, 958738, 920695595084094182);
        check_d(748177670105375694, 399919042996148004, 653574, 1148096624095398551);
        check_d(1040952369870512272, 1092702556198984763, 839713, 2133654925321682641);
        check_d(763519430007385751, 388188682600596387, 862206, 1151708033247165346);
        check_d(1090377424537971488, 281130254804883956, 594184, 1371507062941013158);
        check_d(1095698459427219620, 385519054890685822, 14440, 1481202206356226214);
        check_d(1063284633306362445, 1037626061681071305, 226661, 2100910694296059131);
        check_d(597567107151787438, 1056801118391033333, 225104, 1654367918750170245);
        check_d(609765294263704420, 232712742546266458, 593638, 842477859077490035);
        check_d(740258427599019149, 975344406509613482, 670658, 1715602809632821719);
        check_d(779155487601485124, 231140201173457057, 271024, 1010294911751926787);
        check_d(1109096581315593400, 266333946097541260, 185342, 1375428297001480793);
        check_d(1062586963102900619, 546472623618203656, 385427, 1609059347335713652);
        check_d(424552495534070310, 861196069396009537, 937423, 1285748475527384668);
        check_d(200508555420862777, 295999683041451752, 152751, 496508176038357848);
        check_d(1106552615004777085, 1145349862678209600, 183721, 2251902475863327626);
        check_d(788070202702013406, 898058933862356590, 178657, 1686129116399055382);
        check_d(1104254340346115646, 944317986002910072, 198691, 2048572294734408977);
        check_d(713102237291899420, 157804376883817378, 68208, 870902240822716089);
        check_d(596162136054505693, 96302746176136941, 442375, 692464030686324681);
        check_d(1085194899004282297, 518773761988209247, 364225, 1603968347282862629);
        check_d(433821165441663919, 44012702421519679, 278410, 477832160563926999);
        check_d(246827195399957179, 921779600970024617, 473884, 1168606179162803849);
        check_d(1008798638562515081, 891352180797053365, 650095, 1900150813754942727);
        check_d(212711306820314323, 273742699261824628, 230685, 486453989220338337);
        check_d(679043461354570206, 972292322105972492, 978593, 1651335755986594578);
        check_d(1063782211925118286, 115108500676191415, 200099, 1178885300024160714);
        check_d(360722437847510820, 334078461111227848, 10298, 694800849282158430);
        check_d(698007396999477475, 798794233450093110, 595726, 1496801624727678632);
        check_d(853888946749566925, 260642672026951293, 29511, 1114524153976684136);
        check_d(529218183071202495, 580440891366563904, 690860, 1109659072722856845);
        check_d(724449601862357957, 784726712633418658, 903740, 1509176313161689323);
        check_d(995465407479091789, 209450459837361462, 854251, 1204915344879020624);
        check_d(651067137428398271, 680622204084476542, 77410, 1331689337274081376);
        check_d(312037719658884153, 817667496365569729, 460499, 1129704908749889268);
        check_d(670708075277557887, 912367769113743899, 914198, 1583075823733888032);
        check_d(183154651237507707, 1018911547909837099, 943489, 1202065603065420286);
        check_d(935888456466794064, 499827394094084566, 393402, 1435715665126119716);
        check_d(216894239925849491, 964903025316804599, 483464, 1181796448342901360);
        check_d(771656612020526129, 180253787919935080, 197658, 951908886219846739);
        check_d(996920164932269490, 1003924764276117611, 122359, 2000844929108182185);
        check_d(384790973974708597, 328127925110556696, 783835, 712918896194207730);
        check_d(1008654264510834716, 673912089265190568, 972359, 1682566318120208274);
        check_d(893939313496799420, 451790310246225858, 52824, 1345728082329451496);
        check_d(912190422482274985, 761474123160466597, 957444, 1673664538497048238);
        check_d(67289867447076614, 1046246600081768488, 929304, 1113534428623517910);
        check_d(706494982823985960, 1143092733231313718, 667175, 1849587634262153456);
        check_d(1029955343887396265, 952334094170483825, 24444, 1982289375793376362);
        check_d(942253715913628306, 209319568910177868, 728215, 1151572746438759378);
        check_d(1129109885802456422, 707089869356181426, 98776, 1836199236801582911);
        check_d(21604290952469288, 242910367040752648, 455123, 264513979996979025);
        check_d(628484541607366840, 912674384515788940, 827041, 1541158893325976911);
        check_d(871270596981584522, 860901672257213591, 496685, 1732172269176312503);
        check_d(119629012964319458, 917684848026352137, 80390, 1037304503972244931);
        check_d(1047549255719809765, 8541180666743584, 26233, 1055484336564650163);
        check_d(107980605434516927, 856796946047568124, 301119, 964775124194240728);
        check_d(920801100878680257, 299624099018241362, 693093, 1220424892062714880);
        check_d(933474716972360604, 488938463256194942, 857981, 1422413090503212056);
        check_d(270590800649501416, 329452295101890332, 477289, 600043089643840622);
        check_d(144733378983232640, 778939572228829634, 273475, 923671444967875956);
        check_d(828999129044224736, 30229391586640526, 873875, 859225391499002175);
        check_d(823378504671756346, 485812002342050380, 442186, 1309190401585384382);
        check_d(860385944765299655, 714447907739017324, 115215, 1574833793306589222);
        check_d(909327093482510962, 427786918228409554, 887513, 1337113899452079769);
        check_d(454158508780354720, 892877175191765368, 171723, 1347035218567471244);
        check_d(967032360419142501, 604289647367343297, 987796, 1571321963013227702);
        check_d(580316183247767924, 772174360210359445, 584123, 1352490519683170104);
        check_d(965508761473892462, 1095753053064980027, 285969, 2061261800092088681);
        check_d(844751678486850882, 488912137633317257, 235601, 1333663599187117010);
        check_d(1080604235434743036, 120513205919135456, 470536, 1201115182839936002);
        check_d(427488587006389430, 727729208895811819, 584473, 1155217724312066968);
        check_d(406531824373262825, 981237784831263634, 808611, 1387769431577262136);
        check_d(236329326438186215, 438339552711354618, 6622, 674663863182402058);
        check_d(548529427188681152, 1037685167254811300, 373580, 1586214371335176050);
        check_d(779621173861400649, 1085255214817718993, 893213, 1864876359865855423);
        check_d(805418855697628939, 917290006839953806, 536996, 1722708855744642483);
        check_d(1007159419289486841, 271784414310901189, 499533, 1278943201347604744);
        check_d(29674717031957481, 454171714466514294, 572603, 483845019279794241);
        check_d(626638826268044624, 322981918532767356, 184519, 949620451720140058);
        check_d(632955821814998909, 315700204240676831, 256348, 948655793054981461);
        check_d(928197657558097043, 695880694705780193, 373329, 1624078306826772504);
        check_d(756714633203197736, 301870857152079602, 884426, 1058585354853502657);
        check_d(43976972133356980, 1138061057477028873, 967864, 1182034378431030668);
        check_d(583885210719686548, 382315587148302460, 673356, 966200765221786429);
        check_d(107428726993484749, 455944976939436755, 233581, 563372956316756696);
        check_d(385084432691356821, 933269425760439795, 783140, 1318353682500222630);
        check_d(1098370886857237821, 884425439997259080, 393267, 1982796297158675200);
        check_d(27506536451230162, 773832562995861741, 386014, 801332309202946254);
        check_d(591076420091335809, 639093531123418221, 947475, 1230169950224170947);
        check_d(994141664486974119, 771739769224889278, 342914, 1765881392212364602);
        check_d(424741896666865328, 847493564762142243, 701859, 1272235348933274268);
        check_d(162917582360707691, 727439975145134704, 734895, 890357150270735689);
        check_d(389487191853583807, 403556773460309655, 351240, 793043964958453203);
        check_d(18982342333692776, 252873770270094133, 326788, 271854927514609736);
        check_d(725972077515342023, 908583135181876633, 522254, 1634555192918573408);
        check_d(346405240346680342, 953819307686177835, 553039, 1300224219869089783);
        check_d(1134035601710290242, 943622919447271050, 790836, 2077658510030928192);
        check_d(333107731046601311, 598604317378704528, 496166, 931711965448433987);
        check_d(732714276104319823, 333029971926256594, 902713, 1065744151419053631);
        check_d(642595132837366404, 353261371923185880, 344596, 995856371543520635);
        check_d(578537962250503601, 1140906144656400890, 148940, 1719443415485231722);
        check_d(945231884389005836, 1011780109751756444, 844737, 1957011992799758736);
        check_d(695394575203629189, 371571834086885379, 822147, 1066966343456357419);
        check_d(787869843561457144, 45648283344889187, 835430, 833516216614626703);
        check_d(841682609271034168, 288711464113452959, 467523, 1130393693082939248);
        check_d(103221308708164741, 853116239636209254, 779204, 956336568648179808);
        check_d(1011010347417223362, 18557049923878969, 565471, 1029555449369244023);
        check_d(710663992181963531, 487325309659055492, 529530, 1197989261110856800);
        check_d(688200915684311747, 237243089311108062, 877166, 925443840732066742);
        check_d(310655248834681631, 1028492880322353550, 654268, 1339147716533167923);
        check_d(99020308061501777, 980357117791493481, 906154, 1079376234461066535);
        check_d(968866577657858098, 1083320481737939672, 415770, 2052187051695401897);
        check_d(952325060331248607, 760889392837828036, 787491, 1713214439415534813);
        check_d(801270973683670420, 829339466711374202, 838450, 1630610440106834656);
        check_d(450093846264461257, 530130505453355878, 120796, 980224324486330602);
        check_d(645394585244647492, 917817921784128229, 417728, 1563212448423039879);
        check_d(30136767569127020, 699674825244739449, 695150, 729808802877757981);
        check_d(481443567926688126, 86245621619702777, 950351, 567688908691227925);
        check_d(1085381908624465340, 735485057661737846, 238170, 1820866819723697706);
        check_d(641188905586287340, 147140263264641168, 41519, 788323028799496811);
        check_d(359354021609603439, 787448031499106849, 597610, 1146801897757870111);
        check_d(916686111927660598, 638103831063645393, 601101, 1554789900094149746);
        check_d(97538046812472267, 514589878544947915, 110314, 612125521784558343);
        check_d(147131305502155838, 1036210650075320006, 879460, 1183341083549070937);
        check_d(675001916515712900, 404659131016496497, 8285, 1079656689579868528);
        check_d(713281400425424774, 295711927051996860, 574565, 1008993146015338269);
        check_d(1009906373456246268, 1009915071763536926, 829685, 2019821445219783171);
        check_d(10120917975700918, 90849129398769673, 587777, 100969895180562728);
        check_d(63072738776643730, 1074953404085360262, 654391, 1138022860036653810);
        check_d(461530643694808036, 438528429508653213, 547239, 900059072666003680);
        check_d(347036197541814969, 327746324266900035, 327312, 674782520965658419);
        check_d(59485738436000280, 139129227065909302, 617408, 198614934682937816);
        check_d(210095769570811094, 211094274230267989, 51677, 421190043778176269);
        check_d(1126875067952414060, 735988950574667715, 620900, 1862863949435968920);
        check_d(518936209367448591, 1001904358333317811, 252384, 1520840229770872094);
        check_d(351336678389215118, 437558448250495228, 843012, 788895120982930107);
        check_d(334254208810108048, 880877647589000803, 454583, 1215131517318514334);
        check_d(432836097208834096, 274589801292670627, 366034, 707425847600366808);
        check_d(819440251167542913, 285119502756610407, 827034, 1104559549921903047);
        check_d(733572688789447523, 937705919839890894, 173143, 1671278535537485481);
        check_d(491661289322705152, 75574188099104715, 22277, 567220649095313893);
        check_d(938155120492132833, 20011809209261509, 734892, 958159611959761847);
        check_d(11574816404475471, 1087882175725233073, 857820, 1099442253715201693);
        check_d(685222825843033632, 570324086120578929, 27607, 1255546719926659300);
        check_d(760157332890307241, 421231851849271155, 873065, 1181389124060411328);
        check_d(93085214482307509, 412303500348466544, 560474, 505388415565494987);
        check_d(258054031853163002, 984444636846546953, 78594, 1242494564341909688);
        check_d(430808065875739767, 629717599372688240, 231011, 1060525581557555812);
        check_d(271115681068918392, 138918415676371426, 520561, 410034051058792621);
        check_d(1135908348221855067, 450488085667764746, 715170, 1586396179324492048);
        check_d(456258610641359646, 592118492725519123, 531298, 1048377086514885035);
        check_d(933763709409767505, 1094535996931599710, 160348, 2028299666353227468);
        check_d(14076964774692025, 749012133296552563, 56139, 763002089012169009);
        check_d(16692182990743510, 476211001193667866, 62135, 492876848005082609);
        check_d(504607800848894580, 1107972248584319899, 732139, 1612579870160742946);
        check_d(465110489411621896, 825069873815119762, 243254, 1290180139375980345);
        check_d(703228958217331539, 334813174245900094, 929587, 1038042051997390299);
        check_d(702071762929838060, 646785920159438912, 647986, 1348857681337835401);
        check_d(822105333055523984, 195016031937561617, 909135, 1017121021976991936);
        check_d(381170602728809523, 198425901479446230, 957130, 579596470785970745);
        check_d(86514692695825846, 374446991946072349, 788147, 460961497544783798);
        check_d(524833831196339601, 1023485144043582088, 197167, 1548318520854693882);
        check_d(191643780019858573, 1009145179286693633, 252065, 1200786901574474233);
        check_d(813345328797497479, 1129595596349836781, 889215, 1942940895415195124);
        check_d(1021467542470939389, 39374171164469072, 709164, 1060837229513985140);
        check_d(104668776327270312, 1042971214290391778, 465068, 1147637502953837883);
        check_d(38352169475497743, 1048528822278837244, 861405, 1086876989509420856);
        check_d(1139595136218180817, 42202057792841081, 853619, 1181792860660436183);
        check_d(1137127101266081431, 710371476557804243, 26510, 1847496613873041261);
        check_d(84690278240999959, 1046592131400766575, 584739, 1131279885197224155);
        check_d(610149706529709939, 419219308817828497, 162683, 1029368902625563316);
        check_d(436607895570225032, 438680120300862323, 516397, 875288015866337169);
        check_d(27587669905629499, 730359077560815670, 229127, 757936612324494155);
        check_d(397532564966472622, 722855237281364394, 570539, 1120387711841931303);
        check_d(544844518997543045, 403794432749936184, 817908, 948638938636963982);
        check_d(112954713363081016, 370312195615174223, 638714, 483266759219997934);
        check_d(1087592060543068556, 55852092505380700, 804563, 1143441039928460823);
        check_d(186946729823527801, 149151137400731278, 494076, 336097862867946970);
        check_d(852321527038769504, 879890846002521005, 100958, 1732212370867658972);
        check_d(187409340968290362, 329960086809832995, 958295, 517369405601399487);
        check_d(1141344443871594521, 1095343921558211526, 847415, 2236688364871365265);
        check_d(1026080450515119468, 643334302752834312, 20475, 1669412491589248513);
        check_d(373245446211992026, 325802102129885935, 909363, 699047546563266217);
        check_d(685240436486857775, 307588477372886759, 636069, 992828781836688270);
        check_d(116737832242478225, 807544760826095743, 450704, 924281295424095674);
        check_d(646948635240345382, 606646824844294032, 329923, 1253595458119031492);
        check_d(441097244101024912, 713497476571591803, 900732, 1154594682895254920);
        check_d(614126567638707416, 351852554657363302, 481510, 965979042466579601);
        check_d(904897910169136337, 743711486561701352, 379491, 1648609375766652545);
        check_d(1144723337264586472, 21853335018575128, 531808, 1166562852765585525);
        check_d(449508936494440964, 329669372900821735, 718262, 779178296253704713);
        check_d(463795910629120853, 946896976887043323, 336130, 1410692608724354033);
        check_d(800883281019360823, 1030148521922590954, 268328, 1831031748598701458);
        check_d(1005597691306381502, 18406060926159244, 280361, 1023979715267351523);
        check_d(502132935245774757, 906233759827772185, 129023, 1408366205435301449);
        check_d(987274654247972792, 1040558028615482562, 814422, 2027832682003311185);
        check_d(949051071554807639, 755939963093717095, 528126, 1704991013672105696);
        check_d(453414530587515130, 519244938663463465, 414615, 972659463853261032);
        check_d(598196966966172516, 331274552927244250, 575778, 929471447344992873);
        check_d(567296816172226368, 921569322377686092, 643173, 1488866069083692231);
        check_d(963589138966398261, 739460320609894705, 268014, 1703049403579034900);
        check_d(378428616560196483, 1113927832749055388, 456249, 1492355924619420893);
        check_d(595819424021770917, 1103525842845710658, 972091, 1699345181200720479);
        check_d(508352575853673193, 584979111026103595, 178426, 1093331671756205884);
        check_d(865222485164669150, 1102791534254599375, 235060, 1968013957515643964);
        check_d(206297206627288465, 213167977190593170, 393711, 419465183674918895);
        check_d(236594147571028546, 90986723269138592, 503370, 327580790723098183);
        check_d(890595968434364757, 1016847731892887231, 444629, 1907443690888790030);
        check_d(495977036501544316, 873119299016816013, 849651, 1369096269361007219);
        check_d(398267457227086767, 325005810360818891, 265067, 723273253444874192);
        check_d(472136898324008888, 936252850496575804, 26459, 1408386506679382372);
        check_d(828196176199834199, 777517213688485042, 990400, 1605713389080006976);
        check_d(958096861897457107, 933503787764933050, 202160, 1891600648871452550);
        check_d(24307692019426160, 827498459709952387, 467102, 851798841122292690);
        check_d(156529896101989124, 823569623683829079, 994436, 980099094571251899);
        check_d(1021979501150257033, 1070218649855012307, 144822, 2092198147163247269);
        check_d(821547216228833152, 742070634337564373, 541700, 1563617846828033576);
        check_d(751151357198449844, 825038392498153694, 460246, 1576189745925552506);
        check_d(570227353892836957, 1069893723777897735, 294851, 1640120793124284030);
        check_d(645422135975348609, 318407970968370298, 348222, 963829926908219550);
        check_d(230920903418012600, 269754682176848003, 169093, 500675576634504472);
        check_d(1099667514703400151, 112159740673839486, 364651, 1211823971013473196);
        check_d(173238788920410710, 186241377359132820, 128301, 359480164444316348);
        check_d(432046288804038029, 367938434718911275, 333747, 799984715776725036);
        check_d(1021491410036344819, 675824853900062057, 480088, 1697316187447787990);
        check_d(652572454175475708, 270211923240955865, 76185, 922783122120367017);
        check_d(1112896482862801960, 634394312518317607, 167839, 1747290373360967367);
        check_d(1140563184432769702, 928386277759606930, 294290, 2068949424830295735);
        check_d(70742036906804956, 747208415134482384, 371224, 817948067696188341);
        check_d(286556149457754439, 170500499799045754, 466242, 457056615476398587);
        check_d(664747792349527472, 70673839540517366, 340578, 735419604252204958);
        check_d(828260102566228168, 423979041836272695, 305974, 1252238906298463514);
        check_d(273260353792112728, 878857869660239384, 280321, 1152117438900076035);
        check_d(396983215483684108, 942290969600179075, 728353, 1339274002373577900);
        check_d(1038991992625382705, 913701168510017513, 870805, 1952693156500453421);
        check_d(576660825055303907, 395599645040749272, 897183, 972260450629662002);
        check_d(745272273994528044, 153496407070680395, 75705, 898764138278156268);
        check_d(642856257680205695, 158295546064378793, 143746, 801150196295410847);
        check_d(638256002655171429, 663079715965747121, 813387, 1301335718329729898);
        check_d(1013022309240332105, 303371211758620236, 731833, 1316393152548423980);
        check_d(953166941140070429, 211981544128074444, 106438, 1165144765010412734);
        check_d(1132864603250316407, 112407452888573559, 45307, 1245243963896701971);
        check_d(2813793467750776, 784773586808019211, 610195, 787542712146761908);
        check_d(608978756367101513, 1142713197153925853, 328625, 1751691680763531789);
        check_d(816593571390244886, 600908810582340865, 387116, 1417502338579960981);
        check_d(540722276907126536, 846662818444787157, 338968, 1387384990750809462);
        check_d(195892950391578704, 765369886597105314, 83188, 961259712750552110);
        check_d(592560699020804134, 460290041786141946, 150719, 1052850684796573042);
        check_d(451769450465686523, 19140980125081775, 710900, 470908638403451763);
        check_d(62458341146621602, 490400274767276651, 959718, 552858185379826227);
        check_d(803675037683971588, 697227084867918597, 849787, 1500902118087401925);
        check_d(417801819492490342, 12846629496902201, 922808, 430646666733334430);
        check_d(189624138850746804, 707306093434744719, 393035, 896929662304268836);
        check_d(402659449148772098, 733229501985408585, 377786, 1135888812027525611);
        check_d(647770871734008164, 402513260134570841, 186954, 1050283969865632522);
        check_d(555687562829349396, 425878043857633783, 887034, 981565596838128482);
        check_d(939053362424191915, 945468846668558428, 435425, 1884522209067670875);
        check_d(292337923983972966, 3303917635660590, 89216, 295606027525479224);
        check_d(608314722565522097, 220785937999190151, 408367, 829100376790242623);
        check_d(610254489598287896, 581853841257015038, 109976, 1192108327777396001);
        check_d(626804077881253357, 1127450529643160781, 401430, 1754254413782063542);
        check_d(272792147408719352, 214939526792928214, 338898, 487731663932873973);
        check_d(276483029635442359, 169723254558728609, 322107, 446206242136082436);
        check_d(1002753707653353570, 328433955277078863, 248036, 1331186736695072996);
        check_d(288306285196042674, 34193483002283944, 148023, 322497984359071334);
        check_d(1100085269929110156, 263541125506145841, 819710, 1363625893500636556);
        check_d(1106018549879488578, 61749650205442419, 87553, 1167741581268446293);
        check_d(910047973251896966, 536925447686524267, 79095, 1446972769399865225);
        check_d(402950604066253855, 560882564848223240, 967483, 963833155171387614);
        check_d(488169830974506167, 791379345413295639, 832905, 1279549130689405490);
        check_d(1097176075162593026, 273500013306334300, 917263, 1370675666160928523);
        check_d(78545770627430840, 117272448805710835, 95016, 195818177489782340);
        check_d(1148881733400359731, 926404019314265723, 746830, 2075285736561266538);
        check_d(667620663724137253, 459395020578765899, 167761, 1127015565589812618);
        check_d(362746148002294985, 158673798250334033, 422459, 521419834624901658);
        check_d(1060237344901797781, 432155586339069041, 412046, 1492392541446793580);
        check_d(420479250159583365, 514100905167879277, 593871, 934580147351311074);
        check_d(515322625079134743, 809901006005588814, 522461, 1325223565162020900);
        check_d(816482641110838847, 410316967057526566, 168233, 1226799159309924033);
        check_d(165540251557573466, 696009059897181609, 375546, 861548611087234311);
        check_d(367845943028253775, 273719131365474461, 858624, 641565066175035327);
        check_d(356387942412248503, 427293697675390823, 139992, 783681616985254612);
        check_d(70534611656826058, 506770500075756721, 18615, 577284476391450685);
        check_d(16933549672390358, 1084379808743985585, 25234, 1100975153386341864);
        check_d(232308815853259849, 742093973429285477, 302212, 974402181729286154);
        check_d(972174469522389662, 410138661327507054, 790932, 1382312957776770597);
        check_d(727918203255414479, 606143800807363578, 122156, 1334061958182991258);
        check_d(1029180472033952799, 202296884025705065, 428556, 1231476176460059272);
        check_d(406001551119771989, 696365873932424665, 931870, 1102367380955925178);
        check_d(144442571710562115, 1132561902235607333, 800353, 1277003283579582880);
        check_d(351492998376344865, 45152766245201902, 718844, 396645356787694129);
        check_d(735835055231121507, 1127869596544825020, 387996, 1863704540585375597);
        check_d(71268245341421120, 650483402286465009, 626765, 721750605938984406);
        check_d(496682098338883199, 806472085023137172, 263896, 1303154035472255036);
        check_d(98589312397184887, 179770228737839752, 87003, 278359392426282958);
        check_d(509785065918470023, 877671927487634929, 532935, 1387456894967911996);
        check_d(288333551013185683, 207259863514751938, 175799, 495593375769520531);
        check_d(449238946799606685, 318434028400991487, 68271, 767672807090178868);
        check_d(1025927360713680861, 4124532329325871, 970557, 1030019162809752175);
        check_d(529854860765039117, 364679590482280727, 547537, 894534422412685529);
        check_d(426204066296441280, 71060087809713383, 970053, 497263887256810890);
        check_d(16442663922575548, 381600156292980144, 521010, 398040790823386007);
        check_d(831779637478102307, 452731343244662756, 29954, 1284508935612717249);
        check_d(485210928902929042, 168394341322108280, 718623, 653605130562052747);
        check_d(892979526743683689, 1051717629211032102, 781745, 1944697147611796696);
        check_d(606083432350697358, 87007941560501762, 238225, 693089515774782282);
        check_d(712364716439804146, 922924172782316389, 150754, 1635288797786844416);
        check_d(1012907885283847984, 1008756165910354090, 319941, 2021664051180877676);
        check_d(66895786077310417, 370916771465450410, 905128, 437812332316529807);
        check_d(254617292008205459, 546707395191003248, 275906, 801324464690867692);
        check_d(217467905727619793, 810050294246333348, 552324, 1027517736426103073);
        check_d(983108963565777965, 988549595926565502, 132142, 1971658559435537206);
        check_d(959062422729989604, 933440798366332629, 811054, 1892503220882439364);
        check_d(364317494984948299, 835263278844667165, 215016, 1199580265547802839);
        check_d(343320763973055064, 1087576029336384819, 261160, 1430895777310605158);
        check_d(10729894334755724, 977496241186755425, 9125, 987024333168194103);
        check_d(564716630288226027, 1127097718304845916, 699716, 1691814198413990702);

    }

    #[test]
    fun test_compute_y() {
        check_y(1098512304148995858, 1609597799242156845, 794249, 511085650789627788);
        check_y(105551774673150097, 1351287543179933404, 636274, 1245738393152745968);
        check_y(2045250484898639148, 2296831376791770037, 1188, 253077307234641934);
        check_y(754878898244470000, 875763650012995345, 499821, 120885716480132307);
        check_y(857824581244523356, 1809516247477169523, 863310, 951691669060371080);
        check_y(867139950084152027, 1727010261947987339, 371562, 859870311905014323);
        check_y(8155777549389559399, 1349690409671689975, 9, 608429477304216);
        check_y(151441492345899655, 767033477680579831, 738333, 615592285424504359);
        check_y(842274085351741180, 1438707793064061574, 575383, 596433745314710894);
        check_y(19540493057896515, 659161371856618959, 23089, 639730640357487053);
        check_y(785594198032231554, 1691817800116105066, 413991, 906223612524930043);
        check_y(191788264760594505, 702366723109909301, 65535, 510579848686970473);
        check_y(467971633868208692, 1405729296937309688, 794630, 937757774277178910);
        check_y(681564053529888794, 1504058865883285302, 384869, 822494829660827583);
        check_y(745027730217739713, 1000442106435448245, 466830, 255414713683344119);
        check_y(311003516782169532, 671494115904590227, 700409, 360490601740147867);
        check_y(272802965083447436, 768184182569387688, 324792, 495381325865093117);
        check_y(262995697825609466, 1327359843959453152, 203243, 1064366018999355670);
        check_y(4766289146745791, 704997686688870927, 105552, 700352368988298188);
        check_y(502033037069164421, 780629951928393145, 562066, 278596976826860653);
        check_y(630949985641812281, 959509505239959207, 759576, 328559589247058252);
        check_y(974842651596563139, 1061344606181023111, 179565, 86508868019235307);
        check_y(95782907249936317, 524470581241876219, 630611, 428687954586930997);
        check_y(360206372162485991, 568716557335181440, 454602, 208510233084640767);
        check_y(63115252783798806, 1106112592902374941, 962818, 1042999434685050793);
        check_y(1007401520058251841, 1465291871245291148, 642370, 457890537840737153);
        check_y(19794854198899264, 1104904511276546488, 44593, 1085273273774124203);
        check_y(1127301777868477837, 1313861101988134231, 273178, 186561853922024877);
        check_y(860753431284229474, 1721382308104226448, 577371, 860628876820004778);
        check_y(350233118687010031, 930570551977814885, 554450, 580337487943047709);
        check_y(646984568610274840, 1144834783614075090, 37406, 497850479159965425);
        check_y(1005130829776268769, 1132393087883724776, 486517, 127264010922262336);
        check_y(681378521145220415, 2085403080751752367, 199593, 1404025272526846217);
        check_y(483537163592165366, 775942457874817231, 245709, 292405396274883027);
        check_y(302912742566074154, 830016229665586797, 936642, 527103521968914820);
        check_y(1142633981016844252, 1956003281606511678, 315244, 813369391064219230);
        check_y(375040385825548589, 1607083639196140460, 972411, 1232043581737044528);
        check_y(491603869397198193, 1500531412861847985, 659026, 1008927697032899840);
        check_y(70325128824984210, 727488017120133364, 969086, 657163587533696672);
        check_y(142379855825130803, 419493667277178850, 592, 277154506588979847);
        check_y(715133026787924796, 1507066942982534634, 923022, 791933918320235459);
        check_y(214213849717113041, 920695595084094182, 958738, 706481937578875722);
        check_y(308689888843243168, 1148096624095398551, 653574, 839406973936536624);
        check_y(1040952369870512272, 2133654925321682641, 839713, 1092702556198984762);
        check_y(453487967748268387, 1151708033247165346, 862206, 698220097082720525);
        check_y(1090377424537971488, 1371507062941013158, 594184, 281130254804883955);
        check_y(300108137698365254, 1481202206356226214, 14440, 1181122142617722689);
        check_y(1063284633306362445, 2100910694296059131, 226661, 1037626061681071304);
        check_y(609765294263704420, 842477859077490035, 593638, 232712742546266458);
        check_y(166214792453908082, 1654367918750170245, 225104, 1488159616540411236);
        check_y(354314635110826958, 1010294911751926787, 271024, 655980459081450164);
        check_y(740258427599019149, 1715602809632821719, 670658, 975344406509613482);
        check_y(1109096581315593400, 1375428297001480793, 185342, 266333946097541260);
        check_y(1062586963102900619, 1609059347335713652, 385427, 546472623618203656);
        check_y(335334196678271686, 1285748475527384668, 937423, 950414482366983902);
        check_y(200508555420862777, 496508176038357848, 152751, 295999683041451751);
        check_y(292900317421270253, 2251902475863327626, 183721, 1959009570624844221);
        check_y(788070202702013406, 1686129116399055382, 178657, 898058933862356590);
        check_y(761013012940679464, 2048572294734408977, 198691, 1287559646459510840);
        check_y(713102237291899420, 870902240822716089, 68208, 157804376883817377);
        check_y(457849829435446487, 692464030686324681, 442375, 234614292025553504);
        check_y(1085194899004282297, 1603968347282862629, 364225, 518773761988209247);
        check_y(287178171700888342, 477832160563926999, 278410, 190654025369813422);
        check_y(246827195399957179, 1168606179162803849, 473884, 921779600970024616);
        check_y(943408557866603700, 1900150813754942727, 650095, 956742255960304976);
        check_y(212711306820314323, 486453989220338337, 230685, 273742699261824628);
        check_y(462412322954167039, 1651335755986594578, 978593, 1188923635541341579);
        check_y(1063782211925118286, 1178885300024160714, 200099, 115108500676191415);
        check_y(142057363049148187, 694800849282158430, 10298, 552761600026213065);
        check_y(698007396999477475, 1496801624727678632, 595726, 798794233450093110);
        check_y(700374554217595367, 1114524153976684136, 29511, 414150933040294945);
        check_y(529218183071202495, 1109659072722856845, 690860, 580440891366563904);
        check_y(68508325284706026, 1509176313161689323, 903740, 1440671969930345048);
        check_y(995465407479091789, 1204915344879020624, 854251, 209450459837361462);
        check_y(315259115506506371, 1331689337274081376, 77410, 1016433521005103500);
        check_y(312037719658884153, 1129704908749889268, 460499, 817667496365569729);
        check_y(419400190458073403, 1583075823733888032, 914198, 1163675878960374282);
        check_y(183154651237507707, 1202065603065420286, 943489, 1018911547909837098);
        check_y(153599687213135313, 1435715665126119716, 393402, 1282118928023548867);
        check_y(216894239925849491, 1181796448342901360, 483464, 964903025316804599);
        check_y(304891146805905486, 951908886219846739, 197658, 647018096606007245);
        check_y(996920164932269490, 2000844929108182185, 122359, 1003924764276117611);
        check_y(122301488315035936, 712918896194207730, 783835, 590617753074377926);
        check_y(1008654264510834716, 1682566318120208274, 972359, 673912089265190568);
        check_y(184431495994433734, 1345728082329451496, 52824, 1161310774195713987);
        check_y(912190422482274985, 1673664538497048238, 957444, 761474123160466596);
        check_y(13949411611359092, 1113534428623517910, 929304, 1099596525930997699);
        check_y(706494982823985960, 1849587634262153456, 667175, 1143092733231313717);
        check_y(967897451968191274, 1982289375793376362, 24444, 1014391946143167476);
        check_y(942253715913628306, 1151572746438759378, 728215, 209319568910177868);
        check_y(191907012112381343, 1836199236801582911, 98776, 1644307758056546156);
        check_y(21604290952469288, 264513979996979025, 455123, 242910367040752648);
        check_y(523637807889340333, 1541158893325976911, 827041, 1017521192072717631);
        check_y(59302900917042434, 1037304503972244931, 80390, 978025074058873644);
        check_y(871270596981584522, 1732172269176312503, 496685, 860901672257213591);
        check_y(1047549255719809765, 1055484336564650163, 26233, 8541180666743584);
        check_y(24985065341172800, 964775124194240728, 301119, 939804332545390595);
        check_y(933474716972360604, 1422413090503212056, 857981, 488938463256194942);
        check_y(279387794798706938, 1220424892062714880, 693093, 941037463761093749);
        check_y(74027052794100076, 923671444967875956, 273475, 849648430248364278);
        check_y(270590800649501416, 600043089643840622, 477289, 329452295101890331);
        check_y(828999129044224736, 859225391499002175, 873875, 30229391586640525);
        check_y(458293465980862642, 1309190401585384382, 442186, 850897081887787957);
        check_y(909327093482510962, 1337113899452079769, 887513, 427786918228409554);
        check_y(658663572462289114, 1574833793306589222, 115215, 916170408589767707);
        check_y(227956910810980143, 1571321963013227702, 987796, 1343365860047586838);
        check_y(454158508780354720, 1347035218567471244, 171723, 892877175191765367);
        check_y(580316183247767924, 1352490519683170104, 584123, 772174360210359444);
        check_y(675698035871019371, 2061261800092088681, 285969, 1385564249170188344);
        check_y(1080604235434743036, 1201115182839936002, 470536, 120513205919135456);
        check_y(722779824558337679, 1333663599187117010, 235601, 610883794693912882);
        check_y(59753447115484680, 1387769431577262136, 808611, 1328020332947455634);
        check_y(427488587006389430, 1155217724312066968, 584473, 727729208895811819);
        check_y(236329326438186215, 674663863182402058, 6622, 438339552711354618);
        check_y(201703080369937410, 1586214371335176050, 373580, 1384513949892177789);
        check_y(805418855697628939, 1722708855744642483, 536996, 917290006839953806);
        check_y(174370429213359364, 1864876359865855423, 893213, 1690507965775810000);
        check_y(22356162786530013, 483845019279794241, 572603, 461490830703843931);
        check_y(1007159419289486841, 1278943201347604744, 499533, 271784414310901188);
        check_y(626638826268044624, 949620451720140058, 184519, 322981918532767356);
        check_y(327952890769108292, 948655793054981461, 256348, 620703097039661359);
        check_y(756714633203197736, 1058585354853502657, 884426, 301870857152079602);
        check_y(490038055675130064, 1624078306826772504, 373329, 1134040656978402939);
        check_y(37462228160168525, 966200765221786429, 673356, 928742632195074616);
        check_y(43976972133356980, 1182034378431030668, 967864, 1138061057477028872);
        check_y(107428726993484749, 563372956316756696, 233581, 455944976939436754);
        check_y(19228870323580958, 1318353682500222630, 783140, 1299138611008559757);
        check_y(27506536451230162, 801332309202946254, 386014, 773832562995861740);
        check_y(393146574849676185, 1982796297158675200, 393267, 1589651165990128214);
        check_y(10497923846441999, 1765881392212364602, 342914, 1755489813555009176);
        check_y(591076420091335809, 1230169950224170947, 947475, 639093531123418221);
        check_y(424741896666865328, 1272235348933274268, 701859, 847493564762142242);
        check_y(114449147879313641, 890357150270735689, 734895, 775908748549918853);
        check_y(18982342333692776, 271854927514609736, 326788, 252873770270094133);
        check_y(56970266017621932, 793043964958453203, 351240, 736076802807920230);
        check_y(109934288209535460, 1300224219869089783, 553039, 1190292552971348782);
        check_y(725972077515342023, 1634555192918573408, 522254, 908583135181876632);
        check_y(1134035601710290242, 2077658510030928192, 790836, 943622919447271050);
        check_y(266723320281270293, 931711965448433987, 496166, 664988855077443984);
        check_y(642595132837366404, 995856371543520635, 344596, 353261371923185879);
        check_y(245943984927158241, 1065744151419053631, 902713, 819800407523923256);
        check_y(522459194993144755, 1957011992799758736, 844737, 1434553119240338673);
        check_y(578537962250503601, 1719443415485231722, 148940, 1140906144656400890);
        check_y(695394575203629189, 1066966343456357419, 822147, 371571834086885379);
        check_y(777437931676741237, 833516216614626703, 835430, 56079773413926085);
        check_y(103221308708164741, 956336568648179808, 779204, 853116239636209254);
        check_y(723703243039310196, 1130393693082939248, 467523, 406690553240003644);
        check_y(60503733866633447, 1197989261110856800, 529530, 1137490293296296644);
        check_y(1011010347417223362, 1029555449369244023, 565471, 18557049923878968);
        check_y(688200915684311747, 925443840732066742, 877166, 237243089311108061);
        check_y(112681255519118767, 1339147716533167923, 654268, 1226468757570783284);
        check_y(968866577657858098, 2052187051695401897, 415770, 1083320481737939672);
        check_y(92334685693148931, 1079376234461066535, 906154, 987042856567646974);
        check_y(674080108776804229, 1630610440106834656, 838450, 956530361408531654);
        check_y(952325060331248607, 1713214439415534813, 787491, 760889392837828036);
        check_y(450093846264461257, 980224324486330602, 120796, 530130505453355878);
        check_y(382539226064018345, 1563212448423039879, 417728, 1180673882109071048);
        check_y(481443567926688126, 567688908691227925, 950351, 86245621619702777);
        check_y(18164552220986545, 729808802877757981, 695150, 711649132874522467);
        check_y(438949639883170062, 788323028799496811, 41519, 349373513092030721);
        check_y(1085381908624465340, 1820866819723697706, 238170, 735485057661737846);
        check_y(359354021609603439, 1146801897757870111, 597610, 787448031499106848);
        check_y(170371014732272451, 1554789900094149746, 601101, 1384420905781751381);
        check_y(147131305502155838, 1183341083549070937, 879460, 1036210650075320006);
        check_y(16038037401761912, 612125521784558343, 110314, 596111894444156168);
        check_y(429401436660929992, 1008993146015338269, 574565, 579591729249976311);
        check_y(675001916515712900, 1079656689579868528, 8285, 404659131016496497);
        check_y(1009906373456246268, 2019821445219783171, 829685, 1009915071763536926);
        check_y(4317600221976688, 100969895180562728, 587777, 96652733653107485);
        check_y(461530643694808036, 900059072666003680, 547239, 438528429508653212);
        check_y(50026156875565351, 1138022860036653810, 654391, 1088001006117598101);
        check_y(11303299590039106, 198614934682937816, 617408, 187312223454611281);
        check_y(347036197541814969, 674782520965658419, 327312, 327746324266900035);
        check_y(210095769570811094, 421190043778176269, 51677, 211094274230267989);
        check_y(207017036916505626, 1862863949435968920, 620900, 1655849209075307357);
        check_y(351336678389215118, 788895120982930107, 843012, 437558448250495227);
        check_y(384730089540900319, 1520840229770872094, 252384, 1136111113140701804);
        check_y(110252296520013472, 707425847600366808, 366034, 597174421036636780);
        check_y(334254208810108048, 1215131517318514334, 454583, 880877647589000803);
        check_y(819440251167542913, 1104559549921903047, 827034, 285119502756610407);
        check_y(547550032619799115, 1671278535537485481, 173143, 1123729153917164062);
        check_y(938155120492132833, 958159611959761847, 734892, 20011809209261509);
        check_y(72445380187059487, 567220649095313893, 22277, 494791105627669552);
        check_y(649117949709256229, 1255546719926659300, 27607, 606428796534596440);
        check_y(11574816404475471, 1099442253715201693, 857820, 1087882175725233073);
        check_y(760157332890307241, 1181389124060411328, 873065, 421231851849271154);
        check_y(48025052646405057, 505388415565494987, 560474, 457364222752157699);
        check_y(430808065875739767, 1060525581557555812, 231011, 629717599372688239);
        check_y(175495189094882568, 1242494564341909688, 78594, 1067007762618530751);
        check_y(148472785874772487, 1586396179324492048, 715170, 1437925552875133462);
        check_y(271115681068918392, 410034051058792621, 520561, 138918415676371425);
        check_y(456258610641359646, 1048377086514885035, 531298, 592118492725519122);
        check_y(419179155204054731, 2028299666353227468, 160348, 1609123830390660807);
        check_y(16692182990743510, 492876848005082609, 62135, 476211001193667866);
        check_y(3565544863745733, 763002089012169009, 56139, 759794838783097564);
        check_y(159233829208394785, 1290180139375980345, 243254, 1130949786299560430);
        check_y(504607800848894580, 1612579870160742946, 732139, 1107972248584319899);
        check_y(703228958217331539, 1038042051997390299, 929587, 334813174245900093);
        check_y(280083916447837279, 1348857681337835401, 647986, 1068774305580105228);
        check_y(381170602728809523, 579596470785970745, 957130, 198425901479446229);
        check_y(725202778555111913, 1017121021976991936, 909135, 291918367438225529);
        check_y(427591582598905882, 1548318520854693882, 197167, 1120727922360556822);
        check_y(86514692695825846, 460961497544783798, 788147, 374446991946072349);
        check_y(191643780019858573, 1200786901574474233, 252065, 1009145179286693633);
        check_y(747387542901226543, 1942940895415195124, 889215, 1195553413907841268);
        check_y(1021467542470939389, 1060837229513985140, 709164, 39374171164469072);
        check_y(104668776327270312, 1147637502953837883, 465068, 1042971214290391777);
        check_y(38352169475497743, 1086876989509420856, 861405, 1048528822278837244);
        check_y(1139595136218180817, 1181792860660436183, 853619, 42202057792841080);
        check_y(1137127101266081431, 1847496613873041261, 26510, 710371476557804242);
        check_y(84690278240999959, 1131279885197224155, 584739, 1046592131400766575);
        check_y(610149706529709939, 1029368902625563316, 162683, 419219308817828496);
        check_y(436607895570225032, 875288015866337169, 516397, 438680120300862323);
        check_y(27587669905629499, 757936612324494155, 229127, 730359077560815670);
        check_y(397532564966472622, 1120387711841931303, 570539, 722855237281364394);
        check_y(544844518997543045, 948638938636963982, 817908, 403794432749936184);
        check_y(112954713363081016, 483266759219997934, 638714, 370312195615174222);
        check_y(1087592060543068556, 1143441039928460823, 804563, 55852092505380700);
        check_y(186946729823527801, 336097862867946970, 494076, 149151137400731277);
        check_y(852321527038769504, 1732212370867658972, 100958, 879890846002521004);
        check_y(187409340968290362, 517369405601399487, 958295, 329960086809832995);
        check_y(1141344443871594521, 2236688364871365265, 847415, 1095343921558211526);
        check_y(1026080450515119468, 1669412491589248513, 20475, 643334302752834311);
        check_y(373245446211992026, 699047546563266217, 909363, 325802102129885934);
        check_y(685240436486857775, 992828781836688270, 636069, 307588477372886758);
        check_y(116737832242478225, 924281295424095674, 450704, 807544760826095742);
        check_y(646948635240345382, 1253595458119031492, 329923, 606646824844294032);
        check_y(441097244101024912, 1154594682895254920, 900732, 713497476571591803);
        check_y(614126567638707416, 965979042466579601, 481510, 351852554657363302);
        check_y(904897910169136337, 1648609375766652545, 379491, 743711486561701352);
        check_y(1144723337264586472, 1166562852765585525, 531808, 21853335018575127);
        check_y(449508936494440964, 779178296253704713, 718262, 329669372900821734);
        check_y(463795910629120853, 1410692608724354033, 336130, 946896976887043322);
        check_y(800883281019360823, 1831031748598701458, 268328, 1030148521922590954);
        check_y(1005597691306381502, 1023979715267351523, 280361, 18406060926159243);
        check_y(502132935245774757, 1408366205435301449, 129023, 906233759827772185);
        check_y(987274654247972792, 2027832682003311185, 814422, 1040558028615482562);
        check_y(949051071554807639, 1704991013672105696, 528126, 755939963093717094);
        check_y(453414530587515130, 972659463853261032, 414615, 519244938663463464);
        check_y(598196966966172516, 929471447344992873, 575778, 331274552927244249);
        check_y(567296816172226368, 1488866069083692231, 643173, 921569322377686092);
        check_y(963589138966398261, 1703049403579034900, 268014, 739460320609894704);
        check_y(378428616560196483, 1492355924619420893, 456249, 1113927832749055388);
        check_y(595819424021770917, 1699345181200720479, 972091, 1103525842845710657);
        check_y(508352575853673193, 1093331671756205884, 178426, 584979111026103594);
        check_y(865222485164669150, 1968013957515643964, 235060, 1102791534254599375);
        check_y(206297206627288465, 419465183674918895, 393711, 213167977190593169);
        check_y(236594147571028546, 327580790723098183, 503370, 90986723269138592);
        check_y(890595968434364757, 1907443690888790030, 444629, 1016847731892887230);
        check_y(495977036501544316, 1369096269361007219, 849651, 873119299016816012);
        check_y(398267457227086767, 723273253444874192, 265067, 325005810360818890);
        check_y(472136898324008888, 1408386506679382372, 26459, 936252850496575803);
        check_y(828196176199834199, 1605713389080006976, 990400, 777517213688485042);
        check_y(958096861897457107, 1891600648871452550, 202160, 933503787764933050);
        check_y(24307692019426160, 851798841122292690, 467102, 827498459709952387);
        check_y(156529896101989124, 980099094571251899, 994436, 823569623683829078);
        check_y(1021979501150257033, 2092198147163247269, 144822, 1070218649855012307);
        check_y(821547216228833152, 1563617846828033576, 541700, 742070634337564372);
        check_y(751151357198449844, 1576189745925552506, 460246, 825038392498153693);
        check_y(570227353892836957, 1640120793124284030, 294851, 1069893723777897734);
        check_y(645422135975348609, 963829926908219550, 348222, 318407970968370298);
        check_y(230920903418012600, 500675576634504472, 169093, 269754682176848003);
        check_y(1099667514703400151, 1211823971013473196, 364651, 112159740673839485);
        check_y(173238788920410710, 359480164444316348, 128301, 186241377359132819);
        check_y(432046288804038029, 799984715776725036, 333747, 367938434718911275);
        check_y(1021491410036344819, 1697316187447787990, 480088, 675824853900062057);
        check_y(652572454175475708, 922783122120367017, 76185, 270211923240955864);
        check_y(1112896482862801960, 1747290373360967367, 167839, 634394312518317607);
        check_y(1140563184432769702, 2068949424830295735, 294290, 928386277759606929);
        check_y(70742036906804956, 817948067696188341, 371224, 747208415134482384);
        check_y(286556149457754439, 457056615476398587, 466242, 170500499799045754);
        check_y(664747792349527472, 735419604252204958, 340578, 70673839540517365);
        check_y(828260102566228168, 1252238906298463514, 305974, 423979041836272694);
        check_y(273260353792112728, 1152117438900076035, 280321, 878857869660239383);
        check_y(396983215483684108, 1339274002373577900, 728353, 942290969600179075);
        check_y(1038991992625382705, 1952693156500453421, 870805, 913701168510017512);
        check_y(576660825055303907, 972260450629662002, 897183, 395599645040749272);
        check_y(745272273994528044, 898764138278156268, 75705, 153496407070680394);
        check_y(642856257680205695, 801150196295410847, 143746, 158295546064378793);
        check_y(638256002655171429, 1301335718329729898, 813387, 663079715965747120);
        check_y(1013022309240332105, 1316393152548423980, 731833, 303371211758620235);
        check_y(953166941140070429, 1165144765010412734, 106438, 211981544128074444);
        check_y(1132864603250316407, 1245243963896701971, 45307, 112407452888573558);
        check_y(2813793467750776, 787542712146761908, 610195, 784773586808019210);
        check_y(608978756367101513, 1751691680763531789, 328625, 1142713197153925852);
        check_y(816593571390244886, 1417502338579960981, 387116, 600908810582340865);
        check_y(540722276907126536, 1387384990750809462, 338968, 846662818444787156);
        check_y(195892950391578704, 961259712750552110, 83188, 765369886597105314);
        check_y(592560699020804134, 1052850684796573042, 150719, 460290041786141946);
        check_y(451769450465686523, 470908638403451763, 710900, 19140980125081775);
        check_y(62458341146621602, 552858185379826227, 959718, 490400274767276651);
        check_y(803675037683971588, 1500902118087401925, 849787, 697227084867918596);
        check_y(417801819492490342, 430646666733334430, 922808, 12846629496902200);
        check_y(189624138850746804, 896929662304268836, 393035, 707306093434744718);
        check_y(402659449148772098, 1135888812027525611, 377786, 733229501985408585);
        check_y(647770871734008164, 1050283969865632522, 186954, 402513260134570840);
        check_y(555687562829349396, 981565596838128482, 887034, 425878043857633782);
        check_y(939053362424191915, 1884522209067670875, 435425, 945468846668558428);
        check_y(292337923983972966, 295606027525479224, 89216, 3303917635660589);
        check_y(608314722565522097, 829100376790242623, 408367, 220785937999190150);
        check_y(610254489598287896, 1192108327777396001, 109976, 581853841257015038);
        check_y(626804077881253357, 1754254413782063542, 401430, 1127450529643160780);
        check_y(272792147408719352, 487731663932873973, 338898, 214939526792928213);
        check_y(276483029635442359, 446206242136082436, 322107, 169723254558728609);
        check_y(1002753707653353570, 1331186736695072996, 248036, 328433955277078863);
        check_y(288306285196042674, 322497984359071334, 148023, 34193483002283944);
        check_y(1100085269929110156, 1363625893500636556, 819710, 263541125506145841);
        check_y(1106018549879488578, 1167741581268446293, 87553, 61749650205442418);
        check_y(910047973251896966, 1446972769399865225, 79095, 536925447686524266);
        check_y(402950604066253855, 963833155171387614, 967483, 560882564848223240);
        check_y(488169830974506167, 1279549130689405490, 832905, 791379345413295638);
        check_y(1097176075162593026, 1370675666160928523, 917263, 273500013306334299);
        check_y(78545770627430840, 195818177489782340, 95016, 117272448805710835);
        check_y(1148881733400359731, 2075285736561266538, 746830, 926404019314265722);
        check_y(667620663724137253, 1127015565589812618, 167761, 459395020578765898);
        check_y(362746148002294985, 521419834624901658, 422459, 158673798250334033);
        check_y(1060237344901797781, 1492392541446793580, 412046, 432155586339069040);
        check_y(420479250159583365, 934580147351311074, 593871, 514100905167879277);
        check_y(515322625079134743, 1325223565162020900, 522461, 809901006005588814);
        check_y(816482641110838847, 1226799159309924033, 168233, 410316967057526565);
        check_y(165540251557573466, 861548611087234311, 375546, 696009059897181609);
        check_y(367845943028253775, 641565066175035327, 858624, 273719131365474460);
        check_y(356387942412248503, 783681616985254612, 139992, 427293697675390822);
        check_y(70534611656826058, 577284476391450685, 18615, 506770500075756720);
        check_y(16933549672390358, 1100975153386341864, 25234, 1084379808743985584);
        check_y(232308815853259849, 974402181729286154, 302212, 742093973429285477);
        check_y(972174469522389662, 1382312957776770597, 790932, 410138661327507053);
        check_y(727918203255414479, 1334061958182991258, 122156, 606143800807363577);
        check_y(1029180472033952799, 1231476176460059272, 428556, 202296884025705065);
        check_y(406001551119771989, 1102367380955925178, 931870, 696365873932424664);
        check_y(144442571710562115, 1277003283579582880, 800353, 1132561902235607332);
        check_y(351492998376344865, 396645356787694129, 718844, 45152766245201901);
        check_y(735835055231121507, 1863704540585375597, 387996, 1127869596544825019);
        check_y(71268245341421120, 721750605938984406, 626765, 650483402286465008);
        check_y(496682098338883199, 1303154035472255036, 263896, 806472085023137172);
        check_y(98589312397184887, 278359392426282958, 87003, 179770228737839751);
        check_y(509785065918470023, 1387456894967911996, 532935, 877671927487634928);
        check_y(288333551013185683, 495593375769520531, 175799, 207259863514751938);
        check_y(449238946799606685, 767672807090178868, 68271, 318434028400991487);
        check_y(1025927360713680861, 1030019162809752175, 970557, 4124532329325870);
        check_y(529854860765039117, 894534422412685529, 547537, 364679590482280726);
        check_y(426204066296441280, 497263887256810890, 970053, 71060087809713382);
        check_y(16442663922575548, 398040790823386007, 521010, 381600156292980143);
        check_y(831779637478102307, 1284508935612717249, 29954, 452731343244662755);
        check_y(485210928902929042, 653605130562052747, 718623, 168394341322108280);
        check_y(892979526743683689, 1944697147611796696, 781745, 1051717629211032102);
        check_y(606083432350697358, 693089515774782282, 238225, 87007941560501761);
        check_y(712364716439804146, 1635288797786844416, 150754, 922924172782316389);
        check_y(1012907885283847984, 2021664051180877676, 319941, 1008756165910354090);
        check_y(66895786077310417, 437812332316529807, 905128, 370916771465450410);
        check_y(254617292008205459, 801324464690867692, 275906, 546707395191003248);
        check_y(217467905727619793, 1027517736426103073, 552324, 810050294246333348);
        check_y(983108963565777965, 1971658559435537206, 132142, 988549595926565501);
        check_y(959062422729989604, 1892503220882439364, 811054, 933440798366332628);
        check_y(364317494984948299, 1199580265547802839, 215016, 835263278844667164);
        check_y(343320763973055064, 1430895777310605158, 261160, 1087576029336384819);
        check_y(10729894334755724, 987024333168194103, 9125, 977496241186755425);
        check_y(564716630288226027, 1691814198413990702, 699716, 1127097718304845916);
    }

    #[test]
    fun test_swap() {
        check_swap(990102159702100011, 1151973823846701879, 183733960284297466, 928095, 2142075983548801890, 185815523188, 183733774468774278);
        check_swap(1098512304148995858, 511085650789627788, 21855182491769970, 794249, 1609597954938623646, 13746439899, 21855168745330071);
        check_swap(680828681135416811, 7807546316995058, 82410887408133632, 792996, 688636227452411869, 280885030, 82410887127248602);
        check_swap(422590584965501443, 544645914991196718, 551383572466366465, 48406, 967236499956698161, 128808955559990331, 422574616906376134);
        check_swap(752950248789862680, 713900361779999507, 731814311454194037, 135342, 1466850610569862187, 89613008809104, 731724698445384933);
        check_swap(165122385464154103, 384666163750024998, 24773810861436238, 525492, 549788549214179101, 211592740723, 24773599268695515);
        check_swap(319188259185568119, 418754804619748071, 580969826988949531, 223876, 737943063805316190, 261782162555508660, 319187664433440871);
        check_swap(213293790751246167, 596699263173888970, 282606328854235837, 290840, 809993053925135137, 69316009620595575, 213290319233640262);
        check_swap(66853519460351384, 161443263512907317, 985608814940728005, 345670, 228296782973258701, 918754467596415546, 66854347344312459);
        check_swap(195381755352852283, 1083427880603906074, 720864848221108935, 124744, 1278809635956758357, 525484315401321756, 195380532819787179);
        check_swap(181512761320369839, 149212749748071041, 227065804752892253, 761035, 330725511068440880, 45553365986633604, 181512438766258649);
        check_swap(683147788342113182, 658006297220640183, 707788282170895005, 209458, 1341154085562753365, 24683158482485219, 683105123688409786);
        check_swap(27439079399511343, 932225962185987168, 253209789918632682, 718788, 959665041585498511, 225770820319914470, 27438969598718212);
        check_swap(410063770053375633, 566435595377919519, 717995082038469925, 851404, 976499365431295152, 307931581651089547, 410063500387380378);
        check_swap(108779099854265654, 1050852271706063976, 692966614566292085, 348617, 1159631371560329630, 584187710365549378, 108778904200742707);
        check_swap(41758097720466769, 203025478928005894, 1039764452489033394, 285930, 244783576648472663, 998005814591205750, 41758637897827644);
        check_swap(46772346686349946, 1019273476001358550, 288229989673798403, 482065, 1066045822687708496, 241457921822594633, 46772067851203770);
        check_swap(781729115759070999, 151440627126302750, 246670380588019246, 539671, 933169742885373749, 29270555704, 246670351317463542);
        check_swap(450357899131767005, 1080100373201869213, 248166139897138978, 290654, 1530458272333636218, 3256776218895, 248162883120920083);
        check_swap(1131548013196438444, 105093614112585245, 235728134674772847, 778391, 1236641627309023689, 5738908238, 235728128935864609);
        check_swap(557828227804374817, 1089056110482069837, 1043984223284330699, 932506, 1646884338286444654, 486156476116784893, 557827747167545806);
        check_swap(1113039145396709406, 269246851019189407, 650810403495076651, 362814, 1382285996415898813, 419965366424, 650809983529710227);
        check_swap(663851332086932615, 625128634646589158, 934982127658014396, 591356, 1288979966733521773, 271131718986887250, 663850408671127146);
        check_swap(55265399055343071, 1045810865141004815, 473897823295194431, 939282, 1101076264196347886, 418632495107853818, 55265328187340613);
        check_swap(927754807165593577, 231479065191888839, 973271179942027367, 167136, 1159233872357482416, 45535342767326755, 927735837174700612);
        check_swap(1073396976980204221, 679300589460084094, 503483385235854600, 888506, 1752697566440288315, 233050067093, 503483152185787507);
        check_swap(1055822633613892841, 301398781680589311, 1055941985197310979, 810391, 1357221415294482152, 595440736059133, 1055346544461251846);
        check_swap(722142775826118628, 147259398887365007, 740796840111366283, 826821, 869402174713483635, 18659620423977430, 722137219687388853);
        check_swap(50994731741965962, 434597682724487190, 108745734353261566, 694504, 485592414466453152, 57751421220880506, 50994313132381060);
        check_swap(398772750246691742, 1112359062556386450, 790995541793312092, 324628, 1511131812803078192, 392224253602898279, 398771288190413813);
        check_swap(457090411767864777, 236783441598022668, 1047611035517732313, 448377, 693873853365887445, 590519684078942946, 457091351438789367);
        check_swap(69701080364286956, 998286830005059962, 413247277734203287, 897332, 1067987910369346918, 343546315489379724, 69700962244823563);
        check_swap(902798902010776125, 1058722013563576822, 726087254011078726, 597335, 1961520915574352947, 3432393641533, 726083821617437193);
        check_swap(311063843162541812, 596467209110388959, 376044577602640450, 746723, 907531052272930771, 64982658804641835, 311061918797998615);
        check_swap(324220761648133255, 210020536533280260, 468695516370446987, 759826, 534241298181413515, 144474898589470756, 324220617780976231);
        check_swap(28975812157279949, 696939165100638590, 909825666975352828, 555396, 725914977257918539, 880849842547485041, 28975824427867787);
        check_swap(261953393660241490, 296155217853975336, 283459955495969724, 42099, 558108611514216826, 21547751513563403, 261912203982406321);
        check_swap(900977827479580734, 912138682189197705, 579603268341257644, 666271, 1813116509668778439, 1068808546276, 579602199532711368);
        check_swap(492353049546529532, 75610928035776838, 388868354251515854, 844751, 567963977582306370, 252278131017, 388868101973384837);
        check_swap(342521693541792501, 949540255134435008, 273837231993768786, 246332, 1292061948676227509, 10467401113723, 273826764592655063);
        check_swap(200954927488884401, 570926918874556851, 985771094490520941, 158129, 771881846363441252, 784815791059669632, 200955303430851309);
        check_swap(1130234935163152474, 276248517622598844, 121718709026099807, 844234, 1406483452785751318, 6579173263, 121718702446926544);
        check_swap(664128810773085032, 1141537613799632946, 1008022203876206870, 755402, 1805666424572717978, 343894611579197692, 664127592297009178);
        check_swap(495617001895217315, 177369454415687086, 743134095691201857, 356587, 672986456310904401, 247516660865030083, 495617434826171774);
        check_swap(65835459756930362, 848708640595274085, 854562900007136199, 262147, 914544100352204447, 788727458035283118, 65835441971853081);
        check_swap(1035463378816039496, 307718430957718356, 434632087373290460, 326806, 1343181809773757852, 193891446071, 434631893481844389);
        check_swap(601746315096326807, 535760773324112357, 19198014299118387, 606454, 1137507088420439164, 53161684668, 19197961137433719);
        check_swap(71780117690104996, 711229818190210126, 941353669365326684, 159690, 783009935880315122, 869573463592946730, 71780205772379954);
        check_swap(846181168904229445, 4118068537203171, 955215837902467440, 332016, 850299237441432616, 108953776285081498, 846262061617385942);
        check_swap(212701362119200674, 204142890004822930, 715661759628593785, 723702, 416844252124023604, 502960118600272210, 212701641028321575);
        check_swap(234201803497696121, 38288254249381628, 228820373080381052, 594822, 272490057747077749, 2729481292797, 228817643599088255);
        check_swap(485898716435266565, 108486898661595581, 739983995215261431, 372646, 594385615096862146, 254084083210608897, 485899912004652534);
        check_swap(227396981452615545, 937037597346985918, 638905749751811230, 785836, 1164434578799601463, 411509027652469428, 227396722099341802);
        check_swap(650848360921454302, 495249316829855687, 1061835039619189735, 634710, 1146097677751309989, 410986843306829267, 650848196312360468);
        check_swap(253277652867425949, 959114120726819121, 209709716866463644, 366045, 1212391773594245070, 10320045891034, 209699396820572610);
        check_swap(638994314611586698, 188519831133089580, 1112531398047877590, 899156, 827514145744676278, 473536404973386007, 638994993074491583);
        check_swap(213500944113046110, 826028790413049174, 1128255246368988926, 980144, 1039529734526095284, 914754281909566181, 213500964459422745);
        check_swap(446025184623725388, 504972681698643446, 313475253204376117, 505303, 950997866322368834, 1075884996649, 313474177319379468);
        check_swap(474404450660378617, 185822168468431896, 801635741950746698, 817925, 660226619128810513, 327230984561515838, 474404757389230860);
        check_swap(711121572792189349, 781129580099120244, 374529951433956818, 916465, 1492251152891309593, 419118713288, 374529532315243530);
        check_swap(428626183810882568, 545717877182970801, 727220253884414978, 275125, 974344060993853369, 298594929804810188, 428625324079604790);
        check_swap(996097377156826078, 749927527367615134, 406023893502827318, 465631, 1746024904524441212, 402465732459, 406023491037094859);
        check_swap(253068365070998776, 14111291335437040, 266990268595379389, 813140, 267179656406435816, 13921915201295280, 253068353394084109);
        check_swap(655546770218417729, 984750986965405354, 333340611003924519, 816224, 1640297757183823083, 663557108635, 333339947446815884);
        check_swap(477739861927712826, 343655223672556677, 381391733285996332, 802321, 821395085600269503, 750342326021, 381390982943670311);
        check_swap(115607817495815471, 811191855788015365, 169275055436856900, 698842, 926799673283830836, 53669399534435620, 115605655902421280);
        check_swap(858608160530120196, 737320991823397110, 20846964863190038, 806529, 1595929152353517306, 50517680916, 20846914345509122);
        check_swap(1052462321639944727, 279917652377014834, 120142506370102902, 121121, 1332379974016959561, 53195084379, 120142453175018523);
        check_swap(867178812864340042, 998019624578995959, 1131455686820228140, 525320, 1865198437443336001, 264279500519284459, 867176186300943681);
        check_swap(958013708224124863, 478469715293167685, 632586337976317289, 101565, 1436483423517292548, 3610827713716, 632582727148603573);
        check_swap(176656264780150125, 1010405676742107196, 33172991042696347, 570021, 1187061941522257321, 1463137038308, 33171527905658039);
        check_swap(64233703740076775, 994248612205318401, 1123087709879814114, 699351, 1058482315945395176, 1058854000513900715, 64233709365913399);
        check_swap(310257171877527212, 1098668837226053588, 477337285326750600, 132972, 1408926009103580800, 167088727807349094, 310248557519401506);
        check_swap(295840079878447196, 396753745502854764, 769042502726976892, 587397, 692593825381301960, 473202346592320367, 295840156134656525);
        check_swap(922239260998522042, 270732741773208059, 485399299096443070, 37268, 1192972002771730101, 2782268065684, 485396516828377386);
        check_swap(600093114945910121, 953823171281206667, 1001142073704100875, 311016, 1553916286227116788, 401050632610016497, 600091441094084378);
        check_swap(241940758696819269, 1015031903134549385, 557475042856064891, 416181, 1256972661831368654, 315535164841110745, 241939878014954146);
        check_swap(255307304435836888, 63932261626555954, 1103612622406062663, 994705, 319239566062392842, 848303221861238580, 255309400544824083);
        check_swap(856749780324535339, 454551037516952730, 20513812950056113, 829224, 1311300817841488069, 14738754832, 20513798211301281);
        check_swap(1073945665000235949, 1121356296104260769, 887153796425875747, 390522, 2195301961104496718, 6324315731671, 887147472110144076);
        check_swap(926131562284327643, 215884718911508809, 623984052876477119, 258313, 1142016281195836452, 830809977570, 623983222066499549);
        check_swap(179966386820319612, 305899793796593920, 485692942708757327, 501665, 485866180616913532, 305726556063037569, 179966386645719758);
        check_swap(570302516510492734, 544706804577905268, 1019972441841438688, 367924, 1115009321088398002, 449670178551555969, 570302263289882719);
        check_swap(1099703260318353264, 198961228565754514, 197233986981388906, 588971, 1298664488884107778, 11261966341, 197233975719422565);
        check_swap(46070388419407487, 91221114326684132, 843325821976653714, 993055, 137291502746091619, 797255036681905462, 46070785294748252);
        check_swap(940669469102861867, 992260785053154073, 1142361112352085126, 481879, 1932930254156015940, 201695889098095773, 940665223253989353);
        check_swap(1087587496774858778, 454719434776917739, 968323756040646439, 194238, 1542306931551776517, 10080876106299, 968313675164540140);
        check_swap(1064337914139516469, 69681527140805004, 85439740325996943, 308412, 1134019441280321473, 1362807847, 85439738963189096);
        check_swap(284751194263973121, 966418316841572412, 781194370497469332, 389868, 1251169511105545533, 496443664611443493, 284750705886025839);
        check_swap(1142821763810181183, 1068064840034682801, 769219370200329914, 429134, 2210886603844863984, 2187080953082, 769217183119376832);
        check_swap(623297899421389943, 212332595101723581, 1048956134257594556, 411973, 835630494523113524, 425657213023682645, 623298921233911911);
        check_swap(605394606786964989, 208581805309476857, 153980075631553463, 100747, 813976412096441846, 160929211368, 153979914702342095);
        check_swap(1048253845760126216, 208657606626516465, 147831043616454244, 801992, 1256911452386642681, 6239155270, 147831037377298974);
        check_swap(996162709296073883, 1101709496199986977, 732914357913017703, 164318, 2097872205496060860, 8505453914140, 732905852459103563);
        check_swap(533294198916486171, 350636218883872382, 1046997365644407462, 309690, 883930417800358553, 513702591870443174, 533294773773964288);
        check_swap(547993595467646946, 898302803625988561, 67898997988207489, 704360, 1446296399093635507, 230531107504, 67898767457099985);
        check_swap(115122823678541195, 1060135160397419807, 489166018598761541, 122343, 1175257984075961002, 374044511353489430, 115121507245272111);
        check_swap(274704450082904476, 1054693960995114363, 984293540343861952, 643348, 1329398411078018839, 709589249705729266, 274704290638132686);
        check_swap(839910054432526286, 625768468142627993, 706276058380656956, 993146, 1465678522575154279, 1518764150810, 706274539616506146);
        check_swap(310725537240526073, 533693326474175499, 740282087454968062, 551981, 844418863714701572, 429556655940363342, 310725431514604720);
        check_swap(482363601869079322, 72472558795013316, 600015005978797193, 329593, 554836160664092638, 117650518612502769, 482364487366294424);
        check_swap(8967582676715694, 984069630595493886, 520532745050998623, 549494, 993037213272209580, 511565174991158176, 8967570059840447);
        check_swap(386101712734658603, 210496280150823127, 1098828718885666742, 341709, 596597992885481730, 712725387255754767, 386103331629911975);
        check_swap(885495057512668912, 671940377873637801, 956470243193407280, 415283, 1557435435386306713, 70984919926922912, 885485323266484368);
        check_swap(480487815584684992, 918218254101529787, 8436892502505013, 653986, 1398706069686214779, 230322199677, 8436662180305336);
        check_swap(332680964629025535, 618930792504844881, 538062719749611579, 219981, 951611757133870416, 205383615349498001, 332679104400113578);
        check_swap(995970636654373825, 772748303710328695, 1090371389941871465, 189242, 1768718940364702520, 94421262500218007, 995950127441653458);
        check_swap(444092640794446232, 311906502189989205, 31617263344452384, 665584, 755999142984435437, 24414924346, 31617238929528038);
        check_swap(926815484602454061, 1063519425363932479, 40576991111895503, 589340, 1990334909966386540, 161837180448, 40576829274715055);
        check_swap(578837599622314565, 288648453434169289, 751370866461228303, 744489, 867486053056483854, 172533657913307894, 578837208547920409);
        check_swap(643907439730280501, 1050386311017612472, 888900950566805477, 63455, 1694293750747892973, 245012732662985416, 643888217903820061);
        check_swap(230781954984453181, 781039241617143071, 741142398726881613, 213555, 1011821196601596252, 510360875159272292, 230781523567609321);
        check_swap(158793860788498735, 1036275149934436238, 690958136437669763, 500822, 1195069010722934973, 532164501734384793, 158793634703284970);
        check_swap(889376329731179915, 514321399488101865, 592638451492054019, 585295, 1403697729219281780, 695475456932, 592637756016597087);
        check_swap(171265523558495697, 345338491567123289, 740879692337293701, 692681, 516604015125618986, 569614050788014444, 171265641549279257);
        check_swap(95186016079128641, 109647796940250507, 179758259541848533, 451430, 204833813019379148, 84572290381398812, 95185969160449721);
        check_swap(433034060101819123, 358119183273204785, 994663568191609464, 288917, 791153243375023908, 561628911723948833, 433034656467660631);
        check_swap(840257276886663644, 525106635925559718, 965338873635264991, 138060, 1365363912812223362, 125093234240363119, 840245639394901872);
        check_swap(9673909616790931, 1145756190400466328, 894427998482408126, 407254, 1155430100017257259, 884754095147555792, 9673903334852334);
        check_swap(937195224903781049, 709640346532033472, 1027676392724061234, 7371, 1646835571435814521, 90952912022359043, 936723480701702191);
        check_swap(545663112327639118, 1022254289385661517, 828960467288108609, 154894, 1567917401713300635, 283302839161637293, 545657628126471316);
        check_swap(310671504212888072, 1072076464008946672, 371036037240771805, 483852, 1382747968221834744, 60371881926843419, 310664155313928386);
        check_swap(442061296758154160, 843476759285908526, 680259127046876337, 844818, 1285538056044062686, 238198627439783139, 442060499607093198);
        check_swap(668137214232630153, 1126086961382583241, 66556889707931461, 567030, 1794224175615213394, 346463760207, 66556543244171254);
        check_swap(493968758519502121, 708431327401185482, 969812583179861754, 877735, 1202400085920687603, 475844021402591644, 493968561777270110);
        check_swap(73844712303121542, 533397364290410526, 353575719103035078, 842364, 607242076593532068, 279731067346138327, 73844651756896751);
        check_swap(1082490782738495684, 1063480831033388812, 815810089010907839, 215085, 2145971613771884496, 6739817190627, 815803349193717212);
        check_swap(769906799239075238, 905600438754333964, 484716409766038022, 979009, 1675507237993409202, 718093739481, 484715691672298541);
        check_swap(220138705585717055, 493990048560275183, 1110959866786664648, 105930, 714128754145992238, 890819940556455209, 220139926230209439);
        check_swap(754623777128168574, 635213418000734668, 1099447661313652297, 669758, 1389837195128903242, 344824521992544390, 754623139321107907);
        check_swap(11127148158088554, 737335637242940503, 807991545368249563, 207500, 748462785401029057, 796864393066013208, 11127152302236355);
        check_swap(420387233005322448, 929326067590816326, 154140020374332499, 489786, 1349713300596138774, 903267640345, 154139117106692154);
        check_swap(181995065157352026, 1122299008790681314, 715838032404061348, 556046, 1304294073948033340, 533843234542736780, 181994797861324568);
        check_swap(962714019450525941, 855867870418841169, 414672762762797582, 394032, 1818581889869367110, 652823657192, 414672109939140390);
        check_swap(630477679403740910, 1119676273684727768, 683612263641592826, 568086, 1750153953088468678, 53146770481172329, 630465493160420497);
        check_swap(214147424181398104, 761922459851092408, 1002927866992939693, 199750, 976069884032490512, 788780409182610026, 214147457810329667);
        check_swap(417578608997630608, 894486694129711751, 1047550811933383610, 576025, 1312065303127342359, 629972429609946552, 417578382323437058);
        check_swap(1048666235897312547, 1086336747820296833, 1108484499787580980, 314532, 2135002983717609380, 59847659442964743, 1048636840344616237);
        check_swap(491915524325651734, 683303546239490744, 114522005935678281, 545367, 1175219070565142478, 262439055737, 114521743496622544);
        check_swap(835856771753276528, 1103326482390104347, 163044604116847593, 706011, 1939183254143380875, 275591750408, 163044328525097185);
        check_swap(340083104474679979, 820971485098701011, 850840870640077287, 851312, 1161054589573380990, 510757940902402302, 340082929737674985);
        check_swap(943421662551036570, 1051592886597458946, 1009385842842287547, 282288, 1995014549148495516, 65989973442701346, 943395869399586201);
        check_swap(532267750322230201, 897329265942012906, 621123888864815001, 739391, 1429597016264243107, 88859735885622844, 532264152979192157);
        check_swap(990585555324442936, 496948716698376620, 790849115126801740, 576627, 1487534272022819556, 1558216541597, 790847556910260143);
        check_swap(478529461948002727, 167763784302922881, 1083505592703533908, 692607, 646293246250925608, 604975089930518667, 478530502773015241);
        check_swap(35084307941904245, 612451602830227076, 765512825185780063, 392615, 647535910772131321, 730428501694956911, 35084323490823152);
        check_swap(504628251321944739, 673562841796611739, 372495197998989320, 294203, 1178191093118556478, 3123821554803, 372492074177434517);
        check_swap(1066866582273995117, 221632167485300869, 533820506043583820, 390575, 1288498749759295986, 200898710584, 533820305144873236);
        check_swap(769823817612064315, 776979737310239521, 1111173913360034950, 79435, 1546803554922303836, 341357888057011962, 769816025303022988);
        check_swap(594317342698659030, 611169519839129262, 946825507672192711, 251054, 1205486862537788292, 352509342097322762, 594316165574869949);
        check_swap(730943378793575386, 387953459943939107, 447636429474912883, 310469, 1118896838737514493, 741004430864, 447635688470482019);
        check_swap(752256672727562788, 347585500749856543, 709802777091585091, 176237, 1099842173477419331, 17949388441911, 709784827703143180);
        check_swap(564825080431272786, 499317403106090902, 1135631277074255324, 368485, 1064142483537363688, 570806022842958030, 564825254231297294);
        check_swap(506180650725173858, 582002543294187167, 886708091753549581, 153793, 1088183194019361025, 380528669904909381, 506179421848640200);
        check_swap(101213601157872826, 489677216383703094, 43523778840370930, 931381, 590890817541575920, 596809514869, 43523182030856061);
        check_swap(352572733149215767, 400725347677265690, 282113481957920496, 23202, 753298080826481457, 32295422877171, 282081186535043325);
        check_swap(929497488620059968, 103238589359143931, 997803261164639137, 439850, 1032736077979203899, 68307467381526294, 929495793783112843);
        check_swap(691273058927488761, 736550995675555134, 441846561648871867, 994375, 1427824054603043895, 577584971706, 441845984063900161);
        check_swap(99578797379288349, 913004189477698341, 55326808820964579, 388520, 1012582986856986690, 6517453087434, 55320291367877145);
        check_swap(359540848947683791, 1129160035560933584, 372533503425025957, 852205, 1488700884508617375, 13017105952279587, 359516397472746370);
        check_swap(323166793695428932, 1135140706512164567, 538335170255328423, 674393, 1458307500207593499, 215169723415666719, 323165446839661704);
        check_swap(896100835011436974, 644512048894998780, 1143593450825559670, 627081, 1540612883906435754, 247494058496179580, 896099392329380090);
        check_swap(553747665713662530, 594736802555974603, 1124353557436477158, 845640, 1148484468269637133, 570605914621797429, 553747642814679729);
        check_swap(877740383395376106, 923261640475319124, 178669955018913667, 716188, 1801002023870695230, 185485510215, 178669769533403452);
        check_swap(1081281481240589084, 250857171772655486, 142604305811991825, 571110, 1332138653013244570, 10661810165, 142604295150181660);
        check_swap(199438364961931338, 940540298396061423, 785381063597721388, 757734, 1139978663357992761, 585942820195623262, 199438243402098126);
        check_swap(965313335431769184, 690447899280461712, 654795318194971585, 413195, 1655761234712230896, 1432414111891, 654793885780859694);
        check_swap(148355059513365943, 351353713568050703, 489895814080104374, 640754, 499708773081416646, 341540760322288754, 148355053757815620);
        check_swap(445723933964825482, 685046786982925100, 415587595359512137, 171169, 1130770720947750582, 28542267841441, 415559053091670696);
        check_swap(965344026201135217, 1106044497869476077, 111101404875175170, 826166, 2071388524070611294, 154178928182, 111101250696246988);
        check_swap(668172162304051788, 760101199923936342, 854693503338079203, 455591, 1428273362227988130, 186523899250596512, 668169604087482691);
        check_swap(851179230165015664, 970363733016124903, 1069730056859426020, 944107, 1821542963181140567, 218552567554026046, 851177489305399974);
        check_swap(954972277895884035, 804242896650797313, 486303366540224818, 547310, 1759215174546681348, 595402237525, 486302771137987293);
        check_swap(903023106728871562, 122880421078265159, 601772544395814955, 806456, 1025903527807136721, 190846023853, 601772353549791102);
        check_swap(18394459248644905, 280854604008750074, 504482530253107124, 228035, 299249063257394979, 486088022371045139, 18394507882061985);
        check_swap(533380723686129819, 354753382792777246, 369889490344339859, 384415, 888134106478907065, 852126312077, 369888638218027782);
        check_swap(436476189297984027, 499785171203048661, 771177493823938266, 160241, 936261360501032688, 334702259960393546, 436475233863544720);
        check_swap(85984625337962523, 670701983173132731, 512955664163766752, 70735, 756686608511095254, 426971591351112353, 85984072812654399);
        check_swap(507110516587821943, 1081245575251810963, 639877045390603478, 767716, 1588356091839632906, 132769265362520810, 507107780028082668);
        check_swap(524264277247191397, 559577878732612344, 716421962498458038, 147175, 1083842155979803741, 192161755947319514, 524260206551138524);
        check_swap(686001393131024590, 478334299572125175, 466555635195339575, 213530, 1164335692703149765, 1932774448136, 466553702420891439);
        check_swap(1075228554515771724, 239009557815332349, 4110740106833155, 288468, 1314238112331104073, 4423137620, 4110735683695535);
        check_swap(1146392193691068192, 297903133438658330, 1028848177014834579, 736356, 1444295327129726522, 2335180380700, 1028845841834453879);
        check_swap(1112263265220178896, 992056405892864740, 1013174787960491330, 12093, 2104319671113043636, 397770642028005, 1012777017318463325);
        check_swap(998144196310497254, 928436628877388576, 906514470637925753, 569852, 1926580825187885830, 7676332679431, 906506794305246322);
        check_swap(498563023430112648, 818974170774644903, 779152008412905719, 919855, 1317537194204757551, 280589616098195657, 498562392314710062);
        check_swap(164271472303205913, 119377093766129440, 990308342057674509, 585027, 283648566069335353, 826035646174447211, 164272695883227298);
        check_swap(893661939642802737, 519693971312302838, 854658622438751880, 415019, 1413355910955105575, 14177704427691, 854644444734324189);
        check_swap(942497147929533066, 377935189135772837, 884270697153910067, 640123, 1320432337065305903, 5106856653354, 884265590297256713);
        check_swap(615154726327282596, 571394339391336905, 924101909383719226, 821017, 1186549065718619501, 308947607785853849, 615154301597865377);
        check_swap(409493562486719500, 208517461832648240, 75800762586297620, 531187, 618011024319367740, 26226044313, 75800736360253307);
        check_swap(277347170636307052, 887997726459256873, 1093663592760336097, 334746, 1165344897095563925, 816316484656024171, 277347108104311926);
        check_swap(1070325950214808231, 58305038782147943, 1117059990418285932, 615336, 1128630988996956174, 46735229177406560, 1070324761240879372);
        check_swap(1106381158618224796, 860884257552372420, 1115578919836145658, 87506, 1967265416170597216, 9760653358865170, 1105818266477280488);
        check_swap(719176453997521775, 521183766785183499, 1039322749676999593, 902914, 1240360220782705274, 320146649296650089, 719176100380349504);
        check_swap(4356796341886810, 327626762622636588, 712443435103364303, 935111, 331983558964523398, 708086634218111874, 4356800885252429);
        check_swap(162507125920073090, 85685544467549666, 425795651546638762, 184031, 248192670387622756, 263287425365013681, 162508226181625081);
        check_swap(505224350353577173, 897109297937376839, 406469535664751793, 934987, 1402333648290954012, 2138423001205, 406467397241750588);
        check_swap(207259634032218315, 488255418310961563, 394682692809028992, 163040, 695515052343179878, 187424368597294081, 207258324211734911);
        check_swap(909749719661199620, 237166223617811543, 737455945930400905, 452520, 1146915943279011163, 1294113764761, 737454651816636144);
        check_swap(376444895990571376, 1018106673354762365, 439556624169887746, 945234, 1394551569345333741, 63115466356707300, 376441157813180446);
        check_swap(15440373680011227, 326481609184753304, 885239554981284385, 814912, 341921982864764531, 869799154666272445, 15440400315011940);
        check_swap(504917938389862612, 306298871036880159, 1117642555994816174, 554096, 811216809426742771, 612724025368226531, 504918530626589643);
        check_swap(523808175096473245, 867523642278570134, 629504983362191569, 63050, 1391331817375043379, 105729844054479537, 523775139307712032);
        check_swap(470841083889280951, 524515493611041497, 518946749573862271, 580084, 995356577500322448, 48109878788935169, 470836870784927102);
        check_swap(962739443688398589, 765227072605280443, 3852842428856598, 917968, 1727966516293679032, 37380912154, 3852805047944444);
        check_swap(992808596527384244, 115834486235369531, 140237796831767305, 232549, 1108643082762753775, 9549062548, 140237787282704757);
        check_swap(910227353994887791, 136912973696128461, 710507681079509766, 92829, 1047140327691016252, 3918004898384, 710503763074611382);
        check_swap(457651729940307003, 300388145182646778, 180582162811325877, 824973, 758039875122953781, 80268202039, 180582082543123838);
        check_swap(700811920793810943, 664860116349695073, 303957767914621579, 513925, 1365672037143506016, 408091468149, 303957359823153430);
        check_swap(104955550608699980, 1072175953404808109, 929064802674375839, 250697, 1177131504013508089, 824109359739155576, 104955442935220263);
        check_swap(5784078242600272, 140841369278812444, 636778543683895283, 214555, 146625447521412716, 630994371840029146, 5784171843866137);
        check_swap(132783012634353576, 905065611960275876, 28101847224328836, 43210, 1037848624594629452, 21608034610746, 28080239189718090);
        check_swap(591639021128862768, 8115545091882537, 510948875870433641, 485892, 599754566220745305, 743308086189, 510948132562347452);
        check_swap(262005210814230994, 1119241608703713411, 418448079265638667, 272997, 1381246819517944405, 156447017888523306, 262001061377115361);
        check_swap(972634855746966645, 604951686349339830, 235363013492481420, 247052, 1577586542096306475, 258121781840, 235362755370699580);
        check_swap(717501199014751890, 1016949366788054322, 1109555439810488665, 943608, 1734450565802806212, 392054985165592384, 717500454644896281);
        check_swap(259694546165899835, 705805951681623335, 687307469742680359, 621639, 965500497847523170, 427613119686544793, 259694350056135566);
        check_swap(145654111103262742, 649573693581962011, 320411246737590348, 456515, 795227804685224753, 174757733125137090, 145653513612453258);
        check_swap(327562076958367543, 128672510736427263, 585201191689528701, 334384, 456234587694794806, 257638465640627283, 327562726048901418);
        check_swap(437703711964111063, 842954817990154123, 339566140920671927, 818261, 1280658529954265186, 2009847353761, 339564131073318166);
        check_swap(1033298520441960862, 116159873400312808, 570689004481953120, 345254, 1149458393842273670, 220619408921, 570688783862544199);
        check_swap(1078856340848366665, 950815450201692333, 39595474481623350, 577411, 2029671791050058998, 99703921423, 39595374777701927);
        check_swap(799039873900778254, 116906127715165191, 502090288894909096, 263235, 915946001615943445, 414069474557, 502089874825434539);
        check_swap(975822276763920257, 195424786990176166, 455545331692750845, 487772, 1171247063754096423, 116009137393, 455545215683613452);
        check_swap(248401643334521595, 106226666881645090, 1058401136565762671, 846565, 354628310216166685, 809998230665108388, 248402905900654283);
        check_swap(409404216014345664, 1032665727536093152, 850822248691153805, 681621, 1442069943550438816, 441418562999826496, 409403685691327309);
        check_swap(408547674035135996, 897419398059341980, 147815367591801863, 133702, 1305967072094477976, 3135182223884, 147812232409577979);
        check_swap(650397508181174828, 1138819372412337718, 611204882337691490, 519166, 1789216880593512546, 18392645697022, 611186489691994468);
        check_swap(1012084088309524487, 560408506682870496, 598970391054740482, 181778, 1572492594992394983, 1649611092181, 598968741443648301);
        check_swap(555714314551457060, 681040161336538807, 281508534132116528, 213223, 1236754475887995867, 1541617386520, 281506992514730008);
        check_swap(632902016670606540, 574890573411324, 735329915907690487, 545156, 633476907244017864, 102213333295676805, 633116582612013682);
        check_swap(412947432097979953, 792340348214487846, 626121803018603204, 950708, 1205287780312467799, 213175074988620680, 412946728029982524);
        check_swap(30304231622935395, 663318214044119403, 690921937811003534, 10749, 693622445667054798, 660617717442200442, 30304220368803092);
        check_swap(276464313558551776, 179686172241203012, 344584754862146594, 372898, 456150485799754788, 68121215677599377, 276463539184547217);
        check_swap(324293997821620506, 997190182569197430, 325755412138804185, 119846, 1321484180390817936, 2261909335049599, 323493502803754586);
        check_swap(294714580237718891, 353772237852289330, 84583339444659168, 821662, 648486818090008221, 94037934927, 84583245406724241);
        check_swap(1122310997790777774, 243888194846967981, 1000594684990774942, 992988, 1366199192637745755, 1459018645859, 1000593225972129083);
        check_swap(43726157897559399, 499297062976726649, 524190468618211110, 872384, 543023220874286048, 480464312573231423, 43726156044979687);
        check_swap(583550919210660873, 644029021830648477, 699322965591182638, 844075, 1227579941041309350, 115773775305866410, 583549190285316228);
        check_swap(111129258284212047, 457340685946215739, 406632015603846917, 883586, 568469944230427786, 295502809843747174, 111129205760099743);
        check_swap(847148482574514827, 211668192330028706, 1077893696072931769, 732004, 1058816674904543533, 230745107327720199, 847148588745211570);
        check_swap(147626270855836004, 991671925743002392, 683364044385281570, 342725, 1139298196598838396, 535738052456249319, 147625991929032251);
        check_swap(50364893804203917, 851045066982969626, 833937999829648500, 909736, 901409960787173543, 783573110481430369, 50364889348218131);
        check_swap(1110254547936330029, 1063246709771003500, 692416067505653752, 572349, 2173501257707333529, 1301370583589, 692414766135070163);
        check_swap(793535410694449953, 892891817062965893, 82794605513649120, 7089, 1686427227757415846, 13653044522976, 82780952469126144);
        check_swap(161642671058452402, 192892475171932743, 1009174954186148725, 245296, 354535146230385145, 847530681862038926, 161644272324109799);
        check_swap(338778772401265723, 606246164816071656, 647590435345726707, 509883, 945024937217337379, 308812087936819215, 338778347408907492);
        check_swap(1094334912574012510, 1065319913842954761, 1225560560999073, 370290, 2159654826416967271, 173281614008, 1225387279385065);
        check_swap(32590458087496889, 950016941491412141, 1021257192067900829, 517519, 982607399578909030, 988666731507739706, 32590460560161123);
        check_swap(253790430790935934, 789959294614584929, 716756456823439408, 772677, 1043749725405520863, 462966193873159716, 253790262950279692);
        check_swap(812760227455612428, 455813556045997860, 132437007468134487, 320746, 1268573783501610288, 91918518603, 132436915549615884);
        check_swap(480391804491327794, 356141086665046684, 236490222786726778, 331350, 836532891156374478, 384836935237, 236489837949791541);
        check_swap(37125679898986388, 664338666567052664, 850719898597104618, 319284, 701464346466039052, 813594195307852852, 37125703289251766);
        check_swap(1041154652636118180, 214883091030702522, 460213902001155303, 556346, 1256037743666820702, 94738883162, 460213807262272141);
        check_swap(290273652515204254, 458846896529456129, 262879943529874466, 355843, 749120549044660383, 6433512145017, 262873510017729449);
        check_swap(1124460983567410579, 1151978028084313871, 1152834824347256435, 119312, 2276439011651724450, 28561468048823461, 1124273356298432974);
        check_swap(585029642946245561, 49657570037641847, 529983732106254557, 484335, 634687212983887408, 1438559911473, 529982293546343084);
        check_swap(15016944018856445, 806730688486911048, 454552419531734944, 723714, 821747632505767493, 439535489941119200, 15016929590615744);
        check_swap(620325399404471491, 504177579731677684, 257877235247748409, 266470, 1124502979136149175, 509343774310, 257876725903974099);
        check_swap(1064852217281178814, 839508684362810315, 459021180345346856, 276069, 1904360901643989129, 859299860038, 459020321045486818);
        check_swap(1113888212194295655, 1081338201060475360, 11362030476069336, 946932, 2195226413254771015, 71154851920, 11361959321217416);
        check_swap(231456164815669415, 627320573120396531, 1065133861745049976, 623426, 858776737936065946, 833677599880324118, 231456261864725858);
        check_swap(112192322615000799, 1069546142898035727, 142925967603833646, 650472, 1181738465513036526, 30740833124260941, 112185134479572705);
        check_swap(248617797659190194, 114080682564353293, 487884821389303712, 812079, 362698480223543487, 239266807380312100, 248618014008991612);
        check_swap(440368825602124802, 511556899824100360, 271757337995290096, 210418, 951925725426225162, 1778831333194, 271755559163956902);
        check_swap(818858739639580248, 973218085229994851, 804256133548089340, 807891, 1792076824869575099, 33125555161753, 804223007992927587);
        check_swap(1147592546842392220, 260197728074150276, 936900605325885619, 10058, 1407790274916542496, 71819667131147, 936828785658754472);
        check_swap(1125673675693913171, 255475877190865238, 639691695067367069, 375277, 1381149552884778409, 355965737708, 639691339101629361);
        check_swap(457259388786797288, 356225823106128963, 515030700970233460, 477483, 813485211892926251, 57774052387188684, 457256648583044776);
        check_swap(834492929128167035, 1120717286494530066, 1056395225628541810, 813501, 1955210215622697101, 221904611775484222, 834490613853057588);
        check_swap(743239032946697139, 555147992789504701, 518753715378476844, 641105, 1298387025736201840, 828474439751, 518752886904037093);
        check_swap(577771198782354562, 80123864819841741, 505775019055088894, 9161, 657895063602196303, 57827312898324, 505717191742190570);
        check_swap(1089400269015906861, 199691056780813906, 995089022548207221, 247383, 1289091325796720767, 7087649087279, 995081934899119942);
        check_swap(322909875212487334, 170382712548535881, 456069630830447745, 374106, 493292587761023215, 133159949051978538, 322909681778469207);
        check_swap(915674806169317201, 139075405422766506, 819191650288455565, 420718, 1054750211592083707, 2568940275408, 819189081348180157);
        check_swap(1049721970297735093, 178644043088599627, 458863463946466648, 514230, 1228366013386334720, 86775334619, 458863377171132029);
        check_swap(11540598189468425, 729947561787653319, 620215951243350509, 180490, 741488159977121744, 608675364729458444, 11540586513892065);
        check_swap(128035080618282823, 820069034531041023, 100600988073756822, 392468, 948104115149323846, 9551458263660, 100591436615493162);
        check_swap(510076888556465087, 1086619674008018813, 539713319485203246, 270724, 1596696562564483900, 29674962107024723, 510038357378178523);
        check_swap(94879478477316070, 318139838298083462, 877873459320450960, 927913, 413019316775399532, 782993868299634625, 94879591020816335);
        check_swap(952677194085464699, 257827903478061200, 67998319929637689, 250117, 1210505097563525899, 16142500048, 67998303787137641);
        check_swap(1008342944081487595, 980343217002047189, 479001552393866721, 320867, 1988686161083534784, 1150146705220, 479000402247161501);
        check_swap(872392844657348249, 538198514644116679, 270064905290777421, 951007, 1410591359301464928, 81686512716, 270064823604264705);
        check_swap(1042803167466166067, 579383232724516681, 568224301823934041, 270510, 1622186400190682748, 907183075958, 568223394640858083);
        check_swap(981930677298651845, 953024560120399772, 321672040333417289, 898666, 1934955237419051617, 225499804138, 321671814833613151);
        check_swap(603441090681655604, 983163495542503805, 602964172251554565, 799913, 1586604586224159409, 431933874814035, 602532238376740530);
        check_swap(914933844368196484, 826938396896764358, 828019784529054550, 868683, 1741872241264960842, 4308014364860, 828015476514689690);
        check_swap(225912317151653827, 1060490736294986401, 854896169751127804, 321881, 1286403053446640228, 628984215236956143, 225911954514171661);
        check_swap(135476168355328161, 96525119786691836, 311707475462573691, 567734, 232001288142019997, 176231175620882218, 135476299841691473);
        check_swap(995478747326632206, 208224504906240344, 332810922825681886, 217810, 1203703252232872550, 113944375082, 332810808881306804);
        check_swap(919155354198566398, 1004652269017090036, 455980485996836415, 965103, 1923807623215656434, 452951252024, 455980033045584391);
        check_swap(76150819192532447, 561664282245509561, 416183689914132905, 334183, 637815101438042008, 340032987151870134, 76150702762262771);
        check_swap(253662268796951957, 264820873331229045, 1149313778984110818, 753238, 518483142128181002, 895650978870835312, 253662800113275506);
        check_swap(835237407019752746, 816509222869539230, 21753250786669151, 812469, 1651746629889291976, 67443619749, 21753183343049402);
        check_swap(759490058530958272, 409699010832942251, 1019750147131317403, 69884, 1169189069363900523, 260264752427888365, 759485394703429038);
        check_swap(712151497928788287, 387266716897431966, 1144073852346540959, 862400, 1099418214826220253, 431922275743771723, 712151576602769236);
        check_swap(838724585104533122, 56453945946069240, 603663429162680422, 247864, 895178531050602362, 689373547111, 603662739789133311);
        check_swap(585871997948243976, 672809438601638881, 298130564975483529, 393309, 1258681436549882857, 803214227584, 298129761761255945);
        check_swap(324680760358529014, 867957110359003728, 455315577625369475, 668228, 1192637870717532742, 130636502498633531, 324679075126735944);
        check_swap(821373760751764794, 685258439641769831, 699287246233994807, 377124, 1506632200393534625, 4782436704228, 699282463797290579);
        check_swap(552965760535441095, 997245104942825787, 537470056792136607, 685702, 1550210865478266882, 27381336658230, 537442675455478377);
        check_swap(114775434728248156, 1054931086870003132, 147413576924285516, 275230, 1169706521598251288, 32653733538882159, 114759843385403357);
        check_swap(661711876668404812, 676435452705377749, 424458505901995504, 285302, 1338147329373782561, 1841272706592, 424456664629288912);
        check_swap(539785713216572330, 993180489388244513, 460554054967164461, 136923, 1532966202604816843, 23083240069014, 460530971727095447);
        check_swap(832401019593151649, 739782967119353553, 104227043461712185, 91419, 1572183986712505202, 718061592878, 104226325400119307);
        check_swap(682787113226114265, 1005582538470085721, 281628315244747422, 329764, 1688369651696199986, 1193621669671, 281627121623077751);
        check_swap(1128533297671669592, 745345263680944533, 913216598567774213, 774032, 1873878561352614125, 1826085427225, 913214772482346988);
        check_swap(146853591980657693, 161893326246901333, 335363634691638048, 152587, 308746918227559026, 188509918119734427, 146853716571903621);
        check_swap(862975670856182548, 549610613990625546, 295960814498767259, 249491, 1412586284846808094, 378176581391, 295960436322185868);
        check_swap(117046607125438564, 571468252731894919, 256185100704555740, 81921, 688514859857333483, 139141614609805307, 117043486094750433);
        check_swap(809899890517599682, 853978696826755344, 369450874606463111, 738546, 1663878587344355026, 422912534298, 369450451693928813);
        check_swap(1022246868113196543, 144176417296363527, 724246152961191616, 508239, 1166423285409560070, 463401983717, 724245689559207899);
        check_swap(159502680518288424, 371401389645562035, 133368304937954166, 476423, 530904070163850459, 2431738161678, 133365873199792488);
        check_swap(466533892057890829, 303225282552181961, 1151895877128538965, 728642, 769759174610072790, 685361473694324697, 466534403434214268);
        check_swap(506406255901216314, 390639928856174296, 425922448386557270, 291833, 897046184757390610, 3229947020470, 425919218439536800);
        check_swap(1150370878011095037, 422975093647301357, 1074928597162213737, 507143, 1573345971658396394, 6978165275579, 1074921618996938158);
        check_swap(150504378413872113, 92590269639858415, 760002726544702461, 105947, 243094648053730528, 609492892218173481, 150509834326528980);
        check_swap(497488589784046097, 1007611532109147046, 729102328644506607, 565067, 1505100121893193143, 231615485570850768, 497486843073655839);
        check_swap(1094108089747857052, 705696263741311188, 578533322700125658, 865109, 1799804353489168240, 329798994537, 578532992901131121);
        check_swap(56401986984211658, 512116477139548382, 160936404117235944, 917577, 568518464123760040, 104534612070093887, 56401792047142057);
        check_swap(1122350871612636044, 164484929696983631, 874019750414397593, 64985, 1286835801309619675, 6740951606823, 874013009462790770);
        check_swap(972814275150123156, 491805415966999342, 704320945414744419, 975717, 1464619691117122498, 557515581965, 704320387899162454);
        check_swap(1080241543257274156, 899732469952649354, 1102456986825399552, 855303, 1979974013209923510, 22240898502939076, 1080216088322460476);
        check_swap(897961668535160631, 659598308522826235, 824163442310658420, 639154, 1557559977057986866, 5557336348757, 824157884974309663);
        check_swap(494995972547831862, 290503865252682464, 79078865429696039, 651477, 785499837800514326, 29647774173, 79078835781921866);
        check_swap(847706080508710357, 592517314147744810, 1005616513455330844, 909051, 1440223394656455167, 157911958832758781, 847704554622572063);
        check_swap(78776956774598206, 9979445292167302, 471877314155484739, 190920, 88756402066765508, 393086902869827448, 78790411285657291);
        check_swap(467025774781127547, 140014601325592692, 367042588410841812, 909311, 607040376106720239, 295271054550, 367042293139787262);
        check_swap(763672373398656663, 519517684240717961, 145457840922333159, 261768, 1283190057639374624, 177001792314, 145457663920540845);
        check_swap(913076782138120820, 514460218230474885, 784232944056966925, 845447, 1427537000368595705, 1760692788516, 784231183364178409);
        check_swap(468397713877942093, 199598901314198785, 811909676389763612, 810880, 667996615192140878, 343511673314825719, 468398003074937893);
        check_swap(586001621297679565, 975493289297609697, 927617206680808707, 442484, 1561494910595289262, 341617083800420434, 586000122880388273);
        check_swap(769560275683073069, 1070765639077761412, 1106867746387153898, 257836, 1840325914760834481, 337311311467022826, 769556434920131072);
        check_swap(123089650707295007, 105656639089701604, 671198972342129015, 518935, 228746289796996611, 548108629907571447, 123090342434557568);
        check_swap(48129369214987052, 4883459610937076, 555528458347492154, 160412, 53012828825924128, 507353645545240587, 48174812802251567);
        check_swap(949877275458729246, 905509050788233510, 1152102224399448622, 339668, 1855386326246962756, 202230420012297659, 949871804387150963);
        check_swap(755922012395726820, 611091087848341921, 5492303428237754, 324475, 1367013100244068741, 88013862991, 5492215414374763);
        check_swap(1092367087631898595, 540479949894326984, 769640673711748168, 720102, 1632847037526225579, 740742977064, 769639932968771104);
        check_swap(138479346783689896, 887225324652905741, 830039959684612781, 298309, 1025704671436595637, 691560722970157477, 138479236714455304);
        check_swap(898243865739454384, 945109760205600827, 59695753642051033, 850965, 1843353625945055211, 96405902248, 59695657236148785);
        check_swap(370207550324636128, 703445767510207636, 375399630606304508, 921087, 1073653317834843764, 5221829840112920, 370177800766191588);
        check_swap(612628909543525403, 999605219462342864, 84582414766548453, 623800, 1612234129005868267, 299966254729, 84582114800293724);
        check_swap(697598866830911568, 793033339225930478, 590307235234508953, 791780, 1490632206056842046, 2613017228534, 590304622217280419);
        check_swap(942184392154098859, 865749494847890675, 960437883513834973, 242265, 1807933887001989534, 18344459736437597, 942093423777397376);
        check_swap(561201319771940360, 373049256717149099, 917645182712233974, 189104, 934250576489089459, 356443979124219356, 561201203588014618);
        check_swap(493007885411280951, 463578829092111061, 907178994425009621, 410907, 956586714503392012, 414171223558262140, 493007770866747481);
        check_swap(557382762020442629, 618409389564006149, 194510156845494140, 93520, 1175792151584448778, 1682874439023, 194508473971055117);
        check_swap(260857320801349955, 916061656706178964, 303094064148697559, 860269, 1176918977507528919, 42241091320925855, 260852972827771704);
        check_swap(111695150864909967, 80924832568379776, 693320551626571150, 742251, 192619983433289743, 581624705345270289, 111695846281300861);
        check_swap(200652827227421168, 656263731039317827, 962383020692617568, 757892, 856916558266738995, 761730157560447882, 200652863132169686);
        check_swap(682105675088755590, 618310503328414557, 553235223971610509, 618675, 1300416178417170147, 1938562154371, 553233285409456138);
        check_swap(995426182646009563, 801046992508267313, 1016277584830663137, 816617, 1796473175154276876, 20874772540647825, 995402812290015312);
        check_swap(418450156471079105, 549045899971771391, 47762871831514395, 267381, 967496056442850496, 277087905351, 47762594743609044);
        check_swap(1133999242999275859, 89731449072447252, 586359508494235944, 755673, 1223730692071723111, 76279676941, 586359432214559003);
        check_swap(844235332944683188, 56407491515961325, 444542831659151548, 974650, 900642824460644513, 44788339786, 444542786870811762);
    }

    #[test]
    fun test_virtual_price_does_not_decrease_from_deposit() {
        check_virtual_price_does_not_decrease_from_deposit(794249, 274628076037248964, 127771412697406946, 21855182491769970, 32097373911537805, 618220455500532685);
        check_virtual_price_does_not_decrease_from_deposit(776779, 52524833178964459, 126708361475527496, 919015480762919163, 289797958154721700, 27174523993487366);
        check_virtual_price_does_not_decrease_from_deposit(753939, 164277867715284036, 269624150891001255, 1107659660247636206, 872719342758549796, 560130055843411495);
        check_virtual_price_does_not_decrease_from_deposit(293437, 81988559695463484, 151895456590450955, 480259484544214625, 223089441427407762, 105571270167113388);
        check_virtual_price_does_not_decrease_from_deposit(985561, 60793447792497670, 1481534926809831, 711565528824577741, 1009219011906029087, 987529468512134302);
        check_virtual_price_does_not_decrease_from_deposit(369952, 12462376553773429, 179765450194341165, 798633623547249373, 356349338158655945, 1117221117839336962);
        check_virtual_price_does_not_decrease_from_deposit(594704, 206307793067970660, 149001172892247084, 421820690983013248, 1082791462592340106, 1047534838668042267);
        check_virtual_price_does_not_decrease_from_deposit(498467, 80891457670589621, 265349172237620132, 414528410094549438, 379104041980714835, 442203005012818648);
        check_virtual_price_does_not_decrease_from_deposit(927960, 22036697356546210, 18750246700422937, 291001226191327128, 951700605544731769, 699471458185760256);
        check_virtual_price_does_not_decrease_from_deposit(941999, 32901228324057778, 261649642694251025, 197773381623430900, 507303206110566559, 522369020150431656);
        check_virtual_price_does_not_decrease_from_deposit(126474, 211002747670525377, 183409914092327319, 988200748282291185, 360786346527821485, 256985987894539465);
        check_virtual_price_does_not_decrease_from_deposit(121296, 6623148758269363, 272417234326243525, 812083608608129162, 462940627864243479, 546935315412751393);
        check_virtual_price_does_not_decrease_from_deposit(115658, 121674741235215761, 237632310638848807, 1065634437187512795, 564056025047107978, 896012459640517330);
        check_virtual_price_does_not_decrease_from_deposit(569185, 97039911482181623, 266908506456390191, 479716109641714962, 663824103551101482, 623164033449150666);
        check_virtual_price_does_not_decrease_from_deposit(717372, 254727512727813910, 87312376709827952, 513477894370098437, 683955435375100906, 119347184806425637);
        check_virtual_price_does_not_decrease_from_deposit(349212, 169517862679657369, 141782862877234966, 108025987735963632, 300895661567747767, 703808760789822518);
        check_virtual_price_does_not_decrease_from_deposit(923787, 188442348925860296, 248787007639831547, 1034037097187774742, 955905626824978404, 67300000329287917);
        check_virtual_price_does_not_decrease_from_deposit(30635, 121268823589424638, 63859483637117752, 44947672182315310, 1111133924196667961, 1071008055632801264);
        check_virtual_price_does_not_decrease_from_deposit(804495, 228254357461694183, 52648586563263074, 735650621932304593, 301130895991571204, 663500143422515264);
        check_virtual_price_does_not_decrease_from_deposit(699220, 36747649308954398, 208507414685786129, 377344411611433100, 524027506653449995, 584061005629540062);
        check_virtual_price_does_not_decrease_from_deposit(268140, 241168723749550794, 80284945981123662, 1104871069436197479, 793783239443931177, 145069499339023996);
        check_virtual_price_does_not_decrease_from_deposit(441041, 40633493209004340, 27818982656435547, 17793315508532333, 210531190680672996, 358083500836155360);
        check_virtual_price_does_not_decrease_from_deposit(207579, 146886651608747529, 119792805599621576, 1113894190171473057, 833543534513244331, 350804215274071006);
        check_virtual_price_does_not_decrease_from_deposit(153931, 196800000116812374, 251289192483591387, 688632208281352776, 67406783336881049, 332932208036763763);
        check_virtual_price_does_not_decrease_from_deposit(609112, 69728431270514859, 237477832201710476, 612083648950001426, 158916080027350798, 969269071058534884);
        check_virtual_price_does_not_decrease_from_deposit(909778, 247404993169047663, 28114879717967490, 1043920944457903888, 401345014886951946, 486205836539884104);
        check_virtual_price_does_not_decrease_from_deposit(441838, 123126461665314458, 85144999238030520, 384802311750918065, 709864950788739017, 547704533619381467);
        check_virtual_price_does_not_decrease_from_deposit(927144, 205340578199329481, 94872458728580337, 83131858774647264, 1078328260194504776, 916865292230308588);
        check_virtual_price_does_not_decrease_from_deposit(155622, 247704776956818465, 659922172879280, 37104010486131296, 71882967683123125, 1138822193077950292);
        check_virtual_price_does_not_decrease_from_deposit(100267, 223239718328015346, 267266829061705894, 240377945111999037, 842376334585961686, 748164674155391525);
        check_virtual_price_does_not_decrease_from_deposit(773917, 121345602024928608, 280966542191310845, 711927863459521906, 1075393429380279089, 166117053513819495);
        check_virtual_price_does_not_decrease_from_deposit(280549, 216073343974333919, 196645948970241911, 688340432290985357, 615401911695078073, 368340290711799918);
        check_virtual_price_does_not_decrease_from_deposit(190366, 236369055641979502, 243913242185697537, 493967909791909332, 755534204240869321, 446373775328096235);
        check_virtual_price_does_not_decrease_from_deposit(174835, 34425543010688702, 48205631265304023, 154371127327846306, 489145593673941021, 416322957830909231);
        check_virtual_price_does_not_decrease_from_deposit(250197, 261318888145056802, 143287125337508532, 285971919526850933, 16013449785843076, 90627025971426500);
        check_virtual_price_does_not_decrease_from_deposit(689466, 57954348732245004, 110724574948419581, 315796376019502352, 815576519309239016, 305862633042850137);
        check_virtual_price_does_not_decrease_from_deposit(579209, 128547666062713011, 8778414698202469, 843432964472568618, 156177615161093721, 571777478204094130);
        check_virtual_price_does_not_decrease_from_deposit(504350, 16284308775101633, 57650284541383839, 701718632567168183, 403267225653232862, 50052356649418828);
        check_virtual_price_does_not_decrease_from_deposit(644572, 257133410050528113, 240164556782197390, 83468104572641815, 369367466705034211, 21945583578030536);
        check_virtual_price_does_not_decrease_from_deposit(218241, 72627260969959087, 177148826219544236, 418872786300943149, 937066282416803563, 1019102501843097476);
        check_virtual_price_does_not_decrease_from_deposit(40940, 239385199530599732, 271396538384326867, 450160890165748414, 957143363927652504, 761370890580620941);
        check_virtual_price_does_not_decrease_from_deposit(493402, 168256472479194386, 117982126737685217, 19724768922716082, 1123757274102335564, 849563742993982610);
        check_virtual_price_does_not_decrease_from_deposit(62152, 218135190656760139, 259173470844330692, 677302306203665739, 25543914359429974, 233964775243664975);
        check_virtual_price_does_not_decrease_from_deposit(976580, 65978806818359745, 200821257193449795, 1103969504627028797, 877273919706963000, 555057422120979755);
        check_virtual_price_does_not_decrease_from_deposit(343833, 157910348056986612, 191957600113605702, 362350887640724146, 625685688245063247, 257339618185748748);
        check_virtual_price_does_not_decrease_from_deposit(187877, 197189901473316270, 149781238794265259, 580478326853425632, 881975682404213028, 266527604366108536);
        check_virtual_price_does_not_decrease_from_deposit(502396, 26931127680526662, 114212010926153839, 377628042674980584, 1028296657472306226, 553734986114779374);
        check_virtual_price_does_not_decrease_from_deposit(239318, 94240505963726267, 92199279302155764, 249497645817058386, 347155138463438437, 810662962063624121);
        check_virtual_price_does_not_decrease_from_deposit(490718, 281140697783987248, 88954391465651666, 1058365431469975413, 332205436265718079, 156868443725811806);
        check_virtual_price_does_not_decrease_from_deposit(972265, 236160957984754518, 74435671786429342, 780871568383930957, 330499904016618860, 448973601088088054);
        check_virtual_price_does_not_decrease_from_deposit(275788, 198862482773503837, 152928964105397491, 931995084298172752, 1118999946761323730, 527134755645099610);
        check_virtual_price_does_not_decrease_from_deposit(484437, 119254643861675499, 29273287387717431, 1063286123191261177, 281673122629738602, 1115858599260906703);
        check_virtual_price_does_not_decrease_from_deposit(776306, 96159951506274763, 264983344201382989, 167611119946995841, 960253364828623374, 587050757904918635);
        check_virtual_price_does_not_decrease_from_deposit(794637, 226086892874351080, 35275065571690949, 836815801282399534, 618261739697350473, 654416459364625477);
        check_virtual_price_does_not_decrease_from_deposit(484103, 250184454303632359, 178164123459587494, 323811793058828699, 206766725708412186, 643628311410929725);
        check_virtual_price_does_not_decrease_from_deposit(693327, 85705912590604319, 22963310530175144, 985153309693059724, 454174887733193151, 597548181932904669);
        check_virtual_price_does_not_decrease_from_deposit(450474, 138495516203141023, 246941055272515051, 718076192039993327, 629726648524748984, 1073724755998000945);
        check_virtual_price_does_not_decrease_from_deposit(483926, 178431657464369654, 160299891936893708, 722893259204219729, 732664998513378408, 605053506322335108);
        check_virtual_price_does_not_decrease_from_deposit(788465, 6228845198456045, 59093847643957930, 535616611506651166, 1126583689641713151, 231026924299207700);
        check_virtual_price_does_not_decrease_from_deposit(604651, 114797203626718717, 130783129704996158, 981123137584049588, 618001174094167985, 624288192768605858);
        check_virtual_price_does_not_decrease_from_deposit(140110, 191449353344647567, 134915416160680370, 875335714430460514, 804495327172128356, 1106897172898943190);
        check_virtual_price_does_not_decrease_from_deposit(874079, 154886935443527104, 267634099062144812, 381936823132151294, 1041375555301562346, 978304787064821902);
        check_virtual_price_does_not_decrease_from_deposit(764734, 134057207253171547, 174139310457257227, 1022650111998612240, 240979018556960487, 234546248329447698);
        check_virtual_price_does_not_decrease_from_deposit(616389, 217251496856371594, 83339756556762263, 835881407330141603, 14038637776407974, 370544642297949883);
        check_virtual_price_does_not_decrease_from_deposit(227533, 166957526882745642, 254714025575107398, 434127874032319473, 124489295332103668, 436628427927390770);
        check_virtual_price_does_not_decrease_from_deposit(846746, 163851830212659663, 269201386140194988, 657784863674442228, 727785915016350966, 599955712938139997);
        check_virtual_price_does_not_decrease_from_deposit(212894, 132009671551062190, 27058362625016586, 1148069955872059852, 647334133014183896, 815690128879643659);
        check_virtual_price_does_not_decrease_from_deposit(787009, 259056341037614694, 90827860620536735, 481716179102970890, 559329107516632828, 173032865817815490);
        check_virtual_price_does_not_decrease_from_deposit(641226, 93031542340653946, 73938268237477530, 598044397678637320, 92663788948355735, 833215523003860769);
        check_virtual_price_does_not_decrease_from_deposit(92804, 80402604830219515, 194185128015483358, 247612887245793856, 186003473795398291, 684960342896583704);
        check_virtual_price_does_not_decrease_from_deposit(888726, 10917840566577167, 48697300954460858, 685411659967675091, 1134122093251741096, 327063948345358460);
        check_virtual_price_does_not_decrease_from_deposit(671121, 54795213087458569, 245098378244234225, 253894802144826019, 664779973734006138, 363079801358542616);
        check_virtual_price_does_not_decrease_from_deposit(296837, 213814413303649198, 260306160374623660, 481726269982996733, 611575062381914476, 390506766680111467);
        check_virtual_price_does_not_decrease_from_deposit(706740, 204957366577598574, 10628016072084823, 17569176574657558, 528219333559388494, 282603121648508959);
        check_virtual_price_does_not_decrease_from_deposit(559239, 88527973110288894, 97962701226496341, 103113245747654884, 490934284537395114, 1082590324667617391);
        check_virtual_price_does_not_decrease_from_deposit(700136, 238386252284500926, 244910684234781154, 619945813688236840, 1085754999946030919, 132459689440282387);
        check_virtual_price_does_not_decrease_from_deposit(510794, 222463501627648150, 239470651152569002, 1010894874679004734, 777047797745434720, 1019793799324954171);
        check_virtual_price_does_not_decrease_from_deposit(680278, 66488719841385927, 23130305639875914, 832390006219400119, 653107993628618088, 485914012811362633);
        check_virtual_price_does_not_decrease_from_deposit(760691, 276067747301755191, 27612740738697893, 1015545581700913038, 839775533317483406, 738532130077607568);
        check_virtual_price_does_not_decrease_from_deposit(535515, 276063740932788011, 71443231822327867, 497915611180840408, 38810915621366636, 229551840533665955);
        check_virtual_price_does_not_decrease_from_deposit(986645, 85669295611470704, 52356321311460398, 397412686361508814, 157102984320787862, 286465408992040114);
        check_virtual_price_does_not_decrease_from_deposit(558543, 29137511145541872, 38120537435484492, 875959821236660041, 1062429523439218879, 817596369193613733);
        check_virtual_price_does_not_decrease_from_deposit(912413, 229411528879756353, 214078133378402700, 191464497874101802, 794720633278481162, 454169188842376428);
        check_virtual_price_does_not_decrease_from_deposit(288681, 147173581554864189, 124568223032506895, 971715117884272187, 803458915106352088, 34197065547488759);
        check_virtual_price_does_not_decrease_from_deposit(471932, 49289749732325618, 130716600647639975, 18468366376212801, 735503915047394491, 584701787393779546);
        check_virtual_price_does_not_decrease_from_deposit(622371, 27129932203071448, 124652537636370915, 496078729882122452, 433980827772980614, 723306849067603782);
        check_virtual_price_does_not_decrease_from_deposit(245649, 6939446818234071, 26437862883076815, 627063468828641134, 481566094775798500, 461254830564544449);
        check_virtual_price_does_not_decrease_from_deposit(407406, 206320359392340962, 185531253139912628, 782191704216509721, 102406845654718528, 67324474817138928);
        check_virtual_price_does_not_decrease_from_deposit(347248, 35881323361074101, 250210406902984431, 995105402677175705, 212951779712924761, 527697503076383691);
        check_virtual_price_does_not_decrease_from_deposit(331020, 277225896610571208, 205362029901715712, 480619339555606544, 500746163290326393, 163326299057213518);
        check_virtual_price_does_not_decrease_from_deposit(901028, 42821550990084905, 30476551499414183, 469389206685544030, 573724696177314474, 1147124408779429792);
        check_virtual_price_does_not_decrease_from_deposit(73764, 84731212825476345, 244489821145719626, 471750998056728282, 816395993502571017, 498411758440013707);
        check_virtual_price_does_not_decrease_from_deposit(946855, 142233336652631249, 259735720228752091, 876418605238487394, 855527620742334810, 510904772620815062);
        check_virtual_price_does_not_decrease_from_deposit(828548, 27782515361701010, 107613853383851796, 465108730347132734, 1064100091255259542, 1077861798980673830);
        check_virtual_price_does_not_decrease_from_deposit(989049, 210130971342746617, 24653987133119174, 205078776729563683, 779357529745831225, 70857990755483919);
        check_virtual_price_does_not_decrease_from_deposit(402061, 263738327685621473, 278929261330094646, 633251981875036132, 223723302791446927, 712974141191743946);
        check_virtual_price_does_not_decrease_from_deposit(318501, 6058782507120107, 198021399886918829, 774243575991928738, 963501457244199842, 910831298918369002);
        check_virtual_price_does_not_decrease_from_deposit(144421, 254105798566398692, 266633224233435347, 856922492287646880, 683498955519116216, 236869786174491208);
        check_virtual_price_does_not_decrease_from_deposit(707492, 18873845425777728, 172273014209983486, 506624028626614695, 84926875315956533, 739914190476909438);
        check_virtual_price_does_not_decrease_from_deposit(926673, 71025964812919147, 152574312726572509, 450938978744176493, 701018810816751043, 310060188193148267);
        check_virtual_price_does_not_decrease_from_deposit(727701, 194426918529272384, 48646114206198601, 76379956969656056, 612046278623866496, 695543875338969557);
        check_virtual_price_does_not_decrease_from_deposit(904826, 195451599969806667, 49015241251676348, 402335553061083263, 915622245357457984, 785187874606182577);
        check_virtual_price_does_not_decrease_from_deposit(73574, 8890646182568798, 228369835630569918, 905206514244453916, 622681436013947058, 21942224868652539);
        check_virtual_price_does_not_decrease_from_deposit(909891, 37239423668434411, 76591095409981720, 650965646487264164, 825389578982923399, 603193094186106307);
        check_virtual_price_does_not_decrease_from_deposit(68148, 87785326479909807, 18727786856939006, 364593228778046151, 939590476257003614, 599063950854246102);
        check_virtual_price_does_not_decrease_from_deposit(306052, 21571685407715900, 186191536318773060, 902462353685730703, 675976836185424365, 212619400399030617);
        check_virtual_price_does_not_decrease_from_deposit(624858, 133502726597162301, 37550790143777117, 753437181709630514, 897096011048449857, 405397890701692865);
        check_virtual_price_does_not_decrease_from_deposit(239863, 750779528173742, 256935981666756320, 58258180541248675, 23254438094427717, 422631535239669816);
        check_virtual_price_does_not_decrease_from_deposit(326534, 255082485468833651, 249949043569866459, 360583511953450753, 117107445777175164, 926283514143901011);
        check_virtual_price_does_not_decrease_from_deposit(63311, 223766145814516693, 110071946831594379, 929710310663022036, 771541973282803840, 854910900192803079);
        check_virtual_price_does_not_decrease_from_deposit(287447, 214091145681226764, 250935868470878083, 430130014379973259, 962273468919719378, 919355158469365917);
        check_virtual_price_does_not_decrease_from_deposit(243062, 10680500877812706, 78205131150725109, 29547508190327003, 455443038718143960, 361002591063270593);
        check_virtual_price_does_not_decrease_from_deposit(815190, 181868598039063112, 203340046337660012, 424010008357357729, 948880769240136225, 428098015814078230);
        check_virtual_price_does_not_decrease_from_deposit(39635, 253124620647988637, 137411349684111855, 959771759817934073, 295578233923499509, 1143574246396167513);
        check_virtual_price_does_not_decrease_from_deposit(27323, 214437938920449061, 156478205813640449, 315460377349701507, 701761106913495557, 548110451774105753);
        check_virtual_price_does_not_decrease_from_deposit(423130, 273660106984081006, 138219912282924704, 610559967234747075, 386167996061409931, 137364425813783007);
        check_virtual_price_does_not_decrease_from_deposit(403717, 261542029861462456, 261544749717457000, 883489395679741648, 570175873815945675, 318289741147031500);
        check_virtual_price_does_not_decrease_from_deposit(277402, 183558773035642788, 75254826952704828, 728765024608720880, 319269213866013045, 59544986504797064);
        check_virtual_price_does_not_decrease_from_deposit(61494, 285883141594625881, 272631071271567006, 931550613454058700, 318675979914216788, 718791623333420448);
        check_virtual_price_does_not_decrease_from_deposit(590719, 189583709039552872, 11867437760084852, 729376520116853502, 764604764655762138, 477159503057224547);
        check_virtual_price_does_not_decrease_from_deposit(591362, 152390152683940205, 205683386502210513, 1058217239240218536, 946333987695266535, 376125328413153337);
        check_virtual_price_does_not_decrease_from_deposit(992428, 48962129461296144, 141551172091879205, 345919646160335783, 405582209765322337, 344294067244597321);
        check_virtual_price_does_not_decrease_from_deposit(544771, 248260601156907999, 72123291470433130, 1060539163066502448, 321529558147809595, 60931219123330891);
        check_virtual_price_does_not_decrease_from_deposit(879367, 265766443179758189, 228601400554221961, 510254412910045016, 183342027074954331, 889280015721612945);
        check_virtual_price_does_not_decrease_from_deposit(650839, 210245758905044331, 43795025307031106, 348549030886739602, 47253510722724052, 583301443819197115);
        check_virtual_price_does_not_decrease_from_deposit(886427, 29767393800594957, 235409361944976500, 797648472065023873, 459673988035421738, 323294787288365278);
        check_virtual_price_does_not_decrease_from_deposit(261509, 57253863995197588, 208240727178387078, 725547019644145821, 816601252184191307, 160632134237012176);
        check_virtual_price_does_not_decrease_from_deposit(613218, 240035837704355281, 214204048193127268, 821509262606475443, 303055579063251739, 461972923052863180);
        check_virtual_price_does_not_decrease_from_deposit(829235, 118095067977456304, 67358852966128003, 424839281356585895, 1002499943292036393, 209438860143861951);
        check_virtual_price_does_not_decrease_from_deposit(104372, 84444870964282460, 272214831448165591, 423168247227890125, 98353827960907499, 1127472670142754047);
        check_virtual_price_does_not_decrease_from_deposit(396844, 135147070895834325, 250256430425231637, 871951903880497190, 366073812892906860, 730356949516887130);
        check_virtual_price_does_not_decrease_from_deposit(887284, 240855752787145580, 205058524641994516, 279215959063928916, 1066652790315710493, 709205051699053620);
        check_virtual_price_does_not_decrease_from_deposit(837815, 120142233906153929, 17859359840268361, 199388097176599710, 257261320006782219, 971130226249086768);
        check_virtual_price_does_not_decrease_from_deposit(850005, 66844848550795339, 188701204154061553, 768057739682817446, 832615933316645956, 661270941616506398);
        check_virtual_price_does_not_decrease_from_deposit(82925, 21308610680916080, 263690621534867865, 720862954290123868, 493293605123972134, 699076566211224582);
        check_virtual_price_does_not_decrease_from_deposit(579076, 37614386894293944, 135826610882061614, 368365846852894181, 843858137680783200, 392353719923928215);
        check_virtual_price_does_not_decrease_from_deposit(576181, 214398578543716054, 166834628042109815, 1133995373441942132, 1052274359439112367, 446293422450369706);
        check_virtual_price_does_not_decrease_from_deposit(668030, 38499503527772119, 63020903310576048, 908833467115247202, 567300898200744545, 942722853750129450);
        check_virtual_price_does_not_decrease_from_deposit(299637, 91730160408153112, 62655724102149800, 433171146489399194, 1050422089755357013, 1008986723030551658);
        check_virtual_price_does_not_decrease_from_deposit(841058, 202156632443609183, 238206006965008571, 1096436906418120861, 572119475487165108, 858216298850450822);
        check_virtual_price_does_not_decrease_from_deposit(508114, 218170614662920277, 10884857515247814, 702356619062989236, 732568345802405141, 689235447798159900);
        check_virtual_price_does_not_decrease_from_deposit(324685, 121554777285151433, 30934830241906045, 1139990784588549052, 401194024850461059, 280450170660468839);
        check_virtual_price_does_not_decrease_from_deposit(570150, 124339634778218878, 57571588755754699, 175371496128816382, 27551962639872782, 530069045307703836);
        check_virtual_price_does_not_decrease_from_deposit(205246, 230338205775815209, 204212594674924958, 305188295850850788, 431354661469081210, 1011873717147682660);
        check_virtual_price_does_not_decrease_from_deposit(351932, 8662315088534137, 77711353958469405, 603372003523738324, 1085790244672425274, 538204851031989337);
        check_virtual_price_does_not_decrease_from_deposit(994349, 186080159725051797, 192314873332818575, 79271687704255239, 422736587467304991, 663308695397444079);
        check_virtual_price_does_not_decrease_from_deposit(471794, 143222567878993265, 242687506371086525, 1063355314089634033, 459688493555510720, 169187209337266508);
        check_virtual_price_does_not_decrease_from_deposit(702457, 127938943223017910, 173864582256113290, 454934391482267306, 126392078972419209, 1017654078179946647);
        check_virtual_price_does_not_decrease_from_deposit(992116, 107846335082484846, 195333809566492085, 502048829208818587, 855182731607884653, 1040570938815947588);
        check_virtual_price_does_not_decrease_from_deposit(183030, 164524054101500697, 201993186027463877, 633254731446983107, 426138922186732407, 29374251798072644);
        check_virtual_price_does_not_decrease_from_deposit(523252, 125275134394947899, 230594395323028192, 704765264926504034, 346307096003926424, 561983511421238704);
        check_virtual_price_does_not_decrease_from_deposit(106738, 209309244396776311, 237968817463038748, 23175512715929509, 592280118924143472, 184359128805689207);
        check_virtual_price_does_not_decrease_from_deposit(904925, 266287104820430815, 40253639508638761, 512292242242587411, 274323856894632310, 644557870123347902);
        check_virtual_price_does_not_decrease_from_deposit(666546, 40165015742320710, 211056548596093786, 189938599985411047, 116252722287830841, 1068458909436170504);
        check_virtual_price_does_not_decrease_from_deposit(101177, 185795230401507222, 136415419924410038, 112095927194877370, 853743039676432103, 106591432494566888);
        check_virtual_price_does_not_decrease_from_deposit(533966, 133855081910194450, 203315576725011582, 531223611803328309, 214341317517443385, 979821325577388525);
        check_virtual_price_does_not_decrease_from_deposit(13795, 117927361335820993, 272981193141938581, 304960239379944376, 44388113503408873, 1054734527041877049);
        check_virtual_price_does_not_decrease_from_deposit(736830, 204912277883525237, 136893468786545608, 863525820204319096, 434561340734210, 1084225411942556231);
        check_virtual_price_does_not_decrease_from_deposit(582103, 112032688928453297, 186084062615034304, 367188412950918775, 884831385660292388, 778796885044072695);
        check_virtual_price_does_not_decrease_from_deposit(998268, 16927301423168845, 215614683370767818, 873359025875266857, 118743551384392344, 1037731427319348154);
        check_virtual_price_does_not_decrease_from_deposit(353848, 279767802368617230, 274671957767336924, 789621496997477271, 47506151018019190, 993975369553367926);
        check_virtual_price_does_not_decrease_from_deposit(968034, 188067281974995629, 230784154913131733, 31415714726650222, 516182168115986678, 717915386437655650);
        check_virtual_price_does_not_decrease_from_deposit(112647, 273563078917547131, 144135910916546669, 3105429621259694, 220780776933578428, 365923882904668920);
        check_virtual_price_does_not_decrease_from_deposit(296487, 148118096877646869, 148872593914084247, 1022578575698244394, 914424638145481074, 441381987858476631);
        check_virtual_price_does_not_decrease_from_deposit(886614, 133744992088174078, 109096734049544744, 734263652518083227, 892580053845582390, 103400506219585524);
        check_virtual_price_does_not_decrease_from_deposit(659213, 126647048168012973, 278115786109355877, 501446564542588909, 118086542735321461, 7008764589420013);
        check_virtual_price_does_not_decrease_from_deposit(755786, 269360377087209179, 26552672044842210, 609428581780815766, 1028349484395157835, 1096090147954372667);
        check_virtual_price_does_not_decrease_from_deposit(356129, 203535374092585009, 197267913656828462, 317577700916310391, 1119519301212086771, 181312186096960539);
        check_virtual_price_does_not_decrease_from_deposit(923409, 75498224102331314, 55207875263746451, 62027990088639231, 846859823431187779, 1012932689772142112);
        check_virtual_price_does_not_decrease_from_deposit(796572, 29915903889748418, 440723784728432, 124617275585892662, 965367990872815999, 217815401588299585);
        check_virtual_price_does_not_decrease_from_deposit(679735, 33836950352802006, 100981413182453083, 608684000932630001, 791209580078256097, 66323766200895319);
        check_virtual_price_does_not_decrease_from_deposit(194392, 171782111114070767, 40827599257513056, 154387839139048199, 218259771014210517, 816524456589519097);
        check_virtual_price_does_not_decrease_from_deposit(973137, 61079567500557586, 70415415778311844, 705755662175865728, 262164360151035153, 86917896796897150);
        check_virtual_price_does_not_decrease_from_deposit(3632, 119784628769595687, 199495185074156069, 421882131508518111, 75468530159978177, 1028838897277972145);
        check_virtual_price_does_not_decrease_from_deposit(867247, 38494160724637637, 280030308984112364, 848702170991802352, 866028520601928863, 798342423100641667);
        check_virtual_price_does_not_decrease_from_deposit(995142, 95352969233547600, 241495019750817058, 96410281553117928, 850448064156102121, 923366361538789101);
        check_virtual_price_does_not_decrease_from_deposit(629103, 76019031988742611, 82317154823182807, 937234698035051143, 46351030018623638, 275458175919652599);
        check_virtual_price_does_not_decrease_from_deposit(68349, 221176565744813289, 88187639706662844, 112700200292400847, 318570242166890584, 820802198801476922);
        check_virtual_price_does_not_decrease_from_deposit(880291, 280244480552251858, 251239878600655427, 694449616169813549, 123475371309024922, 316882902293447820);
        check_virtual_price_does_not_decrease_from_deposit(867327, 199423696235278891, 52702834425437530, 695624033231644652, 674032729201924627, 958786866887750433);
        check_virtual_price_does_not_decrease_from_deposit(654718, 53708504705676244, 76492030153893320, 637797285287133399, 264764904327268372, 584557689349124526);
        check_virtual_price_does_not_decrease_from_deposit(890897, 104301324851058825, 46923385871467889, 528526368357056868, 411527076300151764, 343804574131192626);
        check_virtual_price_does_not_decrease_from_deposit(790695, 157687637539636140, 214056353350022597, 996984054553897075, 1101972962154411587, 417390435309629234);
        check_virtual_price_does_not_decrease_from_deposit(787461, 265356421701923119, 73852592695499934, 112917801371131943, 798922400690374614, 363280781565358352);
        check_virtual_price_does_not_decrease_from_deposit(332891, 62081887941632246, 142701910284268402, 845403373046249004, 803449377057222096, 951480810367885003);
        check_virtual_price_does_not_decrease_from_deposit(52875, 43733267283419871, 161976976969982679, 915711941639497183, 367402835307359221, 253328989571224681);
        check_virtual_price_does_not_decrease_from_deposit(9101, 6474664757196274, 271742901993166984, 783618002255661371, 965977698523446007, 1122780009240031940);
        check_virtual_price_does_not_decrease_from_deposit(898123, 30224124261513286, 146137600049209864, 132436262973591916, 775838859759326871, 849247971599596140);
        check_virtual_price_does_not_decrease_from_deposit(338180, 115945726237578852, 286410517994404004, 792389526125835431, 252920280847052592, 277313094064165800);
        check_virtual_price_does_not_decrease_from_deposit(293579, 274958832379937218, 50765835542467111, 267888388268993546, 1058720934395500315, 198231037634767541);
        check_virtual_price_does_not_decrease_from_deposit(406127, 125022021486936387, 36911401307809835, 702026284481527924, 450642580318904833, 225196847613304400);
        check_virtual_price_does_not_decrease_from_deposit(166247, 126568320769641230, 52001480641133062, 241042474362986065, 809049767172398211, 687369864197161726);
        check_virtual_price_does_not_decrease_from_deposit(646595, 48609679460763619, 274421689377752269, 120016400854346319, 23130788799004567, 920079609706349423);
        check_virtual_price_does_not_decrease_from_deposit(554527, 6607544482162589, 80673805401637435, 1092194721075186212, 764212840306852188, 709688872315869671);
        check_virtual_price_does_not_decrease_from_deposit(718426, 286614158469793279, 255211498924382908, 636823178514931388, 927349780333587175, 256599343519294533);
        check_virtual_price_does_not_decrease_from_deposit(924138, 220491200407553668, 136285457938569626, 1134475718801863975, 837350322213308371, 937495822236172110);
        check_virtual_price_does_not_decrease_from_deposit(651345, 123119382993509610, 198494292100964711, 428193274361980322, 919784296137045688, 300910597158672557);
        check_virtual_price_does_not_decrease_from_deposit(662940, 183628310997426892, 60903705976003173, 524163929953193878, 736643762060757613, 59718971195331613);
        check_virtual_price_does_not_decrease_from_deposit(28796, 263493196511633291, 66087008509494462, 718301897070245409, 705155230369666606, 825041680271695507);
        check_virtual_price_does_not_decrease_from_deposit(210791, 179488521553425295, 196532304084687397, 947346438893383738, 636655912041375930, 682532820301096543);
        check_virtual_price_does_not_decrease_from_deposit(773074, 56790070921566940, 43153135588072882, 212113039264472573, 513456722794013188, 712357353917723697);
        check_virtual_price_does_not_decrease_from_deposit(580063, 254063603956925735, 272002738031856946, 33147534254334172, 274324686260756481, 498288320870134051);
        check_virtual_price_does_not_decrease_from_deposit(768428, 117724622317608799, 48505827242722576, 692853607148563869, 709128119550561405, 214369753653066224);
        check_virtual_price_does_not_decrease_from_deposit(83530, 240504059639754645, 13435839385304458, 710180686549123049, 969143375631052479, 977214810659022313);
        check_virtual_price_does_not_decrease_from_deposit(909276, 44496350502874300, 93077225017965667, 469251811369906830, 681424453897215679, 8099549391296559);
        check_virtual_price_does_not_decrease_from_deposit(348064, 211866394316747860, 102901802537778146, 1001206047535120596, 33922578586526181, 306611171470400935);
        check_virtual_price_does_not_decrease_from_deposit(999429, 153330208286635115, 248218840667579219, 331097471352029408, 842529389291073037, 561782145576794525);
        check_virtual_price_does_not_decrease_from_deposit(328276, 177588879583125521, 47131710297959817, 322589198324194629, 407346018557728954, 361726368382237049);
        check_virtual_price_does_not_decrease_from_deposit(999635, 266343405511242346, 127416708790661011, 1041568063655942250, 642392505843237932, 973791771834920069);
        check_virtual_price_does_not_decrease_from_deposit(874400, 205971646411948616, 18284042878200616, 544356512411065683, 810870199516786132, 679416632732740671);
        check_virtual_price_does_not_decrease_from_deposit(570837, 24975900127152771, 187226074991202059, 530865336797793997, 684604439899998064, 846594117392917572);
        check_virtual_price_does_not_decrease_from_deposit(705883, 170675279016978778, 230715740056213992, 884063772175329980, 22763002502685549, 547136424273684439);
        check_virtual_price_does_not_decrease_from_deposit(261763, 70087039389530781, 197100373704804620, 767513437686950556, 28880221680672332, 328691976095603479);
        check_virtual_price_does_not_decrease_from_deposit(564520, 43730935981123312, 42696446925153375, 1035145478972406677, 190373890879898543, 787288378195094394);
        check_virtual_price_does_not_decrease_from_deposit(744080, 107580567877938942, 49908167955678551, 324636838680143642, 734473066166338418, 635769067308670282);
        check_virtual_price_does_not_decrease_from_deposit(573341, 116593643552703554, 106010574838559198, 948329383020296409, 947446634082401643, 786000391151068456);
        check_virtual_price_does_not_decrease_from_deposit(762508, 273181114384745338, 52633343364559401, 157631938790538449, 666685686185498660, 612812411982840882);
        check_virtual_price_does_not_decrease_from_deposit(776753, 113146720178472050, 146150851482905136, 809867341162435695, 373843603242102405, 610141285459148773);
        check_virtual_price_does_not_decrease_from_deposit(544600, 276044383930578428, 116784633304151546, 739908853556401451, 545188572619132310, 654107819373164633);
        check_virtual_price_does_not_decrease_from_deposit(830220, 102264170790849101, 19323406431466304, 274717155103281487, 551050928096737462, 735831406695810804);
        check_virtual_price_does_not_decrease_from_deposit(982616, 21793387568213831, 9944397102200452, 719729179291139862, 536899732398767009, 1014609751753471242);
        check_virtual_price_does_not_decrease_from_deposit(134185, 128283149635445263, 91844385349704809, 663597960478901640, 943031053999633977, 866439261944928506);
        check_virtual_price_does_not_decrease_from_deposit(666410, 29954038612475121, 265012848593611106, 1088845944065063126, 630844763413321595, 633749946340145694);
        check_virtual_price_does_not_decrease_from_deposit(68336, 255850825588931810, 115376313523743189, 167844324676201776, 681511503037723271, 54243114266636792);
        check_virtual_price_does_not_decrease_from_deposit(141760, 168588698692097778, 162987543967469553, 367650337064522489, 716106655536697070, 87217856441832847);
        check_virtual_price_does_not_decrease_from_deposit(463652, 44838557065305089, 37979033678108419, 222833524545762744, 984869983997524901, 78915146127712080);
        check_virtual_price_does_not_decrease_from_deposit(952225, 205552785903967300, 102530957710779745, 1026917749071461736, 282424960196435885, 867586857408920704);
        check_virtual_price_does_not_decrease_from_deposit(974829, 162798355978982402, 270584999120615357, 99675898731074387, 578226941666998240, 414168725161160379);
        check_virtual_price_does_not_decrease_from_deposit(537481, 207754560798094573, 241865586776132391, 574589835532995009, 885555993454374506, 762156437631585629);
        check_virtual_price_does_not_decrease_from_deposit(549679, 153962358770371591, 80483788117607263, 688849937461555363, 1022396689698189465, 759757901025936157);
        check_virtual_price_does_not_decrease_from_deposit(482107, 80071280314730526, 84017684892668880, 133351111840576893, 785370894391386749, 132064050638189450);
        check_virtual_price_does_not_decrease_from_deposit(990012, 130713963020199990, 147226591183198674, 615812989131899513, 1003430414735269000, 1102476296055884501);
        check_virtual_price_does_not_decrease_from_deposit(302467, 65639756174238202, 201357719805104642, 365619766125167, 502206442194105745, 317356774926470067);
        check_virtual_price_does_not_decrease_from_deposit(458557, 243568030029931, 51247917348862445, 532839239228908315, 1043382472763374574, 425539493506957746);
        check_virtual_price_does_not_decrease_from_deposit(770679, 57187031499380579, 31580242666035996, 409361146133569832, 1101022937676831230, 1040692085314627020);
        check_virtual_price_does_not_decrease_from_deposit(165992, 184520662278265414, 277196284395998498, 690651805695025695, 465225011051040509, 303249069688945632);
        check_virtual_price_does_not_decrease_from_deposit(814894, 78814627829878283, 190936952229859937, 186403853278023508, 641045457933481356, 736099683628482755);
        check_virtual_price_does_not_decrease_from_deposit(293519, 248723323757972521, 106366130125993158, 1042513104674038919, 966956966316808547, 618508294576550153);
        check_virtual_price_does_not_decrease_from_deposit(198022, 31706141940057053, 59520316950877408, 829765206784839608, 428062027517840642, 960970129136823933);
        check_virtual_price_does_not_decrease_from_deposit(806841, 287173520562350089, 262990926369631442, 1066151623302192692, 510134841831982641, 313689426479868642);
        check_virtual_price_does_not_decrease_from_deposit(347469, 141656371849762768, 171413534080800349, 704581382488342595, 801261231134074853, 568429501279816636);
        check_virtual_price_does_not_decrease_from_deposit(645365, 111334633291049489, 1736939672095198, 541304545305467408, 685564812385835027, 423661217269660079);
        check_virtual_price_does_not_decrease_from_deposit(951014, 195531199802650974, 286933147406539589, 1050525448690245095, 22166706423301160, 580626928961037078);
        check_virtual_price_does_not_decrease_from_deposit(400949, 118687774104070903, 122334651426325774, 495422529007465836, 1110393159947322163, 671157882706858319);
        check_virtual_price_does_not_decrease_from_deposit(775582, 236419940282484967, 45003248853207753, 715318546306863588, 1000343906962613982, 786296320862851086);
        check_virtual_price_does_not_decrease_from_deposit(349188, 62761784743439815, 261144398283271204, 801808719452916627, 1063871301569100873, 679949339087833061);
        check_virtual_price_does_not_decrease_from_deposit(245213, 6852936441148502, 155826291157141119, 117462933128552145, 1129163745394973537, 388604724755197394);
        check_virtual_price_does_not_decrease_from_deposit(940189, 114541430681715583, 218006110351513555, 842669622631160940, 696848131196277624, 488560614900284528);
        check_virtual_price_does_not_decrease_from_deposit(781893, 3844651808898668, 231085675131584894, 344264822202695002, 1096458070008893207, 30175506242761415);
        check_virtual_price_does_not_decrease_from_deposit(616745, 219624415438370753, 150163293944423254, 955815140709818589, 714829843964726876, 1078548464119500093);
        check_virtual_price_does_not_decrease_from_deposit(427357, 262385567979552083, 82437771213970111, 985141783208598936, 599003828150045838, 663081178279530137);
        check_virtual_price_does_not_decrease_from_deposit(395782, 165199134750052664, 248344303862828915, 222591493717699414, 162339578737499083, 1075555201785505627);
        check_virtual_price_does_not_decrease_from_deposit(889033, 206228867939716872, 117525467040029287, 172734050345766783, 138017861609542978, 912752593994501485);
        check_virtual_price_does_not_decrease_from_deposit(171590, 126728722731718919, 27538940055662886, 859133875305244941, 200078490111400999, 503472083852098721);
        check_virtual_price_does_not_decrease_from_deposit(671617, 94446274902513886, 11625335284597540, 928222767819894310, 182100297146777022, 424621147318628755);
        check_virtual_price_does_not_decrease_from_deposit(156137, 255989322077680060, 228328436188539758, 230891970055248667, 1003002680898851978, 292706830646566438);
    }

    #[test]
    fun test_virtual_price_does_not_decrease_from_swap() {
        check_virtual_price_does_not_decrease_from_swap(794249, 1098512304148995858, 511085650789627788, 21855182491769970);
        check_virtual_price_does_not_decrease_from_swap(806403, 536123195043622361, 671192917270841210, 391567458294850640);
        check_virtual_price_does_not_decrease_from_swap(385727, 241748810900250962, 180056213684760732, 173550941455775594);
        check_virtual_price_does_not_decrease_from_swap(956785, 230535880076851512, 843505350196129507, 739686348205533658);
        check_virtual_price_does_not_decrease_from_swap(977951, 117538455834326936, 692997258522897233, 897051574937324414);
        check_virtual_price_does_not_decrease_from_swap(786518, 725022688100319079, 983583127368639646, 677672340203266879);
        check_virtual_price_does_not_decrease_from_swap(857408, 1089960450711478471, 850597590271641021, 1110827412509877517);
        check_virtual_price_does_not_decrease_from_swap(149736, 682521618013529105, 881374017514727644, 961949146688473091);
        check_virtual_price_does_not_decrease_from_swap(463651, 370247574849776437, 705843037271518212, 219066408657467173);
        check_virtual_price_does_not_decrease_from_swap(950743, 406538994055116610, 353848374911925077, 1011838894827139093);
        check_virtual_price_does_not_decrease_from_swap(81121, 604157273032277192, 75587506978004800, 1051832143882902464);
        check_virtual_price_does_not_decrease_from_swap(800376, 248692087170618715, 1107026058114237564, 927596275808332659);
        check_virtual_price_does_not_decrease_from_swap(748812, 449923227083264031, 588631349705013613, 1108364970572244857);
        check_virtual_price_does_not_decrease_from_swap(834959, 234507525839270119, 1135743545894163286, 943095567295391792);
        check_virtual_price_does_not_decrease_from_swap(112887, 1086368657710732877, 449427336042412023, 667024691458921393);
        check_virtual_price_does_not_decrease_from_swap(563988, 110185262515089388, 849727875114490110, 875283808232391869);
        check_virtual_price_does_not_decrease_from_swap(434964, 346325005923284831, 439018540380138882, 1113057325065442876);
        check_virtual_price_does_not_decrease_from_swap(285783, 260778109154475471, 33187436479892111, 1095404420844935625);
        check_virtual_price_does_not_decrease_from_swap(548215, 298791989408143784, 317759015316477386, 751012994281783467);
        check_virtual_price_does_not_decrease_from_swap(920914, 157907980529213905, 204607178854758746, 934363984045659291);
        check_virtual_price_does_not_decrease_from_swap(196181, 642853096131420127, 384163245191815114, 143833170837068785);
        check_virtual_price_does_not_decrease_from_swap(386968, 1025628491763870267, 753982414274601169, 831114226415806905);
        check_virtual_price_does_not_decrease_from_swap(304338, 706316651324025739, 755882076158395855, 39757829234150782);
        check_virtual_price_does_not_decrease_from_swap(812784, 164789547560304921, 356621591633759361, 739682747369240785);
        check_virtual_price_does_not_decrease_from_swap(924604, 289499852530084365, 108703527216433957, 87946632931203271);
        check_virtual_price_does_not_decrease_from_swap(430006, 93599211336753077, 873252680017793395, 762568647008492016);
        check_virtual_price_does_not_decrease_from_swap(836976, 902888546967415032, 155154741790161110, 331792018634927329);
        check_virtual_price_does_not_decrease_from_swap(31522, 1068452518285257336, 457989487016312683, 974670142276067499);
        check_virtual_price_does_not_decrease_from_swap(584859, 986973174479974253, 781505579330466962, 863188707323442382);
        check_virtual_price_does_not_decrease_from_swap(437033, 1082609945930729427, 113782805808492713, 34678465942839197);
        check_virtual_price_does_not_decrease_from_swap(156784, 1142716651436190451, 441577472736856133, 220359331861764427);
        check_virtual_price_does_not_decrease_from_swap(219270, 1013342172466816967, 331149937866071752, 334382937926867770);
        check_virtual_price_does_not_decrease_from_swap(648098, 681824573334267621, 184930083118336406, 1093483368255752285);
        check_virtual_price_does_not_decrease_from_swap(426386, 945564820770394190, 91253735938527017, 1146498518469359180);
        check_virtual_price_does_not_decrease_from_swap(669711, 705812138413853772, 767906759912830605, 342359535974061951);
        check_virtual_price_does_not_decrease_from_swap(867630, 146357885217687153, 839772310308914882, 75384157911090169);
        check_virtual_price_does_not_decrease_from_swap(845808, 274007896329627990, 337007458228928261, 224648697295146279);
        check_virtual_price_does_not_decrease_from_swap(613250, 704701110504389138, 373378673710319026, 400613876642847382);
        check_virtual_price_does_not_decrease_from_swap(478811, 617986013006002566, 441510785792477200, 615621148656926781);
        check_virtual_price_does_not_decrease_from_swap(373430, 675880448498693571, 853269758001074788, 153781403670929321);
        check_virtual_price_does_not_decrease_from_swap(492294, 11950477103286214, 849274833196997334, 302897925506012694);
        check_virtual_price_does_not_decrease_from_swap(651437, 6270116416898554, 713095603097716329, 349457431057290955);
        check_virtual_price_does_not_decrease_from_swap(954565, 1116234931770445957, 709063986404521800, 1033229745295670919);
        check_virtual_price_does_not_decrease_from_swap(923119, 886982176397105705, 1083894842225225126, 278979572113822009);
        check_virtual_price_does_not_decrease_from_swap(208007, 597851591896192657, 560680573883343597, 521029389948705785);
        check_virtual_price_does_not_decrease_from_swap(350570, 651699852183193823, 1126090723609634734, 91023320515409018);
        check_virtual_price_does_not_decrease_from_swap(576371, 707485189285005186, 176140224881822523, 669347678465814540);
        check_virtual_price_does_not_decrease_from_swap(50516, 572983293943475363, 242114803676776925, 429269996412633555);
        check_virtual_price_does_not_decrease_from_swap(559538, 72829108021141512, 1045666158764293815, 689455907171341968);
        check_virtual_price_does_not_decrease_from_swap(378463, 525632352393034239, 664031600695278651, 1049650799920648689);
        check_virtual_price_does_not_decrease_from_swap(26739, 763833670924161476, 737030307141659290, 8857386474142737);
        check_virtual_price_does_not_decrease_from_swap(6789, 291177564797822085, 616308715177599210, 110342122721252894);
        check_virtual_price_does_not_decrease_from_swap(541260, 970645488778911133, 33984515850637810, 740340413195077277);
        check_virtual_price_does_not_decrease_from_swap(624959, 434977180851718026, 212949304548371823, 1093690306823967509);
        check_virtual_price_does_not_decrease_from_swap(548261, 47332058068525145, 57010373010227883, 1044607719073772838);
        check_virtual_price_does_not_decrease_from_swap(280638, 31311861813121705, 960207275870888195, 263257362393691825);
        check_virtual_price_does_not_decrease_from_swap(289987, 59577007117361022, 279425016976709840, 482292731644465764);
        check_virtual_price_does_not_decrease_from_swap(716154, 1084562207974261557, 101381971719228980, 540434805222585005);
        check_virtual_price_does_not_decrease_from_swap(745500, 719424879607996734, 102103849831228383, 148402261082004136);
        check_virtual_price_does_not_decrease_from_swap(250078, 973371537849519022, 620342250210612104, 1115487260175244538);
        check_virtual_price_does_not_decrease_from_swap(201146, 500886824853768979, 995955196381674704, 778539103267577026);
        check_virtual_price_does_not_decrease_from_swap(334836, 253214014343682428, 495210671042820252, 190005232595629173);
        check_virtual_price_does_not_decrease_from_swap(594345, 424528963594144132, 28704095065640415, 908645890034588705);
        check_virtual_price_does_not_decrease_from_swap(642585, 151226436524802111, 1145811021841482844, 841034573411980234);
        check_virtual_price_does_not_decrease_from_swap(966480, 326012781245625518, 71658249451072818, 165944075386172857);
        check_virtual_price_does_not_decrease_from_swap(996984, 391144874706417098, 326941492471156076, 904295541062112347);
        check_virtual_price_does_not_decrease_from_swap(719283, 1040489777364579885, 257932956520695206, 439899564275929479);
        check_virtual_price_does_not_decrease_from_swap(88379, 683497596358284232, 1100984794230265213, 1019960035359297345);
        check_virtual_price_does_not_decrease_from_swap(635899, 607781129031545479, 767542546862946841, 292293519187105422);
        check_virtual_price_does_not_decrease_from_swap(914047, 259841410046123207, 691030081416164636, 219994482863976517);
        check_virtual_price_does_not_decrease_from_swap(862938, 738483136652443167, 945715578250462510, 721482224318357268);
        check_virtual_price_does_not_decrease_from_swap(351856, 904096195893160390, 708823621152332134, 1051635628121961299);
        check_virtual_price_does_not_decrease_from_swap(268295, 741481867501412015, 90457343948569935, 265134196052255460);
        check_virtual_price_does_not_decrease_from_swap(60774, 66655655813379564, 275009043889672143, 67489499928317825);
        check_virtual_price_does_not_decrease_from_swap(594131, 542130684395588614, 1117829279877606297, 378646751205392376);
        check_virtual_price_does_not_decrease_from_swap(642505, 1068477359424199807, 667846079193274375, 668033442708724512);
        check_virtual_price_does_not_decrease_from_swap(495831, 837373323656701161, 913828637117058356, 182694775548863301);
        check_virtual_price_does_not_decrease_from_swap(164276, 19269929658697568, 851439046912418309, 785504323338669613);
        check_virtual_price_does_not_decrease_from_swap(215250, 54545482960808411, 788328879855217812, 6540079739949560);
        check_virtual_price_does_not_decrease_from_swap(340976, 478500104172655907, 392132316096077801, 827186898162252988);
        check_virtual_price_does_not_decrease_from_swap(926594, 895970142403749219, 343230843747647530, 505563583104553302);
        check_virtual_price_does_not_decrease_from_swap(391539, 570052482090920556, 280094929619024607, 909971640207140462);
        check_virtual_price_does_not_decrease_from_swap(63188, 782518169501407585, 697171866078472752, 66547165369230266);
        check_virtual_price_does_not_decrease_from_swap(124708, 1001774978081374722, 181034953397963485, 368168933492425469);
        check_virtual_price_does_not_decrease_from_swap(786713, 483367821612099182, 820258239407905001, 816707238898730802);
        check_virtual_price_does_not_decrease_from_swap(585563, 129984317901485871, 267180569254646282, 372300113297552243);
        check_virtual_price_does_not_decrease_from_swap(47772, 880130446755844771, 993529427946748672, 177036088712821326);
        check_virtual_price_does_not_decrease_from_swap(978512, 754774397582918389, 156043234436251858, 262925424741487614);
        check_virtual_price_does_not_decrease_from_swap(371957, 418495049748581826, 957182968430062612, 80191541419413681);
        check_virtual_price_does_not_decrease_from_swap(219034, 870907813023757979, 388793099760573828, 915713069771694605);
        check_virtual_price_does_not_decrease_from_swap(910459, 881022795253102152, 849356109159383524, 343201280716053581);
        check_virtual_price_does_not_decrease_from_swap(574313, 693882985649762048, 223018625534249384, 1030399677760047728);
        check_virtual_price_does_not_decrease_from_swap(221399, 1102185297781272405, 967967566195934872, 109900135254114860);
        check_virtual_price_does_not_decrease_from_swap(443138, 342167848591882611, 337273841929517372, 707284356838897778);
        check_virtual_price_does_not_decrease_from_swap(441893, 724779130757212934, 899565622709353699, 80671631688440492);
        check_virtual_price_does_not_decrease_from_swap(21076, 373367422902052393, 623811249531177621, 647263383039513574);
        check_virtual_price_does_not_decrease_from_swap(800418, 922856899596163656, 655852663006860877, 19188696439167358);
        check_virtual_price_does_not_decrease_from_swap(612309, 1110541897345983820, 1056302646049262139, 177730034064304145);
        check_virtual_price_does_not_decrease_from_swap(96695, 936829735706672580, 715644745359865672, 638131992675912091);
        check_virtual_price_does_not_decrease_from_swap(220504, 347800060641138878, 155839158291608146, 348647376354843581);
        check_virtual_price_does_not_decrease_from_swap(367296, 957264678514097625, 874990005540549763, 516983056561110610);
        check_virtual_price_does_not_decrease_from_swap(135622, 339442074694648790, 949299039762451835, 422069798084251053);
        check_virtual_price_does_not_decrease_from_swap(8929, 788165296747681417, 581970351508422200, 616769137783509580);
        check_virtual_price_does_not_decrease_from_swap(546197, 176003171746196892, 231632157671615180, 620119688377823567);
        check_virtual_price_does_not_decrease_from_swap(705147, 743777383849716397, 962818824887242239, 128878120184510863);
        check_virtual_price_does_not_decrease_from_swap(780235, 1145741813191387230, 1087584349510145818, 647102692933526868);
        check_virtual_price_does_not_decrease_from_swap(192948, 698270598624763716, 958273374702781429, 116745817518747709);
        check_virtual_price_does_not_decrease_from_swap(377135, 514300978788064825, 876750035743724265, 962110246489076842);
        check_virtual_price_does_not_decrease_from_swap(563332, 465862906370148390, 43602559516399740, 127189911720875624);
        check_virtual_price_does_not_decrease_from_swap(979126, 489269961173074341, 14586424876105660, 930209430720387476);
        check_virtual_price_does_not_decrease_from_swap(550808, 959505011352679171, 931077737837757647, 74428095942680367);
        check_virtual_price_does_not_decrease_from_swap(991594, 256574713445589969, 78047087236608156, 470243481255779059);
        check_virtual_price_does_not_decrease_from_swap(477378, 837715672446206369, 867740286750595655, 724637608971692324);
        check_virtual_price_does_not_decrease_from_swap(329953, 1089853202024064680, 473629154734017930, 653860028784795801);
        check_virtual_price_does_not_decrease_from_swap(420176, 727209233798759404, 382977648673085608, 512301647364832121);
        check_virtual_price_does_not_decrease_from_swap(627667, 1116838838894200092, 228073045598497514, 534518963325246545);
        check_virtual_price_does_not_decrease_from_swap(542944, 439215349382207935, 621383653922251325, 771513415518460986);
        check_virtual_price_does_not_decrease_from_swap(337401, 1148060931907603377, 86007123965949692, 980491552087898946);
        check_virtual_price_does_not_decrease_from_swap(940670, 923101885489487072, 542476513872410878, 1036570810747535612);
        check_virtual_price_does_not_decrease_from_swap(342887, 36900080146116671, 808416680953222909, 439271831532124813);
        check_virtual_price_does_not_decrease_from_swap(71143, 137532715101271832, 234590452051395562, 1075399266654650779);
        check_virtual_price_does_not_decrease_from_swap(441006, 535643942476093899, 64147162341570039, 595717184438259800);
        check_virtual_price_does_not_decrease_from_swap(337660, 67509301798586673, 412249195047022486, 573191754841220222);
        check_virtual_price_does_not_decrease_from_swap(986024, 1042314502542396226, 260963884496974992, 374607705350710878);
        check_virtual_price_does_not_decrease_from_swap(795210, 209052641525336664, 836960538129656702, 1142687211137047017);
        check_virtual_price_does_not_decrease_from_swap(330391, 974818495309308351, 201742953649657944, 767981814741824160);
        check_virtual_price_does_not_decrease_from_swap(197265, 332901240034150030, 949646128210951360, 442334980701246386);
        check_virtual_price_does_not_decrease_from_swap(498765, 554205546655236641, 710120430055746465, 106715802784592016);
        check_virtual_price_does_not_decrease_from_swap(768840, 1070159043498947972, 1129232104572370006, 89139022653995358);
        check_virtual_price_does_not_decrease_from_swap(887429, 53483754757055523, 81155199671828850, 1056880148943469172);
        check_virtual_price_does_not_decrease_from_swap(508131, 523344576411099598, 140620267505380224, 345705512661532414);
        check_virtual_price_does_not_decrease_from_swap(62535, 491709373934180461, 864168318791899021, 701850495012386121);
        check_virtual_price_does_not_decrease_from_swap(187820, 573408829920388811, 372435518348159267, 155151325072801491);
        check_virtual_price_does_not_decrease_from_swap(839766, 375499839440307613, 1062549656856799861, 365295391358251708);
        check_virtual_price_does_not_decrease_from_swap(488546, 199839295369855846, 632494363283248914, 644322556138708239);
        check_virtual_price_does_not_decrease_from_swap(961893, 604511926513783900, 178992365341543899, 498146028310559321);
        check_virtual_price_does_not_decrease_from_swap(398923, 554719835271122734, 170258127433736280, 409262759061864563);
        check_virtual_price_does_not_decrease_from_swap(778864, 525968421321911775, 677021056918410454, 726841615979631527);
        check_virtual_price_does_not_decrease_from_swap(629879, 51497610530955134, 992341337388483492, 328437534793887238);
        check_virtual_price_does_not_decrease_from_swap(195801, 1092372870811971686, 237870324182000459, 398797768334232634);
        check_virtual_price_does_not_decrease_from_swap(941016, 592205590278151968, 56091589317778546, 302701818777315321);
        check_virtual_price_does_not_decrease_from_swap(415765, 180249488095565291, 481083550392643135, 545112198005639134);
        check_virtual_price_does_not_decrease_from_swap(190904, 675929767693112207, 418107970524734907, 412118330929369281);
        check_virtual_price_does_not_decrease_from_swap(189028, 659618514808245743, 126051569074866979, 374482681509317185);
        check_virtual_price_does_not_decrease_from_swap(731047, 421502104348095257, 170638860041459443, 148524854545451681);
        check_virtual_price_does_not_decrease_from_swap(934635, 521151994250976774, 203225045908038964, 794199372243645450);
        check_virtual_price_does_not_decrease_from_swap(641579, 339441148368938692, 848741428178148171, 134473774558801117);
        check_virtual_price_does_not_decrease_from_swap(108532, 268148895590048341, 1093495668992199032, 1023720719061797916);
        check_virtual_price_does_not_decrease_from_swap(585713, 76502744588577985, 306747510677903015, 1070727872309349564);
        check_virtual_price_does_not_decrease_from_swap(867723, 32085449686208793, 137399442805132795, 169598181627728926);
        check_virtual_price_does_not_decrease_from_swap(942554, 319698492885027265, 468942742357673922, 51093975544050211);
        check_virtual_price_does_not_decrease_from_swap(281111, 872844772006101218, 1141705342415525335, 469484994661242735);
        check_virtual_price_does_not_decrease_from_swap(877934, 807216703454095502, 83172362211421405, 1077135780716198755);
        check_virtual_price_does_not_decrease_from_swap(215865, 371098707916050484, 839882340240323706, 839611301389352454);
        check_virtual_price_does_not_decrease_from_swap(818324, 1076085447066423654, 818588750196633889, 183592904510652707);
        check_virtual_price_does_not_decrease_from_swap(66238, 54780085866118637, 395178517426326032, 156697390588244617);
        check_virtual_price_does_not_decrease_from_swap(564781, 794473824057393905, 944639218488654941, 605211975837795618);
        check_virtual_price_does_not_decrease_from_swap(743882, 6828944116641534, 329283978280032313, 1019634013430540948);
        check_virtual_price_does_not_decrease_from_swap(792891, 878974355481030842, 650810382664957687, 378856134589914016);
        check_virtual_price_does_not_decrease_from_swap(618149, 336006764172503138, 571149847530735746, 202587856880589607);
        check_virtual_price_does_not_decrease_from_swap(446039, 172880340592680447, 449395323603386122, 601809486747358795);
        check_virtual_price_does_not_decrease_from_swap(566452, 572991076987342750, 815818067158435461, 265364465032318944);
        check_virtual_price_does_not_decrease_from_swap(157271, 135585113785929713, 1001583974123246579, 241105090771924706);
        check_virtual_price_does_not_decrease_from_swap(600946, 995017238677634278, 856567530317079876, 92372073885150463);
        check_virtual_price_does_not_decrease_from_swap(804881, 292368795555614605, 896589009233701586, 972397850389041946);
        check_virtual_price_does_not_decrease_from_swap(710340, 717030906327555340, 45652404264640200, 29805219186169778);
        check_virtual_price_does_not_decrease_from_swap(641779, 1030994649767463218, 623091900502989130, 830046497776527176);
        check_virtual_price_does_not_decrease_from_swap(760863, 48973588196358716, 260618035531018121, 975525712729890409);
        check_virtual_price_does_not_decrease_from_swap(109672, 1100316613741515017, 490840847587873594, 496848537070280742);
        check_virtual_price_does_not_decrease_from_swap(598346, 661873715078567768, 680155171664564858, 506233558219573313);
        check_virtual_price_does_not_decrease_from_swap(722467, 165273636197575477, 1078543087492690153, 541643462903906706);
        check_virtual_price_does_not_decrease_from_swap(15348, 323549952608806644, 287449187874186793, 772803518111320054);
        check_virtual_price_does_not_decrease_from_swap(331847, 902322059711029537, 632262648492854174, 119578544734084559);
        check_virtual_price_does_not_decrease_from_swap(153947, 469525004501433576, 111328692526832623, 287654412353136506);
        check_virtual_price_does_not_decrease_from_swap(91847, 936914066271689505, 1148803865853821464, 561807527329578876);
        check_virtual_price_does_not_decrease_from_swap(789224, 775564095660908806, 1087224406399316498, 295544489386422536);
        check_virtual_price_does_not_decrease_from_swap(565208, 590373479208264097, 501948615174802343, 306405110297855336);
        check_virtual_price_does_not_decrease_from_swap(224460, 472836261836457085, 661395964604795906, 827288390048032747);
        check_virtual_price_does_not_decrease_from_swap(983949, 355478090736148605, 939448582414333637, 474988530179823200);
        check_virtual_price_does_not_decrease_from_swap(639958, 784556533607448846, 196397096028259120, 156383125248556939);
        check_virtual_price_does_not_decrease_from_swap(665718, 365881555574591680, 318067007737904430, 35940373438678000);
        check_virtual_price_does_not_decrease_from_swap(436322, 665829444309507321, 76451287220404218, 722512514298952967);
        check_virtual_price_does_not_decrease_from_swap(997654, 924273061869606918, 732934662257133390, 847325772319263728);
        check_virtual_price_does_not_decrease_from_swap(632294, 374322948052401199, 538692292268183215, 502444646391684534);
        check_virtual_price_does_not_decrease_from_swap(927245, 520886347119826512, 349572220185450257, 292276867647091399);
        check_virtual_price_does_not_decrease_from_swap(348564, 594929983370546778, 721894793575678139, 789230159170103903);
        check_virtual_price_does_not_decrease_from_swap(130160, 41552486303883385, 542463784368791768, 271155931072540293);
        check_virtual_price_does_not_decrease_from_swap(386159, 278481627124348489, 124874887027821393, 129439680067955121);
        check_virtual_price_does_not_decrease_from_swap(372076, 253116652625061568, 162960697582897066, 552330081655281116);
        check_virtual_price_does_not_decrease_from_swap(772730, 865108212877008022, 394757131467800614, 461682993052020384);
        check_virtual_price_does_not_decrease_from_swap(32606, 519052140245061367, 843103827280436470, 999491505150342326);
        check_virtual_price_does_not_decrease_from_swap(992352, 644318902159983008, 41164703926256127, 697258381030044286);
        check_virtual_price_does_not_decrease_from_swap(975024, 144767221062317702, 1051688360955763070, 990637767812189150);
        check_virtual_price_does_not_decrease_from_swap(739740, 69906107754011366, 159772232386323607, 565392210050820030);
        check_virtual_price_does_not_decrease_from_swap(99715, 1060110052830101839, 574173551188144989, 703799828462615981);
        check_virtual_price_does_not_decrease_from_swap(740383, 520732463402889506, 113255586818182190, 170453022968905988);
        check_virtual_price_does_not_decrease_from_swap(122486, 878519631700499482, 23213988005304634, 4897867664026702);
        check_virtual_price_does_not_decrease_from_swap(877809, 687977089715532144, 446725813625134580, 1053952908933049006);
        check_virtual_price_does_not_decrease_from_swap(198814, 496066723702885568, 903339237581509278, 1035829782706013398);
        check_virtual_price_does_not_decrease_from_swap(278067, 195534862113751642, 247047031406768234, 990696288471995526);
        check_virtual_price_does_not_decrease_from_swap(975372, 304889154756009078, 40631488807876429, 1137394834506870543);
        check_virtual_price_does_not_decrease_from_swap(869078, 288157737094416633, 838448446355322986, 492216885767868227);
        check_virtual_price_does_not_decrease_from_swap(647982, 874661973457400074, 1107651183822673674, 882862465420744272);
        check_virtual_price_does_not_decrease_from_swap(806984, 927063391128526284, 856379144235286448, 900712114949876386);
        check_virtual_price_does_not_decrease_from_swap(148797, 674868361376818487, 854902634850138393, 764732070189636583);
        check_virtual_price_does_not_decrease_from_swap(570800, 1022775738947869646, 364549597346582738, 993548348864722712);
        check_virtual_price_does_not_decrease_from_swap(523408, 250542782485179905, 667515777071265743, 251201500764997459);
        check_virtual_price_does_not_decrease_from_swap(365450, 1133475853669978407, 195283099907967629, 484544773949788685);
        check_virtual_price_does_not_decrease_from_swap(854257, 573061464504952056, 753037100891517221, 458672797714745542);
        check_virtual_price_does_not_decrease_from_swap(175572, 56182535795889489, 996774764101960880, 211180242586871172);
        check_virtual_price_does_not_decrease_from_swap(831012, 768325353884277171, 490742005510300039, 14195833675036372);
        check_virtual_price_does_not_decrease_from_swap(485062, 739143425993039540, 1033530061971524760, 5471219362783911);
        check_virtual_price_does_not_decrease_from_swap(177723, 321242058038899892, 497699044806712733, 444977834631998714);
        check_virtual_price_does_not_decrease_from_swap(174112, 820926926087486417, 526386418887487404, 637770460366705006);
        check_virtual_price_does_not_decrease_from_swap(963072, 335157885671654784, 250131082047526403, 449535352367018392);
        check_virtual_price_does_not_decrease_from_swap(783266, 185443701682212763, 182703911968040009, 6225075507470596);
        check_virtual_price_does_not_decrease_from_swap(593064, 469358057197954518, 1116416241509828922, 989484785780480417);
        check_virtual_price_does_not_decrease_from_swap(258458, 421423692073673589, 713557835523963165, 989476432177998442);
        check_virtual_price_does_not_decrease_from_swap(30047, 1121518163135628538, 895415097338129402, 248562322698501202);
        check_virtual_price_does_not_decrease_from_swap(217663, 505783270631025875, 847758991191348785, 384502309441133009);
        check_virtual_price_does_not_decrease_from_swap(972650, 276230860376494182, 138227098443002068, 188437088739183995);
        check_virtual_price_does_not_decrease_from_swap(802746, 80398948179312056, 217184363548382969, 707900220537940239);
        check_virtual_price_does_not_decrease_from_swap(269842, 1011007547506880818, 347916082933142349, 559258356667321811);
        check_virtual_price_does_not_decrease_from_swap(503496, 1083293168168904040, 1105926998155638106, 765464310360280308);
        check_virtual_price_does_not_decrease_from_swap(837096, 742286622403778035, 897908358626304434, 330543658476947967);
        check_virtual_price_does_not_decrease_from_swap(472070, 161614825525712662, 848281870884822642, 272578355077547854);
        check_virtual_price_does_not_decrease_from_swap(83652, 1076516017192076691, 184185340368596399, 653250098780897854);
        check_virtual_price_does_not_decrease_from_swap(785096, 987782364155049689, 472843622568120450, 748704655432920676);
        check_virtual_price_does_not_decrease_from_swap(491135, 136222780689778978, 963525010522640584, 10910265836591418);
        check_virtual_price_does_not_decrease_from_swap(871485, 1152525174553734522, 1033867807193265323, 1044356129794468232);
        check_virtual_price_does_not_decrease_from_swap(213623, 518056993680171611, 20755820132025739, 876090769969764620);
        check_virtual_price_does_not_decrease_from_swap(588670, 205165582342752826, 611623843040120903, 800290582952633680);
        check_virtual_price_does_not_decrease_from_swap(592329, 7849093771448911, 986479173561177202, 180126834449469529);
        check_virtual_price_does_not_decrease_from_swap(819968, 92591282111772451, 859832131190939215, 495292224746927695);
        check_virtual_price_does_not_decrease_from_swap(115004, 475287826096072167, 736035950598164168, 6423067019056519);
        check_virtual_price_does_not_decrease_from_swap(643119, 843102377351966490, 146364917873752698, 582558191553463523);
        check_virtual_price_does_not_decrease_from_swap(450447, 500629300987841838, 713017572725636320, 840969733989185156);
        check_virtual_price_does_not_decrease_from_swap(186888, 186290307754841594, 114016676674078434, 160387715640045367);
        check_virtual_price_does_not_decrease_from_swap(844588, 342843633620067415, 917994682142011609, 327770829169515049);
        check_virtual_price_does_not_decrease_from_swap(26011, 718627307750265642, 317292842735023072, 635824635405561322);
        check_virtual_price_does_not_decrease_from_swap(252828, 908054365903909913, 521296373349334486, 356943603482378161);
        check_virtual_price_does_not_decrease_from_swap(172445, 521780904226930128, 362637862641628051, 326603932294970108);
        check_virtual_price_does_not_decrease_from_swap(642430, 982396212499344563, 401630896950490849, 1105628982567210157);
        check_virtual_price_does_not_decrease_from_swap(196743, 838347893395250638, 142773887106068942, 343568691975186671);
        check_virtual_price_does_not_decrease_from_swap(946491, 919848642321722645, 719982433507759597, 663685065462380950);
        check_virtual_price_does_not_decrease_from_swap(553390, 51428355534357963, 518648182087921883, 1127254888603907463);
        check_virtual_price_does_not_decrease_from_swap(737333, 986600342985349809, 38514953159898862, 408788211289774171);
        check_virtual_price_does_not_decrease_from_swap(703002, 200238070345821001, 379330086817774943, 759738777946393829);
        check_virtual_price_does_not_decrease_from_swap(966686, 367531785548688227, 424689958548964256, 903530069880608505);
        check_virtual_price_does_not_decrease_from_swap(56244, 862478342617281729, 1017314365580449304, 22822289252257961);
        check_virtual_price_does_not_decrease_from_swap(856048, 89730348713247087, 779388171707478903, 763069787307591026);
        check_virtual_price_does_not_decrease_from_swap(984608, 549388824400597725, 581168455325149431, 546971025701662940);
        check_virtual_price_does_not_decrease_from_swap(457223, 1044162431955326661, 328746746569242653, 717557217255864904);
        check_virtual_price_does_not_decrease_from_swap(265818, 1019602055801296850, 310296677757924310, 279666509859285892);
        check_virtual_price_does_not_decrease_from_swap(838639, 959266728591630142, 1053578789184606784, 750691552806676458);
        check_virtual_price_does_not_decrease_from_swap(884970, 1117455201130147101, 500916058317287578, 445765392949014536);   
    }

    #[test]
    fun test_virtual_price_does_not_decrease_from_withdraw() {
        check_virtual_price_does_not_decrease_from_withdraw(794249, 486966262337048995, 1098512304148995858, 885493441740400850, 1044329034977142354);
        check_virtual_price_does_not_decrease_from_withdraw(868925, 629104828381979215, 897981734417101733, 322717571324767448, 843337986275137841);
        check_virtual_price_does_not_decrease_from_withdraw(371399, 961888572623043414, 1045994308171251163, 1084891362137449270, 859873011823748376);
        check_virtual_price_does_not_decrease_from_withdraw(430572, 79630170350209603, 177591284580366521, 1129966373690165551, 876616472258640818);
        check_virtual_price_does_not_decrease_from_withdraw(546070, 651296321086639740, 864328675702877778, 757548616235943903, 769256818011835274);
        check_virtual_price_does_not_decrease_from_withdraw(709438, 134266073314683647, 155777205953697866, 1073822116933832554, 1145131926714098157);
        check_virtual_price_does_not_decrease_from_withdraw(265244, 798753685938737016, 884646985225475571, 723952568320187728, 578079473191874306);
        check_virtual_price_does_not_decrease_from_withdraw(520176, 45107416701968984, 132748752954455561, 486182494646946038, 577111089618202970);
        check_virtual_price_does_not_decrease_from_withdraw(291483, 769301349881067652, 919117658185421677, 1030066811786778194, 299596350261401730);
        check_virtual_price_does_not_decrease_from_withdraw(120278, 440369742932920045, 1079442425410403086, 169707295112880800, 268200722623726784);
        check_virtual_price_does_not_decrease_from_withdraw(363063, 367918221374388332, 808274432087619306, 549127942632923493, 1130811990664771933);
        check_virtual_price_does_not_decrease_from_withdraw(178662, 624895426683897901, 1090069986378963897, 912673090455414064, 269481274037133734);
        check_virtual_price_does_not_decrease_from_withdraw(390446, 216590807961118560, 383291321659870753, 144154352152756991, 681513658829730422);
        check_virtual_price_does_not_decrease_from_withdraw(155365, 261984472701770758, 276169414787536678, 84558937404785289, 960214440114820680);
        check_virtual_price_does_not_decrease_from_withdraw(324879, 561721202713571592, 636958681157317909, 157469693275761869, 968170398581052732);
        check_virtual_price_does_not_decrease_from_withdraw(458864, 116625984265537073, 275985038863019975, 175740955499884956, 997984539852145195);
        check_virtual_price_does_not_decrease_from_withdraw(280907, 166882617709934102, 1112151181405141519, 198168735970605353, 30044356970164385);
        check_virtual_price_does_not_decrease_from_withdraw(898292, 160874912567262999, 575493718837409008, 440550368308874179, 1036019282480336614);
        check_virtual_price_does_not_decrease_from_withdraw(588547, 818994306749095836, 994990422133091116, 118431079170297881, 492969678093984933);
        check_virtual_price_does_not_decrease_from_withdraw(595612, 121096635446705482, 167648458592043847, 1136104548211268636, 196505919551405966);
        check_virtual_price_does_not_decrease_from_withdraw(193256, 251082745612872, 5259765357358810, 477694275538060737, 398660929837149121);
        check_virtual_price_does_not_decrease_from_withdraw(957778, 554213825175202055, 1058230723024803509, 1121938785738871348, 750358416325773323);
        check_virtual_price_does_not_decrease_from_withdraw(440711, 38700526729430218, 68553735816061193, 920907634622553207, 627681599368273430);
        check_virtual_price_does_not_decrease_from_withdraw(936696, 73320009579415834, 416650824040680382, 1046037127036250717, 450450014156738326);
        check_virtual_price_does_not_decrease_from_withdraw(170738, 567130855659484153, 606106203273814454, 717533059499076263, 448909365260560681);
        check_virtual_price_does_not_decrease_from_withdraw(637691, 107292529828156357, 577314370073835927, 713360455608539938, 471606287837920410);
        check_virtual_price_does_not_decrease_from_withdraw(869010, 208947878187294457, 776832597402776837, 1008690750323595281, 1152478452673120527);
        check_virtual_price_does_not_decrease_from_withdraw(346348, 113984098517956488, 265079812589635648, 659806750891508456, 29143332991063509);
        check_virtual_price_does_not_decrease_from_withdraw(450694, 290423053774698055, 1063990016454202111, 196879519377002389, 907024965799224650);
        check_virtual_price_does_not_decrease_from_withdraw(807291, 162575160368871677, 852366682387449799, 1031532548621227061, 300202028722640024);
        check_virtual_price_does_not_decrease_from_withdraw(945927, 759717732241421505, 1025176736548603257, 586215269913456947, 907282352272800727);
        check_virtual_price_does_not_decrease_from_withdraw(722844, 977094700816720633, 1071148220457429042, 743682895915062222, 167429143383540132);
        check_virtual_price_does_not_decrease_from_withdraw(928922, 43377324422255580, 136048346035796296, 584077141121453289, 735494281031314803);
        check_virtual_price_does_not_decrease_from_withdraw(213364, 473641219691873880, 538722683518941687, 1085121129322114940, 831446618727671478);
        check_virtual_price_does_not_decrease_from_withdraw(239553, 48148521400145340, 195911990046110886, 797901388645919778, 79700509339565218);
        check_virtual_price_does_not_decrease_from_withdraw(87000, 57458086648794387, 1132992882310355423, 145031758345779931, 1082110856352466705);
        check_virtual_price_does_not_decrease_from_withdraw(662679, 590874774548189205, 1011058392152256133, 836259390318387709, 92993338617375378);
        check_virtual_price_does_not_decrease_from_withdraw(202212, 170397719633701872, 1049105769710668234, 36601012263295936, 982651963410153485);
        check_virtual_price_does_not_decrease_from_withdraw(228317, 43050217824409982, 51848238097785799, 52459694165579859, 967002137928095105);
        check_virtual_price_does_not_decrease_from_withdraw(986997, 61716116970235094, 62275509538711437, 1123518528584736555, 284146794409880759);
        check_virtual_price_does_not_decrease_from_withdraw(772766, 167435658789442670, 379073073380585760, 284596253030280401, 799023526228097734);
        check_virtual_price_does_not_decrease_from_withdraw(839851, 916412234559564687, 949388652373181059, 705541475400372387, 149755593352792377);
        check_virtual_price_does_not_decrease_from_withdraw(561565, 22096211437338133, 383349533239787072, 541853123964774271, 78911678156663017);
        check_virtual_price_does_not_decrease_from_withdraw(634482, 618140099169807997, 687455385247762903, 635326691185640811, 94899369877538945);
        check_virtual_price_does_not_decrease_from_withdraw(11197, 58872752424637790, 704264826059198566, 606164195185089062, 236414484943902475);
        check_virtual_price_does_not_decrease_from_withdraw(787481, 357259248550773705, 1045367682681860245, 38408497520352858, 158189956065614935);
        check_virtual_price_does_not_decrease_from_withdraw(544323, 274767260909668921, 901634285868934445, 23638510793611537, 224296549331654943);
        check_virtual_price_does_not_decrease_from_withdraw(725478, 56726602197061136, 813862528909591696, 789255269151152715, 1077966220205602780);
        check_virtual_price_does_not_decrease_from_withdraw(881675, 460022349789615503, 716802565322567610, 598300192144415364, 31254338195290290);
        check_virtual_price_does_not_decrease_from_withdraw(718296, 313228251089848943, 592062788592495300, 152728279298923238, 682598719248226338);
        check_virtual_price_does_not_decrease_from_withdraw(761052, 51635664211848813, 277794903739720520, 577310503632520877, 1007819586819906777);
        check_virtual_price_does_not_decrease_from_withdraw(399820, 455028771411271436, 570253777692590377, 817058256097594819, 760719146316865966);
        check_virtual_price_does_not_decrease_from_withdraw(917881, 272188528784379585, 781002133167521290, 941927452170742850, 812601924538555614);
        check_virtual_price_does_not_decrease_from_withdraw(727854, 205204901543635873, 400522445599515732, 767643776944153935, 45585917234355916);
        check_virtual_price_does_not_decrease_from_withdraw(443792, 37675568124938161, 78956553275325355, 685116378584053177, 362641541510517041);
        check_virtual_price_does_not_decrease_from_withdraw(824002, 482535829908871788, 546946472053795482, 983488850978794029, 577585968318432072);
        check_virtual_price_does_not_decrease_from_withdraw(483315, 570278058944417868, 958198841485749691, 498045454251176784, 62761993001774641);
        check_virtual_price_does_not_decrease_from_withdraw(880993, 382123089660819534, 410435365143743095, 501604221748538105, 1100348549066044810);
        check_virtual_price_does_not_decrease_from_withdraw(620055, 61621281506287998, 438783637339215108, 1035293010978365129, 26011054906234338);
        check_virtual_price_does_not_decrease_from_withdraw(509270, 236628222232824906, 451287268138771050, 636852492398426067, 496078145070603524);
        check_virtual_price_does_not_decrease_from_withdraw(818345, 340716298898666435, 1047301097980443269, 199483234264439631, 108080547832876181);
        check_virtual_price_does_not_decrease_from_withdraw(488152, 352536991033291966, 1018965344355291267, 1007450486171928796, 202837086833924407);
        check_virtual_price_does_not_decrease_from_withdraw(91610, 707331008453730225, 771290052207517019, 1084152765077138095, 102494130702979086);
        check_virtual_price_does_not_decrease_from_withdraw(404752, 1092661957964412897, 1149666845107962619, 625285323523579190, 512879837537722286);
        check_virtual_price_does_not_decrease_from_withdraw(596577, 189113166139616999, 721755115317157043, 759124713259598036, 374694808426008474);
        check_virtual_price_does_not_decrease_from_withdraw(494236, 279213504499978219, 874460831916824134, 33438098256482125, 974000867741511288);
        check_virtual_price_does_not_decrease_from_withdraw(755751, 345026942282378008, 456477320464659517, 754244018330054021, 1135900376770739628);
        check_virtual_price_does_not_decrease_from_withdraw(27602, 335843148387003211, 1035884925345602671, 375783295296476503, 349009295826214461);
        check_virtual_price_does_not_decrease_from_withdraw(319481, 550972137096994592, 855703216124711770, 924519370253913713, 762946067304499920);
        check_virtual_price_does_not_decrease_from_withdraw(667468, 193156852230381226, 229788684737462429, 849398839866037916, 266183072979303029);
        check_virtual_price_does_not_decrease_from_withdraw(386331, 244088006955172664, 469444539797894739, 268711077975490293, 818069804068214704);
        check_virtual_price_does_not_decrease_from_withdraw(309715, 150219717343624510, 223490261206733612, 356247873849203620, 1005816210668250657);
        check_virtual_price_does_not_decrease_from_withdraw(323282, 100118122880464198, 140089382887510086, 120046620431163978, 513637887838254462);
        check_virtual_price_does_not_decrease_from_withdraw(648222, 89509586541236853, 987853767547282483, 532936287853735677, 807499110389269917);
        check_virtual_price_does_not_decrease_from_withdraw(832815, 349672776865309878, 741457103753228126, 1014166886281778540, 373003685593789583);
        check_virtual_price_does_not_decrease_from_withdraw(350024, 89844034943771789, 522161648255140279, 44267672223983832, 140044838184032482);
        check_virtual_price_does_not_decrease_from_withdraw(494468, 42898415723217939, 67800253307107143, 538512701462651063, 120970198894463323);
        check_virtual_price_does_not_decrease_from_withdraw(124197, 158344247696523437, 307434233260322836, 537744533316701531, 350176401176203517);
        check_virtual_price_does_not_decrease_from_withdraw(912051, 218517640470775287, 614842172605281928, 888076762913508660, 775056830150266934);
        check_virtual_price_does_not_decrease_from_withdraw(642909, 453530037986570114, 847207010333791396, 879337425658969214, 681052730998657765);
        check_virtual_price_does_not_decrease_from_withdraw(579397, 19744436373398000, 129071482765426904, 391223056135552158, 250199949684828828);
        check_virtual_price_does_not_decrease_from_withdraw(536884, 401887834371476153, 476955661160700243, 445736647071913434, 267072915929172557);
        check_virtual_price_does_not_decrease_from_withdraw(55743, 85406227575532141, 658144542497702201, 132758187320695062, 682453625441515981);
        check_virtual_price_does_not_decrease_from_withdraw(871378, 335039050502872055, 917896015442712675, 947293602600236979, 1007870690374135346);
        check_virtual_price_does_not_decrease_from_withdraw(63195, 706826599460546643, 712611587809085184, 92945325528780278, 248092384681400506);
        check_virtual_price_does_not_decrease_from_withdraw(219164, 276502410734862221, 558131705836826505, 696435926575206021, 730923848956203471);
        check_virtual_price_does_not_decrease_from_withdraw(59847, 196467350561546, 3595214156358818, 497893902203658790, 580395959013934660);
        check_virtual_price_does_not_decrease_from_withdraw(803855, 325483249464429400, 334825197778202822, 755600672796857399, 572102482561879929);
        check_virtual_price_does_not_decrease_from_withdraw(621546, 587492331888998560, 885068412624878082, 324261349067264349, 473161270766566083);
        check_virtual_price_does_not_decrease_from_withdraw(238885, 95947910922840160, 137927900358060084, 485107391335919439, 392808581199127372);
        check_virtual_price_does_not_decrease_from_withdraw(20491, 186514918769150712, 290610458649458591, 275154768056147859, 303001314707051218);
        check_virtual_price_does_not_decrease_from_withdraw(962583, 860905501433826997, 911282489932726844, 1148894327754177494, 1078399729063520915);
        check_virtual_price_does_not_decrease_from_withdraw(932442, 27769844098247605, 64325244825559770, 258703301203800864, 976749065552553423);
        check_virtual_price_does_not_decrease_from_withdraw(241838, 146361085808385719, 668044743434050870, 629026974486235731, 549481960696530291);
        check_virtual_price_does_not_decrease_from_withdraw(236480, 15838051031976747, 1051270249135308675, 583199035419645763, 878389005841754054);
        check_virtual_price_does_not_decrease_from_withdraw(637497, 20713777507681187, 147588999692408956, 535630150576491990, 452417623909492352);
        check_virtual_price_does_not_decrease_from_withdraw(805792, 171512842010791499, 562796507587197407, 27016672040454683, 941767648840809138);
        check_virtual_price_does_not_decrease_from_withdraw(692402, 507668953719706570, 849539385048116404, 621179625633550411, 131449041065517625);
        check_virtual_price_does_not_decrease_from_withdraw(596532, 207133525416890594, 647204043447575421, 750586121518818022, 1986399768769465);
        check_virtual_price_does_not_decrease_from_withdraw(117471, 403501623739687499, 935755742267538106, 710538934453898802, 463886354485905760);
        check_virtual_price_does_not_decrease_from_withdraw(706116, 309427765898076422, 481806249557480349, 131997003872939532, 520656203441459019);
        check_virtual_price_does_not_decrease_from_withdraw(718565, 48310535278851184, 77546956020781623, 131723568071777144, 751656608640052550);
        check_virtual_price_does_not_decrease_from_withdraw(329203, 28974313779586110, 57698343141315330, 1017145759979489411, 200441599341477082);
        check_virtual_price_does_not_decrease_from_withdraw(143370, 13179610574758255, 340187686160898914, 53275176327584219, 936220658251462762);
        check_virtual_price_does_not_decrease_from_withdraw(609995, 572230948994042309, 823718289699806197, 516991599674422258, 1054357178466424174);
        check_virtual_price_does_not_decrease_from_withdraw(727003, 79004519583430448, 143332337194727727, 602869983239445818, 1118372223876995112);
        check_virtual_price_does_not_decrease_from_withdraw(641801, 245914030703965907, 328569553070302170, 370268109567795507, 305882594813464926);
        check_virtual_price_does_not_decrease_from_withdraw(417357, 447662690774752742, 461119963009003825, 47218303766235897, 1062676944189465012);
        check_virtual_price_does_not_decrease_from_withdraw(779402, 145228962867617447, 1139535664572120422, 793033419096204437, 436755326738378763);
        check_virtual_price_does_not_decrease_from_withdraw(896343, 793229529647582668, 1076442446649898943, 1026762139289984731, 211712710406779466);
        check_virtual_price_does_not_decrease_from_withdraw(867554, 63672206388594788, 468406449292676582, 1069969301478312641, 929895429541310032);
        check_virtual_price_does_not_decrease_from_withdraw(613673, 172620720272743596, 233374280427820817, 269076001305697325, 759427616117507420);
        check_virtual_price_does_not_decrease_from_withdraw(189497, 126641750621926068, 382936256699423794, 33931672528981799, 1009113853789763025);
        check_virtual_price_does_not_decrease_from_withdraw(777827, 421530016802742565, 628438567498617986, 971541024883525974, 170707972469227086);
        check_virtual_price_does_not_decrease_from_withdraw(466109, 588569944707301940, 819873615940486509, 920042979277475762, 188229153512474139);
        check_virtual_price_does_not_decrease_from_withdraw(69146, 334358025157974936, 890662128971707123, 136760120397830255, 594684419498618728);
        check_virtual_price_does_not_decrease_from_withdraw(264566, 387596532109262618, 635638905271582699, 555106617143161229, 478821825074001197);
        check_virtual_price_does_not_decrease_from_withdraw(887823, 701445738617590809, 1118873048705298125, 882589731039950569, 682043998840207295);
        check_virtual_price_does_not_decrease_from_withdraw(633977, 131839288505707690, 610848107540756678, 566444035736689918, 29818436186043854);
        check_virtual_price_does_not_decrease_from_withdraw(886686, 169838863763616235, 348572971767449696, 299665939624786692, 344181943845814306);
        check_virtual_price_does_not_decrease_from_withdraw(396077, 158602799042962708, 1074508031271095911, 176698618769877811, 647193399028568922);
        check_virtual_price_does_not_decrease_from_withdraw(275542, 80175163079832572, 484439213142713561, 358448296357387330, 563778479954076308);
        check_virtual_price_does_not_decrease_from_withdraw(987088, 291594682011438708, 631475441453978772, 57023955075348215, 864748686565418133);
        check_virtual_price_does_not_decrease_from_withdraw(580241, 333308626462268443, 632890850760290871, 1022353832348193815, 212468128809581991);
        check_virtual_price_does_not_decrease_from_withdraw(715, 432789609943248144, 656182830642686277, 1085634404582293816, 1098849826356269026);
        check_virtual_price_does_not_decrease_from_withdraw(613379, 577637888601454583, 822620066361748855, 1026674716866695282, 37712951861747723);
        check_virtual_price_does_not_decrease_from_withdraw(366820, 450188423305849248, 834478704110570084, 498300076199621333, 21114167092589341);
        check_virtual_price_does_not_decrease_from_withdraw(31307, 650584773332151630, 991667193013435313, 792917248337624091, 414434772410624260);
        check_virtual_price_does_not_decrease_from_withdraw(136079, 502506029046554231, 522316620157015554, 351774552327384685, 797255407967996701);
        check_virtual_price_does_not_decrease_from_withdraw(200809, 574654901125299644, 1087678843312258224, 313560056798009389, 765140163553022385);
        check_virtual_price_does_not_decrease_from_withdraw(827724, 290335341793902744, 302835627428395036, 541179286069623749, 894075579265824502);
        check_virtual_price_does_not_decrease_from_withdraw(234858, 616852045528277611, 900682667335582003, 226178385304614250, 1131255267317831096);
        check_virtual_price_does_not_decrease_from_withdraw(974387, 511834131305593276, 814622839022275921, 903655482010932761, 306678602740949751);
        check_virtual_price_does_not_decrease_from_withdraw(591282, 344037654664416954, 712266973068820069, 523735964191517377, 293048161412954855);
        check_virtual_price_does_not_decrease_from_withdraw(35773, 9822892156776140, 15157316034368187, 348339144833458622, 98478701359846451);
        check_virtual_price_does_not_decrease_from_withdraw(518226, 518573233926878907, 619217151495496749, 181240168230186818, 615254307128892006);
        check_virtual_price_does_not_decrease_from_withdraw(20503, 30283426835598823, 38340792248486639, 1087469154995891247, 489702755982461699);
        check_virtual_price_does_not_decrease_from_withdraw(164205, 31392498870031188, 98708695585628476, 620080612071057657, 911190486843962268);
        check_virtual_price_does_not_decrease_from_withdraw(183169, 383910127655778298, 545297326024353010, 243850017279415433, 113488131254509922);
        check_virtual_price_does_not_decrease_from_withdraw(311506, 137808309498854163, 449518293249858340, 786866593046782364, 160589296230601583);
        check_virtual_price_does_not_decrease_from_withdraw(667765, 73123542258438987, 672544104728674523, 1016331053671507970, 350980303430584323);
        check_virtual_price_does_not_decrease_from_withdraw(324729, 158262095008762686, 1005818054946574198, 823928028518621476, 392762662807740371);
        check_virtual_price_does_not_decrease_from_withdraw(446603, 415637422039520234, 720911168040963429, 752783240393470060, 531751863997463799);
        check_virtual_price_does_not_decrease_from_withdraw(499986, 523513989604599708, 535337944129978613, 101534777390622918, 489389454992195699);
        check_virtual_price_does_not_decrease_from_withdraw(887276, 707434073822178529, 939743904385757203, 535254805389400002, 491966207406956209);
        check_virtual_price_does_not_decrease_from_withdraw(370524, 773769036113189609, 1072394662986828389, 239452447165553615, 1090142454613724660);
        check_virtual_price_does_not_decrease_from_withdraw(97333, 963462191287753632, 1081511442429694258, 917951861142222295, 233545976193168617);
        check_virtual_price_does_not_decrease_from_withdraw(23082, 198577608255296709, 487960173866947988, 444751883426448175, 34759544468998715);
        check_virtual_price_does_not_decrease_from_withdraw(324953, 144157611262829586, 338066012229665562, 907813522956256777, 763338887164071645);
        check_virtual_price_does_not_decrease_from_withdraw(485177, 430113353770340713, 439259600911593000, 214790636049524858, 877614273812047940);
        check_virtual_price_does_not_decrease_from_withdraw(63607, 343816995681580334, 888567553375370304, 974526735771181796, 508527223110961083);
        check_virtual_price_does_not_decrease_from_withdraw(585963, 641224972593335273, 869762504325783133, 771693900584826539, 1046511971370101855);
        check_virtual_price_does_not_decrease_from_withdraw(818729, 120433460277861640, 1079135599617015068, 464742397820196695, 803796418070326473);
        check_virtual_price_does_not_decrease_from_withdraw(197243, 350378151856175889, 766898575433899525, 687831608857394178, 76124271247585961);
        check_virtual_price_does_not_decrease_from_withdraw(885215, 72114355633014414, 125441548832851352, 122909084066931362, 857822373929086494);
        check_virtual_price_does_not_decrease_from_withdraw(710804, 756923584391981954, 926681369326680588, 123413143572730406, 481982618654461307);
        check_virtual_price_does_not_decrease_from_withdraw(668281, 284387759721202580, 408573659802606188, 1136413887650658406, 267779949902329938);
        check_virtual_price_does_not_decrease_from_withdraw(276550, 358869507527142628, 600920843009941907, 665247624114431971, 662128895140337998);
        check_virtual_price_does_not_decrease_from_withdraw(73661, 178652011128124619, 904990108865494933, 1001539414509649644, 914183991363406842);
        check_virtual_price_does_not_decrease_from_withdraw(948696, 23831362600731006, 44073969427845028, 945728361395836578, 763487010860193851);
        check_virtual_price_does_not_decrease_from_withdraw(881329, 663267463590298007, 973573314297859689, 372114076022798520, 366508579818832856);
        check_virtual_price_does_not_decrease_from_withdraw(949750, 13900646875234000, 17349719873571047, 8928530069709547, 37256978918862875);
        check_virtual_price_does_not_decrease_from_withdraw(708528, 110028303595308663, 136807975879192181, 280412075192410975, 861977220815029860);
        check_virtual_price_does_not_decrease_from_withdraw(593008, 35953598865302858, 1095186895764235341, 640480211113896444, 454847708684142141);
        check_virtual_price_does_not_decrease_from_withdraw(126816, 150512002406333341, 739086479150249517, 387713567056108485, 1016336109852404315);
        check_virtual_price_does_not_decrease_from_withdraw(376059, 393744131916299913, 750691908087001263, 976895187051907346, 665300214575110672);
        check_virtual_price_does_not_decrease_from_withdraw(209476, 21886071820612698, 35522365821738589, 287558366651275262, 1001467507904713651);
        check_virtual_price_does_not_decrease_from_withdraw(996912, 772941001194358758, 1053789176486520280, 409320569894964107, 155657900467761475);
        check_virtual_price_does_not_decrease_from_withdraw(33262, 335242403318977520, 366257766974293127, 116113899982033602, 731010113789469778);
        check_virtual_price_does_not_decrease_from_withdraw(99585, 568362584317122360, 862435741820298992, 453120586556523893, 468684200052524862);
        check_virtual_price_does_not_decrease_from_withdraw(892474, 679560619273726284, 697566444682537741, 654791954002683788, 684190513509356316);
        check_virtual_price_does_not_decrease_from_withdraw(437, 303431252553559477, 608808987057441404, 1114010315540971481, 407039638866782460);
        check_virtual_price_does_not_decrease_from_withdraw(8, 342660079100710526, 949177774266256740, 469145134764568953, 853169643907540869);
        check_virtual_price_does_not_decrease_from_withdraw(615713, 119787479591900537, 853020118869403509, 189379796473196120, 162297075417457369);
        check_virtual_price_does_not_decrease_from_withdraw(839292, 300404819152819559, 616780200951124073, 957255662959580695, 85931759367064738);
        check_virtual_price_does_not_decrease_from_withdraw(571714, 183196603873056577, 208428034611057193, 1059459302265388136, 603795020774240267);
        check_virtual_price_does_not_decrease_from_withdraw(808731, 505480186239106256, 625834881174284554, 441257634068055494, 237935148368150443);
        check_virtual_price_does_not_decrease_from_withdraw(306733, 726750894218799898, 732681812446900918, 358794114159606016, 640143482757327393);
        check_virtual_price_does_not_decrease_from_withdraw(190366, 232164997563104753, 333421313583291215, 180744713881763584, 972946294688738142);
        check_virtual_price_does_not_decrease_from_withdraw(909407, 399584242927129508, 775729736045599459, 698339623516122874, 708926295282234271);
        check_virtual_price_does_not_decrease_from_withdraw(575576, 1044330450940100759, 1057433987782971638, 526589629081162597, 426699193849127147);
        check_virtual_price_does_not_decrease_from_withdraw(712201, 379587941747398961, 474633395074252646, 275942813300309495, 369880983639463922);
        check_virtual_price_does_not_decrease_from_withdraw(764241, 344409337553960501, 494064871791556265, 954681159252890126, 964273210513941436);
        check_virtual_price_does_not_decrease_from_withdraw(791560, 10084595583173387, 53442884831968978, 502510174192422887, 322928521682317178);
        check_virtual_price_does_not_decrease_from_withdraw(895573, 42638629847980407, 698482366863383476, 391334062672494797, 97031495439338107);
        check_virtual_price_does_not_decrease_from_withdraw(275495, 335041993523556232, 673703766182543783, 25362977667786970, 270271928478183226);
        check_virtual_price_does_not_decrease_from_withdraw(619140, 716634695734811979, 732634333614169157, 434657830427137823, 9398814542221860);
        check_virtual_price_does_not_decrease_from_withdraw(993015, 160628941365586813, 193437023239645262, 421765758051250262, 500523368697668880);
        check_virtual_price_does_not_decrease_from_withdraw(442187, 417612820655372828, 888400326128776063, 450060006810361329, 174410158431242724);
        check_virtual_price_does_not_decrease_from_withdraw(382503, 723117044251857158, 874464785829028652, 94550927696857611, 431301047706256762);
        check_virtual_price_does_not_decrease_from_withdraw(505, 946794968843914472, 1122176939011908935, 814099768563127188, 307906505863103743);
        check_virtual_price_does_not_decrease_from_withdraw(895768, 468502046511607123, 985027080388193410, 468736936426670469, 400171967601052299);
        check_virtual_price_does_not_decrease_from_withdraw(431168, 355387449929411493, 670461341903595067, 138956449833129926, 1038847022154342542);
        check_virtual_price_does_not_decrease_from_withdraw(629293, 119844908926880286, 518135060517641096, 778328611348552055, 228423507247097300);
        check_virtual_price_does_not_decrease_from_withdraw(209823, 336153053407504197, 434205126382424580, 1095372723386605964, 212070488296790372);
        check_virtual_price_does_not_decrease_from_withdraw(728187, 105525348955939927, 324468265384429580, 1104910046896416058, 315702781452215053);
        check_virtual_price_does_not_decrease_from_withdraw(831810, 539317995560784910, 569856970910782063, 425351460943573191, 691385988661204125);
        check_virtual_price_does_not_decrease_from_withdraw(323339, 3172970895565321, 9494194662757216, 248311782871272747, 300168233957026929);
        check_virtual_price_does_not_decrease_from_withdraw(725408, 7884370961205476, 64590299285060174, 455127195724878831, 1110743080251019816);
        check_virtual_price_does_not_decrease_from_withdraw(422329, 922797711170962254, 963301048596967088, 699144014869080238, 424139566008131100);
        check_virtual_price_does_not_decrease_from_withdraw(790067, 454989374218792456, 1009745482089014741, 830656772620136399, 739019930529792933);
        check_virtual_price_does_not_decrease_from_withdraw(521698, 276394041283806926, 572330299808219962, 94348444837158396, 637392687373113731);
        check_virtual_price_does_not_decrease_from_withdraw(117173, 564635685780318274, 609283173634510179, 375229216389029375, 1118981857809854037);
        check_virtual_price_does_not_decrease_from_withdraw(596770, 261876137986623530, 559784842878271004, 154645011998421920, 962339652638514982);
        check_virtual_price_does_not_decrease_from_withdraw(64900, 178369690621710238, 225844668353436166, 1147334169676371319, 225533041241723909);
        check_virtual_price_does_not_decrease_from_withdraw(884920, 79498047163440860, 158587463702269691, 795050222004103832, 990884017512104795);
        check_virtual_price_does_not_decrease_from_withdraw(739739, 196809283274390005, 827594671578692702, 332495647374164806, 551667101948183508);
        check_virtual_price_does_not_decrease_from_withdraw(609085, 686088858818354082, 952542133329662132, 1131429478410691627, 835191619800193);
        check_virtual_price_does_not_decrease_from_withdraw(974255, 40811648413047032, 342991214075758092, 861025768236531699, 179090363371282027);
        check_virtual_price_does_not_decrease_from_withdraw(181880, 207805429344172256, 273392489102364238, 739360050278393591, 693141671263319000);
        check_virtual_price_does_not_decrease_from_withdraw(997521, 82440923922976877, 226048181537926401, 364198067829650791, 832338466246957940);
        check_virtual_price_does_not_decrease_from_withdraw(741261, 33314112740185089, 895421272046249711, 719250180617214488, 636606487507951894);
        check_virtual_price_does_not_decrease_from_withdraw(350942, 253218256782795553, 821784079882154699, 248834838233321412, 865532321033059253);
        check_virtual_price_does_not_decrease_from_withdraw(879923, 580648423184918477, 1030092194281225023, 425431980490481480, 716459854467576339);
        check_virtual_price_does_not_decrease_from_withdraw(262346, 36387291709721227, 554507882986241027, 371484400297148750, 72780393526346995);
        check_virtual_price_does_not_decrease_from_withdraw(263635, 385652394392907984, 797563885761221902, 268103910111127344, 335709608888167777);
        check_virtual_price_does_not_decrease_from_withdraw(904214, 99217033463960176, 291603342223606605, 752632372204268744, 602417191302129673);
        check_virtual_price_does_not_decrease_from_withdraw(524158, 4757206023896126, 134648090256927039, 558345590016872131, 129907016248985181);
        check_virtual_price_does_not_decrease_from_withdraw(625936, 159243041524410793, 299312253400088796, 1058874199034368168, 343860653395712868);
        check_virtual_price_does_not_decrease_from_withdraw(297751, 62383811126614587, 918463535972142350, 487037403314024527, 279641220181793610);
        check_virtual_price_does_not_decrease_from_withdraw(161817, 28811044724507797, 494144687900856108, 721570676763148145, 48090176017159690);
        check_virtual_price_does_not_decrease_from_withdraw(345916, 30070747820518567, 40126828669631676, 697080693643324816, 773268002418795700);
        check_virtual_price_does_not_decrease_from_withdraw(187216, 206529658958703643, 683759484629673147, 400702067669361726, 656654032742531249);
        check_virtual_price_does_not_decrease_from_withdraw(970832, 365736454020809888, 401321356115860501, 945053175406357502, 897035383484362770);
        check_virtual_price_does_not_decrease_from_withdraw(827985, 19385107493545865, 43226861959484046, 934465381750286401, 587585882214727355);
        check_virtual_price_does_not_decrease_from_withdraw(43001, 295514509312242453, 1001677433230706129, 362571376471305710, 1150570129254481634);
        check_virtual_price_does_not_decrease_from_withdraw(686159, 198629015397964300, 621609719830200445, 592720485993890476, 483234700803924187);
        check_virtual_price_does_not_decrease_from_withdraw(200951, 562411647030343734, 872268667866062695, 500184290393804507, 600511037255976943);
        check_virtual_price_does_not_decrease_from_withdraw(880362, 38065634349294880, 167902395476434399, 923036770112815414, 330819845191284386);
        check_virtual_price_does_not_decrease_from_withdraw(208431, 285552914555902126, 604551161115473579, 386228080273227023, 377149254453836984);
        check_virtual_price_does_not_decrease_from_withdraw(532262, 601883514758415475, 645656586322749747, 721435122933596732, 1142202634524633069);
        check_virtual_price_does_not_decrease_from_withdraw(213409, 243003044396641984, 1098625856779672153, 551126358976843706, 994792916950855550);
        check_virtual_price_does_not_decrease_from_withdraw(649051, 46375065272836192, 214637169074381153, 824162087187872618, 1089198751267647591);
        check_virtual_price_does_not_decrease_from_withdraw(805705, 23274168466582766, 92260013701670352, 209406169252586393, 751432186961346147);
        check_virtual_price_does_not_decrease_from_withdraw(995448, 30509949311274640, 319569767519568552, 916751374848556227, 275841786737859150);
        check_virtual_price_does_not_decrease_from_withdraw(313172, 481468700245718879, 1116967672103287145, 294319114947565573, 688383012737807066);
        check_virtual_price_does_not_decrease_from_withdraw(606000, 685507024108283005, 754466440940858221, 952215349798380830, 875038701414278317);
        check_virtual_price_does_not_decrease_from_withdraw(612912, 17154236991927219, 37892676914771826, 738848939359450208, 787232101249859700);
        check_virtual_price_does_not_decrease_from_withdraw(431473, 95468562888737934, 531998335200804491, 184761929762620170, 916520700029596229);
        check_virtual_price_does_not_decrease_from_withdraw(201531, 578549919194237326, 986389316958105159, 657661327534660660, 257000585376730152);
        check_virtual_price_does_not_decrease_from_withdraw(607719, 25173907974186544, 1050328234300001419, 1091545864486553828, 307560590149656397);
        check_virtual_price_does_not_decrease_from_withdraw(369472, 728115423128626289, 1047456031052109643, 211214073719227493, 40474896594020647);
        check_virtual_price_does_not_decrease_from_withdraw(70012, 177807147593177333, 364913133721668142, 930762280509356502, 507201461240304283);
        check_virtual_price_does_not_decrease_from_withdraw(237976, 115029402617736286, 751577109296998790, 658273801277539107, 223257426590999397);
        check_virtual_price_does_not_decrease_from_withdraw(747177, 361291610279476402, 653556473633989009, 394940792609480007, 1122568577551033754);
        check_virtual_price_does_not_decrease_from_withdraw(654736, 135275564305226208, 495180644010499032, 567878626563670908, 1098644499441024210);
        check_virtual_price_does_not_decrease_from_withdraw(319781, 307718109860598505, 341435653087257743, 980323840201895979, 60922484653385872);
        check_virtual_price_does_not_decrease_from_withdraw(731289, 7413235967931721, 12607209958938988, 281648753752916030, 1002829466270127152);
        check_virtual_price_does_not_decrease_from_withdraw(649978, 119011951063582557, 139183860362971130, 1034558514247553258, 199875000799765025);
        check_virtual_price_does_not_decrease_from_withdraw(413950, 558054104684169391, 561841712852604535, 75691477651097877, 411721533520990722);
        check_virtual_price_does_not_decrease_from_withdraw(260018, 264437591023109116, 615420831836503188, 1019376534133888856, 351155407658002099);
        check_virtual_price_does_not_decrease_from_withdraw(324026, 87996616040078615, 150717495863615751, 147308903048400001, 782015348911989158);
        check_virtual_price_does_not_decrease_from_withdraw(579245, 557464165866922411, 951190041207027601, 718518198379305236, 574652060479267839);
        check_virtual_price_does_not_decrease_from_withdraw(958169, 206147426312850050, 239960159399189755, 421464128793035543, 180567014399804610);
        check_virtual_price_does_not_decrease_from_withdraw(257276, 834066584465181913, 910493702936458109, 216434981494692701, 1003999958137802186);
        check_virtual_price_does_not_decrease_from_withdraw(759180, 59349551054280485, 402698417845031933, 5811990284509525, 189524796621894304);
    }

    #[test]
    fun test_virtual_price_does_not_decrease_from_withdraw_one() {
        check_virtual_price_does_not_decrease_from_withdraw_one(794248, 486966262337048995, 1098512304148995858, 885493441740400850, 1044329034977142354);
        check_virtual_price_does_not_decrease_from_withdraw_one(163479, 545614369201030536, 760722292380034413, 358133497348069441, 181346268861417028);
        check_virtual_price_does_not_decrease_from_withdraw_one(218906, 120636953671671237, 837177577773585699, 1003090414529448712, 606369304222421740);
        check_virtual_price_does_not_decrease_from_withdraw_one(8999, 622294706140820892, 1044507421232603944, 377584840120032814, 604725393373600962);
        check_virtual_price_does_not_decrease_from_withdraw_one(86276, 289364844463776807, 1126995418178935328, 543761561592355940, 212261723623657047);
        check_virtual_price_does_not_decrease_from_withdraw_one(507788, 15646176432169988, 1052204358308890104, 361028345242725934, 287886055182364669);
        check_virtual_price_does_not_decrease_from_withdraw_one(878017, 544178867962848395, 594327478605959507, 6829553651240717, 328732004790280391);
        check_virtual_price_does_not_decrease_from_withdraw_one(401847, 559054385404057437, 1074003125223416838, 279360739086389344, 45138334818937899);
        check_virtual_price_does_not_decrease_from_withdraw_one(72973, 539556308915243371, 555323805739763893, 721817214650345826, 81234557061448181);
        check_virtual_price_does_not_decrease_from_withdraw_one(119347, 1064642948923930524, 1151564748250246046, 1006193565110407332, 7283705712866870);
        check_virtual_price_does_not_decrease_from_withdraw_one(422011, 255431100538403044, 731428902892709737, 488299682071966392, 128240960673968804);
        check_virtual_price_does_not_decrease_from_withdraw_one(9443, 146308822649677565, 196871996762197557, 585276874873565859, 907605174976293846);
        check_virtual_price_does_not_decrease_from_withdraw_one(223146, 88746436771120699, 124179379311463265, 61610940774009814, 1075245345666705012);
        check_virtual_price_does_not_decrease_from_withdraw_one(958532, 17999830125170612, 26660985803672410, 585723126496270679, 872187044015502894);
        check_virtual_price_does_not_decrease_from_withdraw_one(244686, 3720888129162085, 39102119953562802, 961411137003926839, 111324962407173510);
        check_virtual_price_does_not_decrease_from_withdraw_one(579540, 60279190149786145, 1044126509373883328, 1049617019397845590, 874652410656127603);
        check_virtual_price_does_not_decrease_from_withdraw_one(935484, 46192850350453484, 711210842561635701, 1093470887292181788, 679772708025289199);
        check_virtual_price_does_not_decrease_from_withdraw_one(976426, 117880756977571878, 120198599085630401, 327984800945193109, 583658900185316480);
        check_virtual_price_does_not_decrease_from_withdraw_one(970794, 336755936454393965, 1045024060752559975, 944214238219965597, 1099446299508204286);
        check_virtual_price_does_not_decrease_from_withdraw_one(954252, 309413163288396584, 475306302360246823, 1139284321297512086, 1006548533395288398);
        check_virtual_price_does_not_decrease_from_withdraw_one(535025, 238582798822252210, 311095184808376574, 944291137357733670, 736359427458130940);
        check_virtual_price_does_not_decrease_from_withdraw_one(929619, 133238258445779120, 902076439238929858, 1143148135430717704, 939995404497413448);
        check_virtual_price_does_not_decrease_from_withdraw_one(289574, 377599996131518098, 1146323276815243969, 1083960007381066539, 908203295594788822);
        check_virtual_price_does_not_decrease_from_withdraw_one(610813, 91179003089548547, 784069638328155245, 1117282546661323660, 370618579328361704);
        check_virtual_price_does_not_decrease_from_withdraw_one(549502, 260978274662949629, 975810877422954361, 955941920205961340, 1107197028423900000);
        check_virtual_price_does_not_decrease_from_withdraw_one(786119, 381646401922844734, 969102827482191727, 1050963367545172457, 776121587163646411);
        check_virtual_price_does_not_decrease_from_withdraw_one(892730, 48145291884339855, 287922484572216813, 345551732082358384, 570148285325580522);
        check_virtual_price_does_not_decrease_from_withdraw_one(674908, 438443183736015529, 1147431210761120725, 477836858610333067, 1104596018720843021);
        check_virtual_price_does_not_decrease_from_withdraw_one(780538, 3866031265390007, 92280909760316939, 525343554260005116, 446711223803732307);
        check_virtual_price_does_not_decrease_from_withdraw_one(9415, 199845137263319613, 489557177340895099, 505417132641840455, 21803648441778984);
        check_virtual_price_does_not_decrease_from_withdraw_one(536158, 383439642033519750, 966761322488978933, 960756789744268341, 1065680493187380251);
        check_virtual_price_does_not_decrease_from_withdraw_one(688694, 356163872839318375, 773827303051885306, 1035146614578193407, 731886197266639304);
        check_virtual_price_does_not_decrease_from_withdraw_one(408188, 978329527010841370, 1099058521952761951, 762053884682359076, 248223005118360899);
        check_virtual_price_does_not_decrease_from_withdraw_one(927486, 185641844286272726, 1090311484889840609, 1047878581345102038, 230426413368500727);
        check_virtual_price_does_not_decrease_from_withdraw_one(865914, 941964779432876230, 1042040657795975950, 824861750142227955, 887047172355923628);
        check_virtual_price_does_not_decrease_from_withdraw_one(607600, 650386958373209103, 1108208712722667573, 1089473086837251351, 548673729836977396);
        check_virtual_price_does_not_decrease_from_withdraw_one(628890, 28947857039328831, 835420160403240791, 327485816268649302, 600206886403030243);
        check_virtual_price_does_not_decrease_from_withdraw_one(247185, 15272710413989833, 18425912428637864, 1123995718851668097, 445638434600435619);
        check_virtual_price_does_not_decrease_from_withdraw_one(605268, 820763338571266031, 879203420819019420, 1071606854136429321, 286511572563633193);
        check_virtual_price_does_not_decrease_from_withdraw_one(853211, 1042568652844318102, 1081464342305600209, 747766566946591259, 814721669798506180);
        check_virtual_price_does_not_decrease_from_withdraw_one(87722, 4994207138311095, 905276783865830904, 54585838188751622, 279986995303988980);
        check_virtual_price_does_not_decrease_from_withdraw_one(876280, 63823822927204425, 109469890066881568, 419399242638929163, 1033319210959123162);
        check_virtual_price_does_not_decrease_from_withdraw_one(646544, 389593781469874669, 904993929249124917, 252553048335249883, 933611200287211878);
        check_virtual_price_does_not_decrease_from_withdraw_one(758143, 13260591734134268, 650341644727547472, 691559673597843262, 666237590893549432);
        check_virtual_price_does_not_decrease_from_withdraw_one(847104, 262349379357360446, 534381213090812371, 909386523309264841, 42318118405210935);
        check_virtual_price_does_not_decrease_from_withdraw_one(470498, 529658288586786361, 763851873440979012, 449183334858124813, 125570480267820739);
        check_virtual_price_does_not_decrease_from_withdraw_one(604833, 363199475300000581, 385567697098894439, 974969439932400006, 518210787902602355);
        check_virtual_price_does_not_decrease_from_withdraw_one(265435, 287266334725823673, 570012612388503320, 959890818288440755, 892556017752549794);
        check_virtual_price_does_not_decrease_from_withdraw_one(84755, 986530363270413859, 1145013427507816053, 153153083366617279, 651447548815936328);
        check_virtual_price_does_not_decrease_from_withdraw_one(933765, 75583290291076512, 155189179977993956, 153066045663843824, 761129733459033877);
        check_virtual_price_does_not_decrease_from_withdraw_one(675172, 440868149862458709, 511839017883238725, 495180624635243668, 329583269803620010);
        check_virtual_price_does_not_decrease_from_withdraw_one(890028, 644312315732772943, 848076403392081431, 466814324376177492, 635935884646525224);
        check_virtual_price_does_not_decrease_from_withdraw_one(761610, 586372223212938761, 721512581010372555, 375858084543522644, 517719028729940351);
        check_virtual_price_does_not_decrease_from_withdraw_one(271352, 48593075596119818, 147833906350570990, 629887386491337652, 934216194672213635);
        check_virtual_price_does_not_decrease_from_withdraw_one(791721, 416870260970967411, 434718029228774346, 95144828318514419, 1058389958056705490);
        check_virtual_price_does_not_decrease_from_withdraw_one(953860, 522873332242640258, 653211661140707661, 528037410650171046, 779248265669296551);
        check_virtual_price_does_not_decrease_from_withdraw_one(393433, 401503231294765313, 502029282379443772, 440408847251262027, 505277399467319835);
        check_virtual_price_does_not_decrease_from_withdraw_one(521651, 61039052135917103, 1043061713540230958, 905184365941238202, 989235778411892695);
        check_virtual_price_does_not_decrease_from_withdraw_one(21877, 1086426159230416850, 1137137157232840512, 1078300371023249383, 80664347930611379);
        check_virtual_price_does_not_decrease_from_withdraw_one(447395, 42113014451399737, 112670628915303879, 917626470350283265, 111407989611128497);
        check_virtual_price_does_not_decrease_from_withdraw_one(797298, 371613349633836258, 925776123454421042, 819034315735731317, 760916245466632747);
        check_virtual_price_does_not_decrease_from_withdraw_one(915649, 105913479681984111, 253609687418470443, 30904443578229419, 1104772501059152032);
        check_virtual_price_does_not_decrease_from_withdraw_one(434841, 307291517433649573, 1116024387685029268, 772852076038931893, 910455638880450972);
        check_virtual_price_does_not_decrease_from_withdraw_one(627656, 146705347078535383, 221616671878740872, 230778915140932051, 436382389221121582);
        check_virtual_price_does_not_decrease_from_withdraw_one(548357, 168277296314942838, 169159053652666131, 1085927180585132122, 167492560362098169);
        check_virtual_price_does_not_decrease_from_withdraw_one(466619, 40086612251451675, 709799673408965701, 798227843946263149, 607269657166440010);
        check_virtual_price_does_not_decrease_from_withdraw_one(541603, 59312564943819689, 721930385933429318, 688862593144866285, 703094797139707174);
        check_virtual_price_does_not_decrease_from_withdraw_one(353679, 220332453418636229, 482548704856580628, 482020805286843581, 262605030269869926);
        check_virtual_price_does_not_decrease_from_withdraw_one(829404, 1435920841173805, 367222773226537217, 1086721730655882973, 473310024648099337);
        check_virtual_price_does_not_decrease_from_withdraw_one(547063, 26718399266190693, 561920650784417550, 234473299601911162, 387193171706652831);
        check_virtual_price_does_not_decrease_from_withdraw_one(249011, 31795837704970503, 69046449930801033, 94945365758818030, 951464629693846479);
        check_virtual_price_does_not_decrease_from_withdraw_one(402311, 27969752275129725, 88164044902403199, 849354329878296337, 576238560273655318);
        check_virtual_price_does_not_decrease_from_withdraw_one(156450, 397759852908813239, 1012951799015873920, 865253085951494000, 474560478430794409);
        check_virtual_price_does_not_decrease_from_withdraw_one(853567, 472683213876860183, 1042269419765634280, 69206818221990409, 511035104351116506);
        check_virtual_price_does_not_decrease_from_withdraw_one(468420, 93913581571364898, 119857932808926573, 799508076046836282, 805242813295705445);
        check_virtual_price_does_not_decrease_from_withdraw_one(148332, 197434881075887720, 1080836537579942388, 44882466035784836, 21718187446171970);
        check_virtual_price_does_not_decrease_from_withdraw_one(396861, 93678531861416754, 927494384200343230, 854637600388886862, 23228729692409004);
        check_virtual_price_does_not_decrease_from_withdraw_one(820200, 614047745220927439, 978124193851884482, 179024183561257316, 459606859052931964);
        check_virtual_price_does_not_decrease_from_withdraw_one(241235, 287545671960489299, 343240292252568281, 917122153047018535, 458702184767451964);
        check_virtual_price_does_not_decrease_from_withdraw_one(530020, 1104152235123861595, 1113954009229747390, 194367321559226603, 840448308436699076);
        check_virtual_price_does_not_decrease_from_withdraw_one(426073, 34248547772558523, 142654074741537250, 812548713812850536, 230212094803868346);
        check_virtual_price_does_not_decrease_from_withdraw_one(729310, 277219689568404126, 928586163980667081, 371819044269081980, 613357595000485754);
        check_virtual_price_does_not_decrease_from_withdraw_one(56855, 309078989852454542, 956283384649763613, 418590558446209567, 424808209739475040);
        check_virtual_price_does_not_decrease_from_withdraw_one(19034, 341469774168684745, 678037208173887430, 360808236172034699, 436009525423736553);
        check_virtual_price_does_not_decrease_from_withdraw_one(118829, 582782417698448081, 1054703323830090474, 37186722065267912, 1133851474257798594);
        check_virtual_price_does_not_decrease_from_withdraw_one(909044, 731931494750397933, 802305715381706898, 301171575726821561, 441789569743281360);
        check_virtual_price_does_not_decrease_from_withdraw_one(27099, 2830037946099914, 547197939551288514, 822929369903421880, 679185420463712428);
        check_virtual_price_does_not_decrease_from_withdraw_one(99836, 344762437704087672, 750674658810149393, 586465583563777738, 19522668208328113);
        check_virtual_price_does_not_decrease_from_withdraw_one(312599, 187883525718177658, 480038162568255132, 867474162702995713, 76419671395780496);
        check_virtual_price_does_not_decrease_from_withdraw_one(979780, 198397116998572820, 787803957780216321, 265137609493495429, 473065313169756157);
        check_virtual_price_does_not_decrease_from_withdraw_one(881869, 551728220113805685, 1113848614329660742, 1144463123231639341, 551200668114513898);
        check_virtual_price_does_not_decrease_from_withdraw_one(654537, 605586461952306892, 651565088161664109, 892894022878589513, 1103787198980681710);
        check_virtual_price_does_not_decrease_from_withdraw_one(230166, 30449332646039758, 47737709916993552, 206589830671458490, 757829915256770982);
        check_virtual_price_does_not_decrease_from_withdraw_one(299510, 73584994563585641, 569647260601504237, 63681185320842651, 979687952585460397);
        check_virtual_price_does_not_decrease_from_withdraw_one(918761, 58572628220537591, 72237485183538932, 368326672024636160, 124113859120505004);
        check_virtual_price_does_not_decrease_from_withdraw_one(497269, 34484896531617180, 161059035740331197, 355630113741372259, 430062446760335422);
        check_virtual_price_does_not_decrease_from_withdraw_one(408942, 466918594693360090, 766480103128312857, 203871874139637832, 609468260453368091);
        check_virtual_price_does_not_decrease_from_withdraw_one(634581, 92350275757658042, 921653242750858467, 736523654664559299, 204204818876992562);
        check_virtual_price_does_not_decrease_from_withdraw_one(298330, 470459374254083203, 1016908732024190108, 597249920626713409, 1120588100956269000);
        check_virtual_price_does_not_decrease_from_withdraw_one(997845, 12613086158856639, 483586045070831421, 793165086959982196, 1117285366241235872);
        check_virtual_price_does_not_decrease_from_withdraw_one(804425, 625425535432010792, 943613146076173485, 879303570933904891, 566140842844878681);
        check_virtual_price_does_not_decrease_from_withdraw_one(398406, 11454186179584969, 24745709490713816, 500645204473155526, 1038796468611526668);
        check_virtual_price_does_not_decrease_from_withdraw_one(505631, 500720250041602303, 714603681793401056, 307765230077071920, 873985885598341873);
        check_virtual_price_does_not_decrease_from_withdraw_one(980361, 279336374813255008, 329135160190534144, 668755946289891836, 1021452650362134100);
        check_virtual_price_does_not_decrease_from_withdraw_one(816154, 12906722931566667, 13483049207233955, 343048047505274441, 462969401501125574);
        check_virtual_price_does_not_decrease_from_withdraw_one(234240, 128571986612244624, 933823817792435835, 1126864961944980180, 665548544402486672);
        check_virtual_price_does_not_decrease_from_withdraw_one(441639, 422526778777473824, 563303605391548217, 1126430324868752932, 684865127313066325);
        check_virtual_price_does_not_decrease_from_withdraw_one(681132, 370909198183635485, 936283407452391244, 911576880191222117, 802747110185345998);
        check_virtual_price_does_not_decrease_from_withdraw_one(276938, 188615011855914735, 384671898845143189, 29345046456617450, 431584084559349139);
        check_virtual_price_does_not_decrease_from_withdraw_one(654893, 117522556190813191, 133458623967215336, 127930731603352267, 522917741000355071);
        check_virtual_price_does_not_decrease_from_withdraw_one(725853, 799574233312978077, 969473764490828170, 1069252502170887172, 367943055685360461);
        check_virtual_price_does_not_decrease_from_withdraw_one(673698, 74638643759292491, 80108614932865774, 516139922636091462, 97561391470378945);
        check_virtual_price_does_not_decrease_from_withdraw_one(964374, 632476812625136603, 710690157846071976, 337687321870186863, 1097331655102220706);
        check_virtual_price_does_not_decrease_from_withdraw_one(809645, 77007795477995902, 119492885826475940, 1005254202529251584, 778350252108977223);
        check_virtual_price_does_not_decrease_from_withdraw_one(982750, 104492980853286216, 950471175882889687, 444321401594277543, 390011625286400103);
        check_virtual_price_does_not_decrease_from_withdraw_one(868465, 192231540187625402, 238720404366988834, 564627599331563917, 712295870693295379);
        check_virtual_price_does_not_decrease_from_withdraw_one(715805, 270959831769113512, 458116403270687893, 33327236204918432, 187882794335285434);
        check_virtual_price_does_not_decrease_from_withdraw_one(355485, 226342791397199647, 663335472061186555, 496046889832805425, 1006145489339336935);
        check_virtual_price_does_not_decrease_from_withdraw_one(306089, 109383126095334463, 165651764742254545, 145150969388353295, 296972056673609000);
        check_virtual_price_does_not_decrease_from_withdraw_one(226554, 314137553889453840, 489966979222257115, 988337573340226050, 1031889455983331792);
        check_virtual_price_does_not_decrease_from_withdraw_one(118532, 558074185128687392, 671426361319710920, 294109223607597480, 261314924007421845);
        check_virtual_price_does_not_decrease_from_withdraw_one(859863, 63910681018299485, 228987944425103517, 48740247884462318, 604469812972099764);
        check_virtual_price_does_not_decrease_from_withdraw_one(678694, 71979081556486838, 133822890527330323, 1016930634800983052, 120371189740941338);
        check_virtual_price_does_not_decrease_from_withdraw_one(642342, 580403453233822768, 946782988906458633, 440102929985855277, 234390249116838159);
        check_virtual_price_does_not_decrease_from_withdraw_one(848483, 248990500106554617, 757980733648879853, 1076428993352501734, 461049480786246836);
        check_virtual_price_does_not_decrease_from_withdraw_one(531377, 3196714545279050, 1015221965277328187, 261441053730908279, 574490753689812111);
        check_virtual_price_does_not_decrease_from_withdraw_one(781680, 58013048937823120, 410961252385747096, 437384348187790677, 800380618779177348);
        check_virtual_price_does_not_decrease_from_withdraw_one(111535, 20200590669863169, 45752342442460498, 179359002811598579, 949976176937396103);
        check_virtual_price_does_not_decrease_from_withdraw_one(118022, 350664491163984749, 647372706518099916, 51936532858164077, 707557699360745557);
        check_virtual_price_does_not_decrease_from_withdraw_one(971000, 1723434956519195, 7262321649155847, 372116506129321868, 392147257763070566);
        check_virtual_price_does_not_decrease_from_withdraw_one(706556, 23268436349155307, 230547963442801170, 619183579251135267, 115246679529491057);
        check_virtual_price_does_not_decrease_from_withdraw_one(225629, 573263982837517137, 1074655972341244516, 1010745581794795270, 938789816444260705);
        check_virtual_price_does_not_decrease_from_withdraw_one(88063, 99453063210219212, 122118688547833520, 752702683625758365, 1022730507185221047);
        check_virtual_price_does_not_decrease_from_withdraw_one(824246, 81578696980771031, 185916814505211461, 1038057954736228982, 139484451250074470);
        check_virtual_price_does_not_decrease_from_withdraw_one(368860, 218803953716588717, 325621780309914783, 357167165675417167, 36502325317319729);
        check_virtual_price_does_not_decrease_from_withdraw_one(333395, 155964137390537552, 509743052347171740, 594205492161259568, 1101399790946553314);
        check_virtual_price_does_not_decrease_from_withdraw_one(690842, 18814931871145837, 34551296672509343, 156995193231421417, 1073465637970175743);
        check_virtual_price_does_not_decrease_from_withdraw_one(288409, 460941259582655387, 986827954683982520, 182400236088506457, 142203333754429079);
        check_virtual_price_does_not_decrease_from_withdraw_one(960320, 854851740180808154, 956382213319453757, 325064692238193911, 84709188662641056);
        check_virtual_price_does_not_decrease_from_withdraw_one(875856, 170031439808538169, 430142991686488890, 398806893113029406, 151569067734520567);
        check_virtual_price_does_not_decrease_from_withdraw_one(195716, 252887222688970314, 1035444213389531398, 1006018758170856226, 1030133422022223384);
        check_virtual_price_does_not_decrease_from_withdraw_one(385185, 166721007448850295, 508004723689371746, 407613564639896230, 933416886408539333);
        check_virtual_price_does_not_decrease_from_withdraw_one(224596, 182985593958335674, 281464255150720584, 349511739545127594, 600104844427683584);
        check_virtual_price_does_not_decrease_from_withdraw_one(624951, 511572043269618065, 688198451703345616, 61327692602556801, 844198585354729814);
        check_virtual_price_does_not_decrease_from_withdraw_one(876953, 285725399015057465, 449952375847566802, 263834725632287735, 271953268258700681);
        check_virtual_price_does_not_decrease_from_withdraw_one(994486, 43248974131461134, 68001913869929684, 102619619125805421, 355571238231327982);
        check_virtual_price_does_not_decrease_from_withdraw_one(573373, 842615483972983087, 1094765110179402503, 1068445265533238879, 326670021994222214);
        check_virtual_price_does_not_decrease_from_withdraw_one(610740, 349262996250420205, 727136546434355782, 1003950234521163383, 155667090547035721);
        check_virtual_price_does_not_decrease_from_withdraw_one(147377, 112011275017625442, 206108620312696258, 862180139271766770, 1041455854736684533);
        check_virtual_price_does_not_decrease_from_withdraw_one(651572, 217401727451620357, 424654643593638429, 1093513255964805062, 100736900296281596);
        check_virtual_price_does_not_decrease_from_withdraw_one(450122, 52620388003906903, 347766257879641847, 376158455013584273, 429908296723520017);
        check_virtual_price_does_not_decrease_from_withdraw_one(559515, 471221380805123915, 485311521329269227, 470718371671399133, 961839748821840134);
        check_virtual_price_does_not_decrease_from_withdraw_one(688416, 471206384432744755, 811010797897747739, 435098760004745091, 170659901409959908);
        check_virtual_price_does_not_decrease_from_withdraw_one(394475, 236582583928488106, 587764416158390786, 990578097843669169, 383451453139616930);
        check_virtual_price_does_not_decrease_from_withdraw_one(669948, 295962195450312683, 528906855043476473, 579226935507135980, 242137863817360450);
        check_virtual_price_does_not_decrease_from_withdraw_one(97198, 635865632634755699, 817375623446733631, 931499974814324131, 1041623598734820);
        check_virtual_price_does_not_decrease_from_withdraw_one(284694, 58639710520615039, 339517341333928695, 303226138119459470, 275986662805430648);
        check_virtual_price_does_not_decrease_from_withdraw_one(410102, 116195371517320234, 493152616571349297, 1001225984988922937, 582262881579546614);
        check_virtual_price_does_not_decrease_from_withdraw_one(674344, 340750655219670795, 985503835370430022, 935488430243026456, 556640669848430321);
        check_virtual_price_does_not_decrease_from_withdraw_one(533212, 462017529002409830, 646459423870962217, 260619334574578043, 93772344560692330);
        check_virtual_price_does_not_decrease_from_withdraw_one(887192, 77490928249679669, 84863942199177325, 966815018002358488, 200034602420043298);
        check_virtual_price_does_not_decrease_from_withdraw_one(315389, 4107665901543926, 10124191341317269, 674417646789185415, 940275595757469718);
        check_virtual_price_does_not_decrease_from_withdraw_one(801330, 533774987708256089, 1041112817621664159, 937621244177316790, 474209191588262120);
        check_virtual_price_does_not_decrease_from_withdraw_one(177457, 30157841005777899, 956018887854440135, 72877219871348424, 1087653099040239116);
        check_virtual_price_does_not_decrease_from_withdraw_one(279345, 53972178615458755, 127789612085682522, 203672139619626720, 383131482638040083);
        check_virtual_price_does_not_decrease_from_withdraw_one(129584, 863551275042502138, 964885067292809669, 968366307157384986, 1137172229202083924);
        check_virtual_price_does_not_decrease_from_withdraw_one(809465, 643901660139336814, 900262316095973134, 859214454733793321, 655008437472268212);
        check_virtual_price_does_not_decrease_from_withdraw_one(110224, 130881253432995743, 426547623427981728, 384040296884026007, 409065141145670359);
        check_virtual_price_does_not_decrease_from_withdraw_one(825755, 1716970355569202, 522036821807663092, 1141801048153052215, 542542325276031354);
        check_virtual_price_does_not_decrease_from_withdraw_one(792545, 738453404714436921, 1011677510386132790, 9152342200576150, 991286353181054323);
        check_virtual_price_does_not_decrease_from_withdraw_one(857028, 45401321122654439, 115158233773116446, 144701067855016115, 85251045716285951);
        check_virtual_price_does_not_decrease_from_withdraw_one(355879, 412144935078940447, 563668582953945872, 840729990893303265, 307488597873804517);
        check_virtual_price_does_not_decrease_from_withdraw_one(234489, 487474200734633594, 644772319126245289, 687205172903498229, 1077367272978769184);
        check_virtual_price_does_not_decrease_from_withdraw_one(606750, 209156495113615357, 590399677003944915, 915023704158929143, 894542645285189354);
        check_virtual_price_does_not_decrease_from_withdraw_one(222657, 207476609112803349, 279006718976664187, 30238538963801031, 429135133338727680);
        check_virtual_price_does_not_decrease_from_withdraw_one(57426, 61270242704235817, 79384597670697270, 179878930801108121, 933326415225680477);
        check_virtual_price_does_not_decrease_from_withdraw_one(285038, 401772765993332269, 547238852410866339, 326967081796168479, 276607564044822409);
        check_virtual_price_does_not_decrease_from_withdraw_one(550462, 106513538359163055, 159341629156651618, 489598540271964101, 1150387769412574737);
        check_virtual_price_does_not_decrease_from_withdraw_one(759207, 353475326301424740, 735826042339682744, 540426655520178634, 444054491372952349);
        check_virtual_price_does_not_decrease_from_withdraw_one(744984, 235104034011264704, 674383744874199976, 523543048251234168, 308732801645763276);
        check_virtual_price_does_not_decrease_from_withdraw_one(639294, 177492546883702680, 285634821849867480, 472259916172455219, 1039604162862390564);
        check_virtual_price_does_not_decrease_from_withdraw_one(277685, 19026024002633766, 26906101997715565, 124895219638663475, 109599448377334922);
        check_virtual_price_does_not_decrease_from_withdraw_one(887516, 252519022805618304, 980941329097659345, 321779823578675966, 645172955883958439);
        check_virtual_price_does_not_decrease_from_withdraw_one(969908, 239204697113365209, 239248797830200129, 1035449535544737167, 550731280458992023);
        check_virtual_price_does_not_decrease_from_withdraw_one(944947, 980936266350281340, 1020938027711866778, 1022275793962429441, 734420544856942271);
        check_virtual_price_does_not_decrease_from_withdraw_one(891924, 467885410354446598, 1104719227933116257, 273219607803412776, 980393445782227825);
        check_virtual_price_does_not_decrease_from_withdraw_one(800684, 909161596833336856, 1003545714549452300, 611440974753969026, 263771174559967803);
        check_virtual_price_does_not_decrease_from_withdraw_one(832824, 130483766245568051, 347838965471389070, 439647561920591498, 51597852237168962);
        check_virtual_price_does_not_decrease_from_withdraw_one(809073, 246534420788181671, 266805165733377830, 650325861468040681, 212843863446988800);
        check_virtual_price_does_not_decrease_from_withdraw_one(171816, 542677762999628461, 756016545351600193, 645809283397773476, 210703052527618685);
        check_virtual_price_does_not_decrease_from_withdraw_one(864361, 472950018443145288, 601446869447823635, 769691214757858956, 349143326242968526);
        check_virtual_price_does_not_decrease_from_withdraw_one(323477, 503971786604901508, 520777485978130402, 959749964497203923, 458777718515045924);
        check_virtual_price_does_not_decrease_from_withdraw_one(909335, 130426817219955180, 226187525588329753, 381081551606925283, 788060139238351296);
        check_virtual_price_does_not_decrease_from_withdraw_one(826503, 880847115864813333, 897546938810343681, 823332151682876861, 195266383384203626);
        check_virtual_price_does_not_decrease_from_withdraw_one(401876, 334458950798363202, 345153999969057584, 84736789984076928, 1016140259921529917);
        check_virtual_price_does_not_decrease_from_withdraw_one(702257, 367151973751029623, 561845238666089664, 911338736911851394, 1149836401413017083);
        check_virtual_price_does_not_decrease_from_withdraw_one(888048, 307425631890583394, 372547276022724934, 580434362885662647, 529226519389943646);
        check_virtual_price_does_not_decrease_from_withdraw_one(36990, 121319218631626366, 165961003396936528, 517518860715424098, 72988944286351935);
        check_virtual_price_does_not_decrease_from_withdraw_one(682016, 297727646337937907, 308683157532333588, 1096597316834915297, 298742416546920205);
        check_virtual_price_does_not_decrease_from_withdraw_one(838052, 35751670224982, 75851927923019562, 613480826330277913, 275258178381124571);
        check_virtual_price_does_not_decrease_from_withdraw_one(314253, 12073019474044997, 187388570746554489, 158967361426963576, 711704674111733654);
        check_virtual_price_does_not_decrease_from_withdraw_one(662861, 353615624614203896, 450930499294247636, 856330639349645020, 1024195175512622204);
        check_virtual_price_does_not_decrease_from_withdraw_one(628409, 39877067871926410, 689661482365934605, 716261772926206931, 1061486961356577038);
        check_virtual_price_does_not_decrease_from_withdraw_one(698161, 32677980436106608, 169423327004802666, 345319404597269059, 423482187907414952);
        check_virtual_price_does_not_decrease_from_withdraw_one(253635, 279739934085958485, 1070299942519043052, 1141896648641563366, 1107660782878937137);
        check_virtual_price_does_not_decrease_from_withdraw_one(635507, 99590082115961838, 116600277899004986, 494290683600698102, 126346941184448433);
        check_virtual_price_does_not_decrease_from_withdraw_one(369747, 468611090275438349, 731949235490350193, 969796904760667375, 675871979466601113);
        check_virtual_price_does_not_decrease_from_withdraw_one(203359, 304963625084207692, 821581694471194072, 776823037627459563, 809422890696469154);
        check_virtual_price_does_not_decrease_from_withdraw_one(6247, 702200257644210618, 793096727204294771, 432975073310946303, 254591884085831221);
        check_virtual_price_does_not_decrease_from_withdraw_one(411859, 28775250360119489, 274703538912479579, 689716691672763998, 1096842705633197051);
        check_virtual_price_does_not_decrease_from_withdraw_one(618682, 55884179857783530, 893896791590126185, 722301422905116549, 501494936562580035);
        check_virtual_price_does_not_decrease_from_withdraw_one(85561, 129458922979098261, 233233145732821676, 398682291188069567, 549138133628690546);
        check_virtual_price_does_not_decrease_from_withdraw_one(697267, 123036622273712695, 129197502023844576, 864164384653341216, 837691202990091380);
        check_virtual_price_does_not_decrease_from_withdraw_one(151222, 148370833202464145, 328870011053322145, 380667465749381859, 328366814384519091);
        check_virtual_price_does_not_decrease_from_withdraw_one(412813, 78207095650174067, 225912682309236553, 475477408934681799, 441965816040179515);
        check_virtual_price_does_not_decrease_from_withdraw_one(285281, 102837586823290395, 822795145851027417, 188144557352875314, 868768618321754055);
        check_virtual_price_does_not_decrease_from_withdraw_one(511559, 178794423218936708, 289508941594364219, 339784330216462220, 56498096487016652);
        check_virtual_price_does_not_decrease_from_withdraw_one(224012, 97729142278922089, 1130476731980491123, 263250324289795248, 13988985714697327);
        check_virtual_price_does_not_decrease_from_withdraw_one(133771, 65251216677049359, 643785287917212191, 817637218926118031, 72088259402216717);
        check_virtual_price_does_not_decrease_from_withdraw_one(737900, 32787763984905064, 71341346355632763, 67370978315395762, 1784674346713526);
        check_virtual_price_does_not_decrease_from_withdraw_one(891242, 24300478202234480, 410163276674958270, 158172628994788526, 942863412055803510);
        check_virtual_price_does_not_decrease_from_withdraw_one(552527, 32567484349769521, 33530445623304094, 721426716537271102, 783651756811574014);
        check_virtual_price_does_not_decrease_from_withdraw_one(109723, 6067985593752677, 56054125664028203, 45471148660444870, 361068312475759864);
        check_virtual_price_does_not_decrease_from_withdraw_one(403782, 109213388510314582, 532535367606554041, 142454162596535952, 1105965199321684480);
        check_virtual_price_does_not_decrease_from_withdraw_one(791581, 256431627625950690, 488531806630617846, 158172596653879171, 216166898463933420);
        check_virtual_price_does_not_decrease_from_withdraw_one(894599, 1029268327395718615, 1067820273411635097, 407193545832094698, 279984273040891725);
        check_virtual_price_does_not_decrease_from_withdraw_one(844668, 48776899595112315, 517674655138435717, 438634226040130341, 993328624735509689);
        check_virtual_price_does_not_decrease_from_withdraw_one(760365, 162320222188781838, 451321279001357754, 251176368918663879, 1150025792945421778);
        check_virtual_price_does_not_decrease_from_withdraw_one(216280, 75478495262594596, 88573995193163253, 766823915502715949, 936921406028593021);
        check_virtual_price_does_not_decrease_from_withdraw_one(672885, 328680518201466500, 368039048429365901, 425138307439378487, 46180847790281481);
        check_virtual_price_does_not_decrease_from_withdraw_one(120457, 843665044411941492, 1026978990026653230, 423129923824769906, 500573134136056233);
        check_virtual_price_does_not_decrease_from_withdraw_one(237009, 134466032489492948, 397237660599661876, 330566483974430050, 1056035931087723538);
        check_virtual_price_does_not_decrease_from_withdraw_one(460652, 778560229104994778, 1060093120760261457, 579342281217043129, 665437980985925963);
        check_virtual_price_does_not_decrease_from_withdraw_one(530660, 225409777190334811, 1084745662330841379, 902753240648541967, 285122407468582425);
        check_virtual_price_does_not_decrease_from_withdraw_one(346283, 335974969700130491, 923714558662672738, 454409852610837134, 177794867996682348);
        check_virtual_price_does_not_decrease_from_withdraw_one(148705, 264777850692032293, 897109663457260129, 198209142521287907, 745959153813520403);
        check_virtual_price_does_not_decrease_from_withdraw_one(879926, 95701580033911830, 525325212197587353, 303215454902919523, 395830885404033072);
        check_virtual_price_does_not_decrease_from_withdraw_one(2108, 552698788751049412, 640180929480153387, 792876800975053587, 172851063196858453);
        check_virtual_price_does_not_decrease_from_withdraw_one(901777, 33884268952542346, 98495153306871998, 270933037163049739, 564475910190257248);
        check_virtual_price_does_not_decrease_from_withdraw_one(721975, 66783195787984516, 288351504689737972, 222406620130691235, 741773735136129707);
        check_virtual_price_does_not_decrease_from_withdraw_one(778573, 856954150572309541, 1003737329647025163, 927371959563873029, 88707347049303428);
        check_virtual_price_does_not_decrease_from_withdraw_one(459902, 421572662641065759, 513160507339832014, 2092131277214450, 1837564530481328);
        check_virtual_price_does_not_decrease_from_withdraw_one(135419, 115949472807255842, 434537769286273879, 557210024524858684, 251402648224401013);
        check_virtual_price_does_not_decrease_from_withdraw_one(666554, 140474893812790013, 831564115216218195, 122022916523050539, 897925772444283128);
        check_virtual_price_does_not_decrease_from_withdraw_one(755378, 238928219140619594, 354054975198996611, 667884610068086549, 651263863688489733);
        check_virtual_price_does_not_decrease_from_withdraw_one(874975, 565626978676175607, 969552201635887887, 356106415237983335, 761811537118107638);
        check_virtual_price_does_not_decrease_from_withdraw_one(19350, 272623585968746555, 341025377672987886, 823680746171852168, 186102635698482744);
        check_virtual_price_does_not_decrease_from_withdraw_one(993776, 284055221102333528, 670309491114736354, 898544704961269792, 704598828059443829);
        check_virtual_price_does_not_decrease_from_withdraw_one(853478, 11366532194080148, 29103335815430994, 788840914012877134, 107232816908341970);
        check_virtual_price_does_not_decrease_from_withdraw_one(274800, 795384847885108296, 801813620113285429, 313709669537038434, 1020180958541678527);
        check_virtual_price_does_not_decrease_from_withdraw_one(991906, 182759364794780202, 483093174915608246, 303055664249743123, 109486993135491422);
        check_virtual_price_does_not_decrease_from_withdraw_one(548503, 744913827396713448, 1044365890737663134, 322860312059315093, 624145086397990582);
        check_virtual_price_does_not_decrease_from_withdraw_one(219580, 1033337699564208785, 1088186457519284795, 931169310060315637, 267306980969606487);
        check_virtual_price_does_not_decrease_from_withdraw_one(158561, 218175292496718441, 402344825510597903, 471631961670153498, 345306392522222267);
        check_virtual_price_does_not_decrease_from_withdraw_one(115178, 282973574289675784, 342281680470130538, 947045155361658495, 229687690079072883);
        check_virtual_price_does_not_decrease_from_withdraw_one(790449, 86048827669803405, 194469027372617031, 88740790050503612, 892301011060022720);
    }
}