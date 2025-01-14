#[lint_allow(self_transfer)]
module razor::RazorSwapPool {
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Supply, Balance};
    use sui::transfer;
    use sui::math;
    use sui::tx_context::{Self, TxContext};
    use std::type_name;
    use std::ascii::String;
    use std::vector;
    use sui::event;
    use sui::dynamic_object_field as ofield;
    use sui::clock::{Self, Clock};
    use razor::RazorPoolLibrary::{quote, sqrt, get_amount_out, get_amount_in, compare, is_overflow_mul, overflow_add};
    use razor::uq64x64;
    // use std::debug;

    /// When contract error
    const ERR_INTERNAL_ERROR: u64 = 102;
    /// When user is not admin
    const ERR_FORBIDDEN: u64 = 103;
    /// When not enough amount for pool
    const ERR_INSUFFICIENT_AMOUNT: u64 = 104;
    /// When not enough liquidity minted
    const ERR_INSUFFICIENT_LIQUIDITY_MINT: u64 = 106;
    /// When not enough X amount
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 108;
    /// When not enough Y amount
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 109;
    /// When not enough input amount
    const ERR_INSUFFICIENT_INPUT_AMOUNT: u64 = 110;
    /// When not enough output amount
    const ERR_INSUFFICIENT_OUTPUT_AMOUNT: u64 = 111;
    /// When contract K error
    const ERR_K_ERROR: u64 = 112;
    /// When already exists on account
    const ERR_PAIR_ALREADY_EXIST: u64 = 115;
    /// When not exists on account
    const ERR_PAIR_NOT_EXIST: u64 = 116;
    /// When error loan amount
    const ERR_LOAN_ERROR: u64 = 117;
    /// When contract is not reentrant
    const ERR_LOCK_ERROR: u64 = 118;
    /// When pair has wrong ordering
    const ERR_PAIR_ORDER_ERROR: u64 = 119;
    /// When contract is paused
    const ERR_PAUSABLE_ERROR: u64 = 120;
    /// When input value not satisfied
    const ERR_INPUT_VALUE: u64 = 121;

    const MINIMUM_LIQUIDITY: u64 = 1000;

    struct LPCoin<phantom X, phantom Y> has drop {}

    struct LiquidityPool<phantom X, phantom Y> has key, store {
        id: UID,
        coin_x_reserve: Balance<X>,
        coin_y_reserve: Balance<Y>,
        lp_coin_reserve: Balance<LPCoin<X, Y>>,
        lp_supply: Supply<LPCoin<X, Y>>,
        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        k_last: u128,
        locked: bool,
    }

    // global config
    struct AdminData has store, copy, drop {
        dao_fee_to: address,
        admin_address: address,
        dao_fee: u64,           // 1/(dao_fee+1) comes to dao_fee_to if dao_fee_on
        swap_fee: u64,          // BP, swap_fee * 1/10000
        dao_fee_on: bool,       // default: true
        is_pause: bool,         // pause swap
    }

    /// LiquidityPool is dynamically added to this
    struct LiquidityPools has key {
        id: UID,
        admin_data: AdminData,
        pair_info: PairInfo
    }

    /// events
    struct PairMeta has drop, store, copy {
        coin_x: String,
        coin_y: String,
    }

    /// pair list
    struct PairInfo has store, copy, drop {
        pair_list: vector<PairMeta>,
    }

    struct PairCreatedEvent<phantom X, phantom Y> has drop, copy {
        meta: PairMeta,
    }

    struct MintEvent<phantom X, phantom Y> has drop, copy {
        amount_x: u64,
        amount_y: u64,
        liquidity: u64,
    }

    struct SwapEvent<phantom X, phantom Y> has drop, copy {
        amount_x_in: u64,
        amount_y_in: u64,
        amount_x_out: u64,
        amount_y_out: u64,
    }

    struct SyncEvent<phantom X, phantom Y> has drop, copy {
        reserve_x: u64,
        reserve_y: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
    }

    struct FlashSwapEvent<phantom X, phantom Y> has drop, copy {
        loan_coin_x: u64,
        loan_coin_y: u64,
        repay_coin_x: u64,
        repay_coin_y: u64,
    }

    /// no copy, no drop
    struct FlashSwap<phantom X, phantom Y> {
        loan_coin_x: u64,
        loan_coin_y: u64
    }

    /// To publish a new Pool one has to create a type which will mark LPCoins.
    fun init(ctx: &mut TxContext) {
        transfer::share_object(LiquidityPools {
            id: object::new(ctx),
            admin_data: AdminData {
                dao_fee_to: @deployer,
                admin_address: @deployer,
                dao_fee: 5,
                swap_fee: 30,
                dao_fee_on: true,
                is_pause: false,
            },
            pair_info: PairInfo {
                pair_list: vector::empty(),
            }
        });
    }

    public fun get_lp_name<X, Y>(): String {
        type_name::into_string(type_name::get<LPCoin<X, Y>>())
    }

    /// get reserves size
    /// always return (X_reserve, Y_reserve)
    public fun get_reserves_size<X, Y>(pool: &LiquidityPool<X, Y>): (u64, u64) {
        (balance::value(&pool.coin_x_reserve), balance::value(&pool.coin_y_reserve))
    }

    /// get amounts out, 1 pair
    /// X in and Y out
    public fun get_amounts_out<X, Y>(
        lps: &mut LiquidityPools,
        amount_in: u64,
    ): u64 {
        if (compare<X, Y>()) {
            let (pool, admin_data) = get_pool<X, Y>(lps);
            let (reserve_in, reserve_out) = get_reserves_size<X, Y>(pool);
            get_amount_out(amount_in, reserve_in, reserve_out, admin_data.swap_fee)
        } else {
            let (pool, admin_data) = get_pool<Y, X>(lps);
            let (reserve_out, reserve_in) = get_reserves_size<Y, X>(pool);
            get_amount_out(amount_in, reserve_in, reserve_out, admin_data.swap_fee)
        }
    }

    /// get amounts in, 1 pair
    /// X in and Y out
    public fun get_amounts_in<X, Y>(
        lps: &mut LiquidityPools,
        amount_out: u64,
    ): u64 {
        if (compare<X, Y>()) {
            let (pool, admin_data) = get_pool<X, Y>(lps);
            let (reserve_in, reserve_out) = get_reserves_size<X, Y>(pool);
            get_amount_in(amount_out, reserve_in, reserve_out, admin_data.swap_fee)
        } else {
            let (pool, admin_data) = get_pool<Y, X>(lps);
            let (reserve_out, reserve_in) = get_reserves_size<Y, X>(pool);
            get_amount_in(amount_out, reserve_in, reserve_out, admin_data.swap_fee)
        }
    }

    /// get amounts in, 2 pairs
    /// X in and Z out
    public fun get_amounts_in_2_pair<X, Y, Z> (
        lps: &mut LiquidityPools,
        amount_out: u64,
    ): u64 {
        let (amount_mid, amount_in);
        {
            if (compare<Y, Z>()) {
                let (pool, admin_data) = get_pool<Y, Z>(lps);
                let (reserve_in, reserve_out) = get_reserves_size<Y, Z>(pool);
                amount_mid = get_amount_in(amount_out, reserve_in, reserve_out, admin_data.swap_fee);
            } else {
                let (pool, admin_data) = get_pool<Z, Y>(lps);
                let (reserve_out, reserve_in) = get_reserves_size<Z, Y>(pool);
                amount_mid = get_amount_in(amount_out, reserve_in, reserve_out, admin_data.swap_fee);
            };
        };
        {
            if (compare<X, Y>()) {
                let (pool, admin_data) = get_pool<X, Y>(lps);
                let (reserve_in, reserve_out) = get_reserves_size<X, Y>(pool);
                amount_in = get_amount_in(amount_mid, reserve_in, reserve_out, admin_data.swap_fee);
            } else {
                let (pool, admin_data) = get_pool<Y, X>(lps);
                let (reserve_out, reserve_in) = get_reserves_size<Y, X>(pool);
                amount_in = get_amount_in(amount_mid, reserve_in, reserve_out, admin_data.swap_fee);
            };
        };
        amount_in
    }

    /// return remaining coin.
    public fun return_remaining_coin<X>(
        coin: Coin<X>,
        ctx: &mut TxContext,
    ) {
        if (coin::value(&coin) == 0) {
            coin::destroy_zero(coin);
        } else {
            transfer::public_transfer(coin, tx_context::sender(ctx));
        };
    }

    /// Calculate optimal amounts of coins to add
    public fun calc_optimal_coin_values<X, Y>(
        lps: &mut LiquidityPools,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64
    ): (u64, u64) {
        let (pool, _) = get_pool<X, Y>(lps);
        let (reserve_x, reserve_y) = get_reserves_size(pool);
        if (reserve_x == 0 && reserve_y == 0) {
            (amount_x_desired, amount_y_desired)
        } else {
            let amount_y_optimal = quote(amount_x_desired, reserve_x, reserve_y);
            if (amount_y_optimal <= amount_y_desired) {
                assert!(amount_y_optimal >= amount_y_min, ERR_INSUFFICIENT_Y_AMOUNT);
                (amount_x_desired, amount_y_optimal)
            } else {
                let amount_x_optimal = quote(amount_y_desired, reserve_y, reserve_x);
                assert!(amount_x_optimal <= amount_x_desired, ERR_INTERNAL_ERROR);
                assert!(amount_x_optimal >= amount_x_min, ERR_INSUFFICIENT_X_AMOUNT);
                (amount_x_optimal, amount_y_desired)
            }
        }
    }

    public fun check_pair_exist<X, Y>(
        lps: &LiquidityPools,
    ): bool {
        ofield::exists_<String>(&lps.id, get_lp_name<X, Y>())
    }

    /// get pool
    public fun get_pool<X, Y>(
        lps: &mut LiquidityPools,
    ): (&mut LiquidityPool<X, Y>, AdminData) {
        let pool = ofield::borrow_mut<String, LiquidityPool<X, Y>>(
            &mut lps.id, get_lp_name<X, Y>()
        );
        (pool, lps.admin_data)
    }

    /// create pair function
    /// require X < Y
    public fun create_pair<X, Y>(
        lps: &mut LiquidityPools,
        ctx: &mut TxContext,
    ) {
        assert!(compare<X, Y>(), ERR_PAIR_ORDER_ERROR);
        assert!(!check_pair_exist<X, Y>(lps), ERR_PAIR_ALREADY_EXIST);
        assert_not_paused(lps);
        let lp = LiquidityPool<X, Y> {
            id: object::new(ctx),
            coin_x_reserve: balance::zero<X>(),
            coin_y_reserve: balance::zero<Y>(),
            lp_coin_reserve: balance::zero(),
            lp_supply: balance::create_supply(LPCoin<X, Y> {}),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            k_last: 0,
            locked: false,
        };
        ofield::add(&mut lps.id, get_lp_name<X, Y>(), lp);
        let pair_meta = PairMeta {
            coin_x: type_name::into_string(type_name::get<X>()),
            coin_y: type_name::into_string(type_name::get<Y>()),
        };
        vector::push_back(&mut lps.pair_info.pair_list, pair_meta);
        // event
        event::emit(PairCreatedEvent<X, Y> {
            meta: pair_meta,
        });
    }

    /// add liqudity entry function
    /// require X < Y
    public entry fun add_liquidity_entry<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coin_x_origin: Coin<X>,
        coin_y_origin: Coin<Y>,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        ctx: &mut TxContext,
    ) {
        // check pair exists first
        if (!check_pair_exist<X, Y>(lps)) {
            create_pair<X, Y>(lps, ctx);
        };
        // add lp
        let lp_coins = add_liquidity<X, Y>(
            lps,
            clock,
            coin_x_origin,
            coin_y_origin,
            amount_x_desired,
            amount_y_desired,
            amount_x_min,
            amount_y_min,
            ctx,
        );
        transfer::public_transfer(lp_coins, tx_context::sender(ctx));
    }

    /// remove liqudity entry function
    /// require X < Y
    public entry fun remove_liquidity_entry<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        liquidity: Coin<LPCoin<X, Y>>,
        liquidity_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        ctx: &mut TxContext,
    ) {
        let (coin_x, coin_y) = remove_liquidity<X, Y>(
            lps,
            clock,
            liquidity,
            liquidity_desired,
            amount_x_min,
            amount_y_min,
            ctx,
        );
        transfer::public_transfer(coin_x, tx_context::sender(ctx));
        transfer::public_transfer(coin_y, tx_context::sender(ctx));
    }

    /// add liqudity
    /// require X < Y
    public fun add_liquidity<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coin_x_origin: Coin<X>,
        coin_y_origin: Coin<Y>,
        amount_x_desired: u64,
        amount_y_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        ctx: &mut TxContext,
    ): Coin<LPCoin<X, Y>> {
        let amt_x = coin::value(&coin_x_origin);
        let amt_y = coin::value(&coin_y_origin);

        assert!(amt_x >= amount_x_desired
            && amount_x_desired >= amount_x_min
            && amount_x_min > 0,
            ERR_INSUFFICIENT_X_AMOUNT);
        assert!(amt_y >= amount_y_desired
            && amount_y_desired >= amount_y_min
            && amount_y_min > 0,
            ERR_INSUFFICIENT_Y_AMOUNT);

        let (amount_x, amount_y) =
            calc_optimal_coin_values<X, Y>(lps, amount_x_desired, amount_y_desired, amount_x_min, amount_y_min);
        let coin_x = coin::split(&mut coin_x_origin, amount_x, ctx);
        let coin_y = coin::split(&mut coin_y_origin, amount_y, ctx);
        let lp_balance = mint<X, Y>(lps, clock, coin::into_balance<X>(coin_x), coin::into_balance<Y>(coin_y));
        let lp_coins = coin::from_balance<LPCoin<X, Y>>(lp_balance, ctx);
        return_remaining_coin(coin_x_origin, ctx);
        return_remaining_coin(coin_y_origin, ctx);
        lp_coins
    }

    /// remove liqudity
    /// require X < Y
    public fun remove_liquidity<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        liquidity: Coin<LPCoin<X, Y>>,
        liquidity_desired: u64,
        amount_x_min: u64,
        amount_y_min: u64,
        ctx: &mut TxContext,
    ): (Coin<X>, Coin<Y>) {
        let amt_lp = coin::value(&liquidity);
        assert!(amt_lp >= liquidity_desired, ERR_INSUFFICIENT_INPUT_AMOUNT);
        let coin_lp = coin::split(&mut liquidity, liquidity_desired, ctx);
        let (x_balance, y_balance) = burn<X, Y>(lps, clock, coin::into_balance(coin_lp));
        let x_out = coin::from_balance(x_balance, ctx);
        let y_out = coin::from_balance(y_balance, ctx);
        assert!(coin::value(&x_out) >= amount_x_min, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(coin::value(&y_out) >= amount_y_min, ERR_INSUFFICIENT_Y_AMOUNT);
        return_remaining_coin(liquidity, ctx);
        (x_out, y_out)
    }

    /// entry, swap from exact X to Y
    /// no require for X Y order
    public entry fun swap_exact_coins_for_coins_entry<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_in_origin: Coin<X>,
        amount_in: u64,
        amount_out_min: u64,
        ctx: &mut TxContext,
    ) {
        if (compare<X, Y>()) {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            let (zero, coins_out) = swap_coins_for_coins<X, Y>(lps, clock, coins_in, coin::zero(ctx), ctx);
            coin::destroy_zero(zero);
            assert!(coin::value(&coins_out) >= amount_out_min, ERR_INSUFFICIENT_OUTPUT_AMOUNT);
            return_remaining_coin(coins_in_origin, ctx);
            transfer::public_transfer(coins_out, tx_context::sender(ctx));
        } else {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            let (coins_out, zero) = swap_coins_for_coins<Y, X>(lps, clock, coin::zero(ctx), coins_in, ctx);
            coin::destroy_zero(zero);
            assert!(coin::value(&coins_out) >= amount_out_min, ERR_INSUFFICIENT_OUTPUT_AMOUNT);
            return_remaining_coin(coins_in_origin, ctx);
            transfer::public_transfer(coins_out, tx_context::sender(ctx));
        }
    }

    /// entry, swap from exact X to Y to Z
    public entry fun swap_exact_coins_for_coins_2_pair_entry<X, Y, Z>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_in_origin: Coin<X>,
        amount_in: u64,
        amount_out_min: u64,
        ctx: &mut TxContext,
    ) {
        let (zeroX, zeroY, coins_mid, coins_out);
        if (compare<X, Y>()) {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            (zeroX, coins_mid) = swap_coins_for_coins<X, Y>(lps, clock, coins_in, coin::zero(ctx), ctx);
            coin::destroy_zero(zeroX);
            return_remaining_coin(coins_in_origin, ctx);
        } else {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            (coins_mid, zeroX) = swap_coins_for_coins<Y, X>(lps, clock, coin::zero(ctx), coins_in, ctx);
            coin::destroy_zero(zeroX);
            return_remaining_coin(coins_in_origin, ctx);
        };
        if (compare<Y, Z>()) {
            (zeroY, coins_out) = swap_coins_for_coins<Y, Z>(lps, clock, coins_mid, coin::zero(ctx), ctx);
            coin::destroy_zero(zeroY);
            assert!(coin::value(&coins_out) >= amount_out_min, ERR_INSUFFICIENT_OUTPUT_AMOUNT);
        } else {
            (coins_out, zeroY) = swap_coins_for_coins<Z, Y>(lps, clock, coin::zero(ctx), coins_mid, ctx);
            coin::destroy_zero(zeroY);
            assert!(coin::value(&coins_out) >= amount_out_min, ERR_INSUFFICIENT_OUTPUT_AMOUNT);
        };
        transfer::public_transfer(coins_out, tx_context::sender(ctx));
    }

    /// entry, swap from X to exact Y
    /// no require for X Y order
    public entry fun swap_coins_for_exact_coins_entry<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_in_origin: Coin<X>,
        amount_out: u64,
        amount_in_max: u64,
        ctx: &mut TxContext,
    ) {
        let amount_in = get_amounts_in<X, Y>(lps, amount_out);
        assert!(amount_in <= amount_in_max, ERR_INSUFFICIENT_INPUT_AMOUNT);
        let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
        if (compare<X, Y>()) {
            let (zero, coins_out) = swap_coins_for_coins<X, Y>(lps, clock, coins_in, coin::zero(ctx), ctx);
            coin::destroy_zero(zero);
            return_remaining_coin(coins_in_origin, ctx);
            transfer::public_transfer(coins_out, tx_context::sender(ctx));
        } else {
            let (coins_out, zero) = swap_coins_for_coins<Y, X>(lps, clock, coin::zero(ctx), coins_in, ctx);
            coin::destroy_zero(zero);
            return_remaining_coin(coins_in_origin, ctx);
            transfer::public_transfer(coins_out, tx_context::sender(ctx));
        }
    }

    public entry fun swap_coins_for_exact_coins_2_pair_entry<X, Y, Z>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_in_origin: Coin<X>,
        amount_out: u64,
        amount_in_max: u64,
        ctx: &mut TxContext,
    ) {
        let amount_in = get_amounts_in_2_pair<X, Y, Z>(lps, amount_out);
        assert!(amount_in <= amount_in_max, ERR_INSUFFICIENT_INPUT_AMOUNT);
        let (zeroX, zeroY, coins_mid, coins_out);
        if (compare<X, Y>()) {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            (zeroX, coins_mid) = swap_coins_for_coins<X, Y>(lps, clock, coins_in, coin::zero(ctx), ctx);
            coin::destroy_zero(zeroX);
            return_remaining_coin(coins_in_origin, ctx);
        } else {
            let coins_in = coin::split(&mut coins_in_origin, amount_in, ctx);
            (coins_mid, zeroX) = swap_coins_for_coins<Y, X>(lps, clock, coin::zero(ctx), coins_in, ctx);
            coin::destroy_zero(zeroX);
            return_remaining_coin(coins_in_origin, ctx);
        };
        if (compare<Y, Z>()) {
            (zeroY, coins_out) = swap_coins_for_coins<Y, Z>(lps, clock, coins_mid, coin::zero(ctx), ctx);
            coin::destroy_zero(zeroY);
        } else {
            (coins_out, zeroY) = swap_coins_for_coins<Z, Y>(lps, clock, coin::zero(ctx), coins_mid, ctx);
            coin::destroy_zero(zeroY);
        };
        transfer::public_transfer(coins_out, tx_context::sender(ctx));
    }

    /// swap from Coin to Coin, both sides
    /// require X < Y
    public fun swap_coins_for_coins<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_x_in: Coin<X>,
        coins_y_in: Coin<Y>,
        ctx: &mut TxContext,
    ): (Coin<X>, Coin<Y>) {
        let (balance_x_out, balance_y_out)=
            swap_balance_for_balance<X, Y>(lps, clock, coin::into_balance<X>(coins_x_in), coin::into_balance<Y>(coins_y_in));
        (coin::from_balance<X>(balance_x_out, ctx), coin::from_balance<Y>(balance_y_out, ctx))
    }

    /// swap from Balance to Balance, both sides
    /// require X < Y
    public fun swap_balance_for_balance<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_x_in: Balance<X>,
        coins_y_in: Balance<Y>,
    ): (Balance<X>, Balance<Y>) {
        let (pool, admin_data) = get_pool<X, Y>(lps);
        let amount_x_in = balance::value(&coins_x_in);
        let amount_y_in = balance::value(&coins_y_in);
        assert!((amount_x_in > 0 && amount_y_in == 0) || (amount_x_in == 0 || amount_x_in > 0), ERR_INPUT_VALUE);
        if (amount_x_in > 0) {
            let (reserve_in, reserve_out) = get_reserves_size<X, Y>(pool);
            let amount_out = get_amount_out(amount_x_in, reserve_in, reserve_out, admin_data.swap_fee);
            swap<X, Y>(lps, clock, coins_x_in, 0, coins_y_in, amount_out)
        } else {
            let (reserve_out, reserve_in) = get_reserves_size<X, Y>(pool);
            let amount_out = get_amount_out(amount_y_in, reserve_in, reserve_out, admin_data.swap_fee);
            swap<X, Y>(lps, clock, coins_x_in, amount_out, coins_y_in, 0)
        }
    }

    /// Swap coins, both sides
    /// require X < Y
    public fun swap<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coins_x_in: Balance<X>,
        amount_x_out: u64,
        coins_y_in: Balance<Y>,
        amount_y_out: u64,
    ): (Balance<X>, Balance<Y>) {
        assert_lp_unlocked<X, Y>(lps);
        assert_not_paused(lps);
        let (pool, admin_data) = get_pool<X, Y>(lps);
        let amount_x_in = balance::value(&coins_x_in);
        let amount_y_in = balance::value(&coins_y_in);
        assert!(amount_x_in > 0 || amount_y_in > 0, ERR_INSUFFICIENT_INPUT_AMOUNT);
        assert!(amount_x_out > 0 || amount_y_out > 0, ERR_INSUFFICIENT_OUTPUT_AMOUNT);
        let (reserve_x, reserve_y) = get_reserves_size<X, Y>(pool);
        balance::join<X>(&mut pool.coin_x_reserve, coins_x_in);
        balance::join<Y>(&mut pool.coin_y_reserve, coins_y_in);
        let coins_x_out = balance::split(&mut pool.coin_x_reserve, amount_x_out);
        let coins_y_out = balance::split(&mut pool.coin_y_reserve, amount_y_out);
        let (balance_x, balance_y) = get_reserves_size<X, Y>(pool);
        // assert_k_increase
        assert_k_increase(admin_data, balance_x, balance_y, amount_x_in, amount_y_in, reserve_x, reserve_y);
        // update internal
        update_internal<X, Y>(pool, clock, balance_x, balance_y, reserve_x, reserve_y);
        // event
        event::emit(SwapEvent<X, Y> {
            amount_x_in,
            amount_y_in,
            amount_x_out,
            amount_y_out,
        });
        (coins_x_out, coins_y_out)
    }

    /// mint lp
    /// require X < Y
    public fun mint<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        coin_x: Balance<X>,
        coin_y: Balance<Y>,
    ): Balance<LPCoin<X, Y>> {
        assert_lp_unlocked<X, Y>(lps);
        assert_not_paused(lps);
        // feeOn
        let fee_on = mint_fee_internal<X, Y>(lps);
        let (pool, _) = get_pool<X, Y>(lps);
        let amount_x = balance::value(&coin_x);
        let amount_y = balance::value(&coin_y);
        let (reserve_x, reserve_y) = get_reserves_size(pool);
        let total_supply = balance::supply_value<LPCoin<X, Y>>(&pool.lp_supply);
        balance::join<X>(&mut pool.coin_x_reserve, coin_x);
        balance::join<Y>(&mut pool.coin_y_reserve, coin_y);
        let (balance_x, balance_y) = get_reserves_size(pool);
        let liquidity;
        if (total_supply == 0) {
            liquidity = sqrt(amount_x, amount_y) - MINIMUM_LIQUIDITY;
            let balance_reserve = balance::increase_supply(&mut pool.lp_supply, MINIMUM_LIQUIDITY);
            balance::join(&mut pool.lp_coin_reserve, balance_reserve);
        } else {
            let amount_1 = ((amount_x as u128) * (total_supply as u128) / (reserve_x as u128) as u64);
            let amount_2 = ((amount_y as u128) * (total_supply as u128) / (reserve_y as u128) as u64);
            liquidity = math::min(amount_1, amount_2);
        };
        assert!(liquidity > 0, ERR_INSUFFICIENT_LIQUIDITY_MINT);
        let coins = balance::increase_supply(&mut pool.lp_supply, liquidity);
        // update internal
        update_internal<X, Y>(pool, clock, balance_x, balance_y, reserve_x, reserve_y);
        // feeOn
        if (fee_on) pool.k_last = (balance_x as u128) * (balance_y as u128);
        // event
        event::emit(MintEvent<X, Y> {
            amount_x,
            amount_y,
            liquidity,
        });
        coins
    }

    /// burn lp
    /// require X < Y
    public fun burn<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        liquidity: Balance<LPCoin<X, Y>>,
    ): (Balance<X>, Balance<Y>) {
        assert_lp_unlocked<X, Y>(lps);
        assert_not_paused(lps);
        // feeOn
        let fee_on = mint_fee_internal<X, Y>(lps);
        let (pool, _) = get_pool<X, Y>(lps);
        let liquidity_amount = balance::value(&liquidity);
        let (reserve_x, reserve_y) = get_reserves_size(pool);
        let total_supply = balance::supply_value<LPCoin<X, Y>>(&pool.lp_supply);
        let amount_x = ((liquidity_amount as u128) * (reserve_x as u128) / (total_supply as u128) as u64);
        let amount_y = ((liquidity_amount as u128) * (reserve_y as u128) / (total_supply as u128) as u64);
        let x_coin_to_return = balance::split(&mut pool.coin_x_reserve, amount_x);
        let y_coin_to_return = balance::split(&mut pool.coin_y_reserve, amount_y);
        let (balance_x, balance_y) = get_reserves_size(pool);
        balance::decrease_supply(&mut pool.lp_supply, liquidity);
        // update internal
        update_internal<X, Y>(pool, clock, balance_x, balance_y, reserve_x, reserve_y);
        // feeOn
        if (fee_on) pool.k_last = (balance_x as u128) * (balance_y as u128);
        // event
        event::emit(MintEvent<X, Y> {
            amount_x,
            amount_y,
            liquidity: liquidity_amount,
        });
        (x_coin_to_return, y_coin_to_return)
    }

    fun mint_fee_internal<X, Y>(
        lps: &mut LiquidityPools,
    ): bool {
        let (pool, admin_data) = get_pool<X, Y>(lps);
        let fee_on = admin_data.dao_fee_on;
        let k_last = pool.k_last;
        if (fee_on) {
            if (k_last != 0) {
                let (reserve_x, reserve_y) = get_reserves_size(pool);
                let root_k = sqrt(reserve_x, reserve_y);
                let root_k_last = (math::sqrt_u128(k_last) as u64);
                let total_supply = (balance::supply_value<LPCoin<X, Y>>(&pool.lp_supply) as u128);
                if (root_k > root_k_last) {
                    let delta_k = ((root_k - root_k_last) as u128);
                    // overflow
                    if (is_overflow_mul(total_supply, delta_k)) {
                        let numerator = (total_supply as u256) * (delta_k as u256);
                        let denominator = (root_k as u256) * (admin_data.dao_fee as u256) + (root_k_last as u256);
                        let liquidity = ((numerator / denominator) as u64);
                        if (liquidity > 0) {
                            let balance = balance::increase_supply(&mut pool.lp_supply, liquidity);
                            balance::join(&mut pool.lp_coin_reserve, balance);
                        };
                    } else {
                        let numerator = total_supply * delta_k;
                        let denominator = (root_k as u128) * (admin_data.dao_fee as u128) + (root_k_last as u128);
                        let liquidity = ((numerator / denominator) as u64);
                        if (liquidity > 0) {
                            let balance = balance::increase_supply(&mut pool.lp_supply, liquidity);
                            balance::join(&mut pool.lp_coin_reserve, balance);
                        };
                    };
                }
            }
        } else if (k_last != 0) {
            pool.k_last = 0;
        };
        fee_on
    }

    /// k should not decrease
    fun assert_k_increase(
        admin_data: AdminData,
        balance_x: u64,
        balance_y: u64,
        amount_x_in: u64,
        amount_y_in: u64,
        reserve_x: u64,
        reserve_y: u64,
    ) {
        let swap_fee = admin_data.swap_fee;
        let balance_x_adjusted = (balance_x as u128) * 10000 - (amount_x_in as u128) * (swap_fee as u128);
        let balance_y_adjusted = (balance_y as u128) * 10000 - (amount_y_in as u128) * (swap_fee as u128);
        let balance_xy_old_not_scaled = (reserve_x as u128) * (reserve_y as u128);
        let scale = 100000000;
        // should be: new_reserve_x * new_reserve_y > old_reserve_x * old_eserve_y
        // gas saving
        if (is_overflow_mul(balance_x_adjusted, balance_y_adjusted) || is_overflow_mul(balance_xy_old_not_scaled, scale)) {
            assert!((balance_x_adjusted as u256) * (balance_y_adjusted as u256) >= (balance_xy_old_not_scaled as u256) * (scale as u256), ERR_K_ERROR)
        } else {
            assert!(balance_x_adjusted * balance_y_adjusted >= balance_xy_old_not_scaled * scale, ERR_K_ERROR)
        };
    }

    /// update cumulative, coin_reserve, block_timestamp
    fun update_internal<X, Y>(
        pool: &mut LiquidityPool<X, Y>,
        clock: &Clock,
        balance_x: u64, // new reserve value
        balance_y: u64,
        reserve_x: u64, // old reserve value
        reserve_y: u64
    ) {
        let now = clock::timestamp_ms(clock);
        let time_elapsed = ((now - pool.last_block_timestamp) as u128);
        if (time_elapsed > 0 && reserve_x != 0 && reserve_y != 0) {
            // allow overflow u128
            let last_price_x_cumulative_delta = uq64x64::to_u128(uq64x64::fraction(reserve_y, reserve_x)) * time_elapsed;
            pool.last_price_x_cumulative = overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative_delta);

            let last_price_y_cumulative_delta = uq64x64::to_u128(uq64x64::fraction(reserve_x, reserve_y)) * time_elapsed;
            pool.last_price_y_cumulative = overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative_delta);
        };
        pool.last_block_timestamp = now;
        // event
        event::emit(SyncEvent<X, Y> {
            reserve_x: balance_x,
            reserve_y: balance_y,
            last_price_x_cumulative: pool.last_price_x_cumulative,
            last_price_y_cumulative: pool.last_price_y_cumulative,
        });
    }

    /**
     *  Setting config functions
     */
    public entry fun set_dao_fee_to(
        lps: &mut LiquidityPools,
        dao_fee_to: address,
        ctx: &mut TxContext,
    ) {
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        lps.admin_data.dao_fee_to = dao_fee_to;
    }

    public entry fun set_admin_address(
        lps: &mut LiquidityPools,
        admin_address: address,
        ctx: &mut TxContext,
    ) {
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        lps.admin_data.admin_address = admin_address;
    }

    public entry fun set_dao_fee(
        lps: &mut LiquidityPools,
        dao_fee: u64,
        ctx: &mut TxContext,
    ) {
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        if (dao_fee == 0) {
            lps.admin_data.dao_fee_on = false;
        } else {
            lps.admin_data.dao_fee_on = true;
            lps.admin_data.dao_fee = dao_fee;
        };
    }

    public entry fun set_swap_fee(
        lps: &mut LiquidityPools,
        swap_fee: u64,
        ctx: &mut TxContext,
    ) {
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        lps.admin_data.swap_fee = swap_fee;
    }

    public entry fun withdraw_dao_fee<X, Y>(
        lps: &mut LiquidityPools,
        ctx: &mut TxContext,
    ) {
        assert!(lps.admin_data.dao_fee_to == tx_context::sender(ctx), ERR_FORBIDDEN);
        let (pool, _) = get_pool<X, Y>(lps);
        let amount = balance::value(&pool.lp_coin_reserve) - MINIMUM_LIQUIDITY;
        let balance_out = balance::split(&mut pool.lp_coin_reserve, amount);
        let coins_out = coin::from_balance(balance_out, ctx);
        transfer::public_transfer(coins_out, tx_context::sender(ctx));
    }

    /// pause swap, only remove lp is allowed
    /// EMERGENCY ONLY
    public entry fun pause(
        lps: &mut LiquidityPools,
        ctx: &mut TxContext,
    ) {
        assert_not_paused(lps);
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        lps.admin_data.is_pause = true;
    }

    /// unpause swap
    /// EMERGENCY ONLY
    public entry fun unpause(
        lps: &mut LiquidityPools,
        ctx: &mut TxContext,
    ) {
        assert_paused(lps);
        assert!(lps.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);
        lps.admin_data.is_pause = false;
    }

    fun assert_paused(
        lps: &LiquidityPools,
    ) {
        assert!(lps.admin_data.is_pause, ERR_PAUSABLE_ERROR);
    }

    fun assert_not_paused(
        lps: &LiquidityPools,
    ) {
        assert!(!lps.admin_data.is_pause, ERR_PAUSABLE_ERROR);
    }

    fun assert_lp_unlocked<X, Y>(lps: &mut LiquidityPools) {
        assert!(check_pair_exist<X, Y>(lps), ERR_PAIR_NOT_EXIST);
        let (pool, _) = get_pool<X, Y>(lps);
        assert!(!pool.locked, ERR_LOCK_ERROR);
    }

    public fun flash_swap<X, Y>(
        lps: &mut LiquidityPools,
        loan_coin_x: u64,
        loan_coin_y: u64,
    ): (Balance<X>, Balance<Y>, FlashSwap<X, Y>) {
        assert!(compare<X, Y>(), ERR_PAIR_ORDER_ERROR);
        assert!(loan_coin_x > 0 || loan_coin_y > 0, ERR_LOAN_ERROR);
        assert_lp_unlocked<X, Y>(lps);
        assert_not_paused(lps);
        let (pool, _) = get_pool<X, Y>(lps);
        assert!(balance::value(&pool.coin_x_reserve) >= loan_coin_x && balance::value(&pool.coin_y_reserve) >= loan_coin_y, ERR_INSUFFICIENT_AMOUNT);
        pool.locked = true;

        let loaned_coin_x = balance::split(&mut pool.coin_x_reserve, loan_coin_x);
        let loaned_coin_y = balance::split(&mut pool.coin_y_reserve, loan_coin_y);

        // Return loaned amount.
        (loaned_coin_x, loaned_coin_y, FlashSwap<X, Y> {loan_coin_x, loan_coin_y})
    }

    public fun pay_flash_swap<X, Y>(
        lps: &mut LiquidityPools,
        clock: &Clock,
        x_in: Balance<X>,
        y_in: Balance<Y>,
        flash_swap: FlashSwap<X, Y>,
    ) {
        assert!(compare<X, Y>(), ERR_PAIR_ORDER_ERROR);
        assert_not_paused(lps);

        let FlashSwap { loan_coin_x, loan_coin_y } = flash_swap;
        let amount_x_in = balance::value(&x_in);
        let amount_y_in = balance::value(&y_in);

        assert!(amount_x_in > 0 || amount_y_in > 0, ERR_LOAN_ERROR);
        let (pool, admin_data) = get_pool<X, Y>(lps);
        let reserve_x = balance::value(&pool.coin_x_reserve);
        let reserve_y = balance::value(&pool.coin_y_reserve);

        // reserve size before loan out
        reserve_x = reserve_x + loan_coin_x;
        reserve_y = reserve_y + loan_coin_y;

        balance::join(&mut pool.coin_x_reserve, x_in);
        balance::join(&mut pool.coin_y_reserve, y_in);

        let balance_x = balance::value(&pool.coin_x_reserve);
        let balance_y = balance::value(&pool.coin_y_reserve);
        assert_k_increase(admin_data, balance_x, balance_y, amount_x_in, amount_y_in, reserve_x, reserve_y);
        // update internal
        update_internal<X, Y>(pool, clock, balance_x, balance_y, reserve_x, reserve_y);

        pool.locked = false;
        // event
        event::emit(FlashSwapEvent<X, Y> {
            loan_coin_x,
            loan_coin_y,
            repay_coin_x: amount_x_in,
            repay_coin_y: amount_y_in,
        });
    }

    public fun get_admin_data(lps: &mut LiquidityPools): (u64, u64, bool, bool) {
        (lps.admin_data.swap_fee, lps.admin_data.dao_fee, lps.admin_data.dao_fee_on, lps.admin_data.is_pause)
    }

    public fun get_pair_list(lps: &mut LiquidityPools): vector<PairMeta> {
        lps.pair_info.pair_list
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}

