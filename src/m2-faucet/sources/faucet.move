module razor::faucet {
    use std::type_name;
    use std::ascii::String;
    use std::vector;
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::dynamic_object_field as ofield;
    use sui::tx_context::{Self, TxContext};
    use sui::event;

    // Errors.

    /// When Faucet already exists on account.
    const ERR_FAUCET_EXISTS: u64 = 100;

    /// When Faucet doesn't exists on account.
    const ERR_FAUCET_NOT_EXISTS: u64 = 101;

    /// When contract is paused
    const ERR_PAUSABLE_ERROR: u64 = 102;

    /// When user is not admin
    const ERR_FORBIDDEN: u64 = 103;

    struct AdminData has store, copy, drop {
        admin_address: address,
        is_pause: bool,
    }

    struct Faucet<phantom CoinType> has key, store {
        id: UID,
        deposit: Balance<CoinType>,
    }

    struct Faucets has key {
        id: UID,
        admin_data: AdminData,
        faucet_info: FaucetInfo,
        per_request: u64,
        period: u64,
    }

    struct CoinMeta has drop, store, copy {
        coin: String,
    }

    struct FaucetInfo has store, copy, drop {
        faucet_list: vector<CoinMeta>,
    }

    struct FaucetCreatedEvent<phantom CoinType> has drop, copy {
        meta: CoinMeta,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(Faucets {
            id: object::new(ctx),
            admin_data: AdminData {
                admin_address: @deployer,
                is_pause: false,
            },
            faucet_info: FaucetInfo {
                faucet_list: vector::empty(),
            },
            per_request: 10000000000,
            period: 86400,
        });
    }

    public fun get_faucet_name<CoinType>(): String {
        type_name::into_string(type_name::get<Faucet<CoinType>>())
    }

    // Public functions.

    public fun check_faucet_exist<CoinType>(
        faucets: &Faucets,
    ): bool {
        ofield::exists_<String>(&faucets.id, get_faucet_name<CoinType>())
    }

    /// Create a new faucet on `account` address.
    /// * `deposit` - initial coins on faucet balance.
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public fun create_faucet_internal<CoinType>(
        faucets: &mut Faucets,
        ctx: &mut TxContext
    ) {
        assert!(faucets.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);

        assert!(!check_faucet_exist<CoinType>(faucets), ERR_FAUCET_EXISTS);
        assert_not_paused(faucets);
        let faucet = Faucet<CoinType>{
            id: object::new(ctx),
            deposit: balance::zero<CoinType>(),
        };

        ofield::add(&mut faucets.id, get_faucet_name<CoinType>(), faucet);

        let coin_meta = CoinMeta {
            coin: type_name::into_string(type_name::get<CoinType>()),
        };

        vector::push_back(&mut faucets.faucet_info.faucet_list, coin_meta);

        event::emit(FaucetCreatedEvent<CoinType> {
            meta: coin_meta,
        });
    }

    /// Change settings of faucet `CoinType`.
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public fun change_settings_internal<CoinType>(
        faucets: &mut Faucets,
        per_request: u64,
        period: u64,
        ctx: &mut TxContext,
    ) {
        assert!(check_faucet_exist<CoinType>(faucets), ERR_FAUCET_EXISTS);
        assert_not_paused(faucets);

        assert!(faucets.admin_data.admin_address == tx_context::sender(ctx), ERR_FORBIDDEN);

        faucets.per_request = per_request;
        faucets.period = period;
    }

    /// Deposist more coins `CoinType` to faucet.
    public fun deposit_internal<CoinType>(
        deposit: Coin<CoinType>,
        faucets: &mut Faucets,
        faucet: &mut Faucet<CoinType>,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        assert!(check_faucet_exist<CoinType>(faucets), ERR_FAUCET_NOT_EXISTS);

        let split = coin::split(&mut deposit, amount, ctx);
        coin::put(&mut faucet.deposit, split);
        return_remaining_coin(deposit, ctx);
    }

    /// Requests coins `CoinType` from faucet `faucet_addr`.
    public fun request_internal<CoinType>(
        faucets: &Faucets,
        faucet: &mut Faucet<CoinType>,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        assert!(check_faucet_exist<CoinType>(faucets), ERR_FAUCET_NOT_EXISTS);

        let coins = balance::split(&mut faucet.deposit, faucets.per_request);
        // return_remaining_balance<CoinType>(faucet.deposit, ctx);

        coin::from_balance(coins, ctx)
    }

    // Scripts.

    /// Creates new faucet on `account` address for coin `CoinType`.
    /// * `account` - account which creates
    /// * `per_request` - how much funds should be distributed per user request.
    /// * `period` - interval allowed between requests for specific user.
    public entry fun create_faucet<CoinType>(faucets: &mut Faucets, ctx: &mut TxContext) {
        create_faucet_internal<CoinType>(faucets, ctx);
    }

    /// Changes faucet settings on `account`.
    public entry fun change_settings<CoinType>(
        faucets: &mut Faucets,
        per_request: u64,
        period: u64,
        ctx: &mut TxContext,
    ) {
        change_settings_internal<CoinType>(faucets, per_request, period, ctx);
    }

    /// Deposits coins `CoinType` to faucet on `faucet` address, withdrawing funds from user balance.
    public entry fun deposit<CoinType>(
        deposit: Coin<CoinType>,
        faucets: &mut Faucets,
        faucet: &mut Faucet<CoinType>,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        deposit_internal<CoinType>(deposit, faucets, faucet, amount, ctx);
    }

    /// Deposits coins `CoinType` from faucet on user's account.
    /// `faucet` - address of faucet to request funds.
    public entry fun request<CoinType>(
        faucets: &Faucets,
        faucet: &mut Faucet<CoinType>,
        ctx: &mut TxContext
    ) {
        let coins = request_internal<CoinType>(faucets, faucet, ctx);
        transfer::public_transfer(coins, tx_context::sender(ctx));
    }

    fun assert_not_paused(
        faucets: &Faucets,
    ) {
        assert!(!faucets.admin_data.is_pause, ERR_PAUSABLE_ERROR);
    }

    #[lint_allow(self_transfer)]
    public fun return_remaining_coin<CoinType>(
        coin: Coin<CoinType>,
        ctx: &mut TxContext,
    ) {
        if (coin::value(&coin) == 0) {
            coin::destroy_zero(coin);
        } else {
            transfer::public_transfer(coin, tx_context::sender(ctx));
        };
    }

    #[lint_allow(self_transfer)]
    public fun return_remaining_balance<CoinType>(
        balance: Balance<CoinType>,
        ctx: &mut TxContext,
    ) {
        if (balance::value(&balance) == 0) {
            balance::destroy_zero(balance);
        } else {
            transfer::public_transfer(coin::from_balance(balance, ctx), tx_context::sender(ctx));
        };
    }
}