#[test_only]
module defi::animeswap_tests {
    use sui::coin::{mint_for_testing as mint, burn_for_testing as burn};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use defi::animeswap::{Self, LiquidityPools, LPCoin};
    use sui::clock::{Self, Clock};
    // use std::debug;

    const TEST_ERROR: u64 = 10000;

    /// Gonna be our test token.
    struct TestCoin1 has drop {}
    struct TestCoin2 has drop {}
    struct TestCoin3 has drop {}

    #[test]
    fun test_add_remove_lp_basic() {
        let scenario = scenario();
        let (owner, one, two) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, two);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(10000, ctx(test)),
                mint<TestCoin2>(20000, ctx(test)),
                10000,
                10000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 9000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(10000, ctx(test)),
                mint<TestCoin2>(20000, ctx(test)),
                10000,
                10000,
                1,
                1,
                ctx(test),
            );

            assert!(burn(lp_coins) == 10000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let (coin_x, coin_y) = animeswap::remove_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<LPCoin<TestCoin1, TestCoin2>>(1000, ctx(test)),
                500,
                1,
                1,
                ctx(test),
            );

            assert!(burn(coin_x) == 500, TEST_ERROR);
            assert!(burn(coin_y) == 500, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        test::end(scenario);
    }

    #[test]
    fun test_swap_lp_basic() {
        let scenario = scenario();
        let (owner, one, _) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(10000, ctx(test)),
                mint<TestCoin2>(20000, ctx(test)),
                10000,
                10000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 9000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let (zero, coins_out) = animeswap::swap_coins_for_coins<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000, ctx(test)),
                coin::zero(ctx(test)),
                ctx(test),
            );
            coin::destroy_zero(zero);
            assert!(burn(coins_out) == 906, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let (coins_out, zero) = animeswap::swap_coins_for_coins<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                coin::zero(ctx(test)),
                mint<TestCoin2>(1000, ctx(test)),
                ctx(test),
            );
            coin::destroy_zero(zero);
            assert!(burn(coins_out) == 1086, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        test::end(scenario);
    }

    #[test]
    fun test_swap_lp_multiple_exact_x_y_z() {
        let scenario = scenario();
        let (owner, one, _) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            animeswap::create_pair<TestCoin2, TestCoin3>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000000, ctx(test)),
                mint<TestCoin2>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin2>(1000000, ctx(test)),
                mint<TestCoin3>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            animeswap::swap_exact_coins_for_coins_2_pair_entry<TestCoin1, TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000, ctx(test)),
                1000,
                1,
                ctx(test),
            );
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            // 1000 TestCoins1 -> 15825 TestCoins3
            let test = &mut scenario;
            let coins = test::take_from_sender<Coin<TestCoin3>>(test);
            assert!(coin::value(&coins) == 15825, TEST_ERROR);
            test::return_to_sender(test, coins);
        };
        test::end(scenario);
    }

    #[test]
    fun test_swap_lp_multiple_x_y_z_exact() {
        let scenario = scenario();
        let (owner, one, _) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            animeswap::create_pair<TestCoin2, TestCoin3>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000000, ctx(test)),
                mint<TestCoin2>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin2>(1000000, ctx(test)),
                mint<TestCoin3>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            animeswap::swap_coins_for_exact_coins_2_pair_entry<TestCoin1, TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin1>(20000, ctx(test)),
                15825,
                10000000000,
                ctx(test),
            );
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            // 1000 TestCoins1 -> 15825 TestCoins3
            let test = &mut scenario;
            let coins = test::take_from_sender<Coin<TestCoin1>>(test);
            // remain value
            assert!(coin::value(&coins) == 20000 - 1000, TEST_ERROR);
            test::return_to_sender(test, coins);
        };
        test::end(scenario);
    }

    #[test]
    fun test_swap_lp_multiple_exact_z_y_x() {
        let scenario = scenario();
        let (owner, one, _) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            animeswap::create_pair<TestCoin2, TestCoin3>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000000, ctx(test)),
                mint<TestCoin2>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin2>(1000000, ctx(test)),
                mint<TestCoin3>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            animeswap::swap_exact_coins_for_coins_2_pair_entry<TestCoin3, TestCoin2, TestCoin1>(
                &mut lps,
                &clock,
                mint<TestCoin3>(100000, ctx(test)),
                99984,
                1,
                ctx(test),
            );
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            // 99984 TestCoin3 -> 6024 TestCoin1
            // also: 100000 TestCoin3 -> 6024 TestCoin1
            let test = &mut scenario;
            let coins = test::take_from_sender<Coin<TestCoin1>>(test);
            assert!(coin::value(&coins) == 6024, TEST_ERROR);
            test::return_to_sender(test, coins);
        };
        test::end(scenario);
    }

    #[test]
    fun test_swap_lp_multiple_z_y_x_exact() {
        let scenario = scenario();
        let (owner, one, _) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
            let clock = clock::create_for_testing(ctx(test));
            clock::share_for_testing(clock);
        };
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            animeswap::create_pair<TestCoin2, TestCoin3>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin1, TestCoin2>(
                &mut lps,
                &clock,
                mint<TestCoin1>(1000000, ctx(test)),
                mint<TestCoin2>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            let lp_coins = animeswap::add_liquidity<TestCoin2, TestCoin3>(
                &mut lps,
                &clock,
                mint<TestCoin2>(1000000, ctx(test)),
                mint<TestCoin3>(4000000, ctx(test)),
                1000000,
                4000000,
                1,
                1,
                ctx(test),
            );
            assert!(burn(lp_coins) == 1999000, TEST_ERROR);
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            let clock = test::take_shared<Clock>(test);
            animeswap::swap_coins_for_exact_coins_2_pair_entry<TestCoin3, TestCoin2, TestCoin1>(
                &mut lps,
                &clock,
                mint<TestCoin3>(200000, ctx(test)),
                6024,
                1000000,
                ctx(test),
            );
            test::return_shared(clock);
            test::return_shared(lps);
        };
        next_tx(&mut scenario, one);
        {
            // 99984 TestCoin3 -> 6024 TestCoin1
            let test = &mut scenario;
            let coins = test::take_from_sender<Coin<TestCoin3>>(test);
            // remain value
            assert!(coin::value(&coins) == 200000 - 99984, TEST_ERROR);
            test::return_to_sender(test, coins);
        };
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = animeswap::ERR_PAIR_ALREADY_EXIST)]
    fun test_create_lp_dup_error() {
        let scenario = scenario();
        let (owner, one, two) = people();
        next_tx(&mut scenario, owner);
        {
            let test = &mut scenario;
            animeswap::init_for_testing(ctx(test));
        };
        next_tx(&mut scenario, one);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        next_tx(&mut scenario, two);
        {
            let test = &mut scenario;
            let lps = test::take_shared<LiquidityPools>(test);
            animeswap::create_pair<TestCoin1, TestCoin2>(&mut lps, ctx(test));
            test::return_shared(lps);
        };
        test::end(scenario);
    }

    // utilities
    fun scenario(): Scenario { test::begin(@0x1) }
    fun people(): (address, address, address) { (@0xBEEF, @0x1111, @0x2222) }
}