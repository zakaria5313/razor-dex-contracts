module razor::Coins {
    use std::signer;
    use std::string::utf8;

    use aptos_framework::coin::{Self, MintCapability, FreezeCapability, BurnCapability};

    // Define the different types of coins.
    struct USDT {}
    struct USDC {}
    struct BTC {}
    struct ETH {}
    struct SOL {}
    struct BNB {}

    // Define a struct to hold the capabilities for each coin type.
    struct Caps<phantom CoinType> has key {
        mint: MintCapability<CoinType>,
        freeze: FreezeCapability<CoinType>,
        burn: BurnCapability<CoinType>,
    }

    // Initialize the coins with their respective names, symbols, decimals, and other properties.
    public entry fun initialize(admin: &signer) {
        // Initialize BTC
        let (btc_b, btc_f, btc_m) =
            coin::initialize<BTC>(admin,
                utf8(b"Bitcoin"), utf8(b"BTC"), 8, true);
        // Initialize USDT
        let (usdt_b, usdt_f, usdt_m) =
            coin::initialize<USDT>(admin,
                utf8(b"Tether"), utf8(b"USDT"), 8, true);
        // Initialize USDC
        let (usdc_b, usdc_f, usdc_m) =
            coin::initialize<USDC>(admin,
                utf8(b"Circle USD"), utf8(b"USDC"), 8, true);
        // Initialize ETH
        let (eth_b, eth_f, eth_m) =
            coin::initialize<ETH>(admin,
                utf8(b"Ether"), utf8(b"ETH"), 8, true);
        // Initialize SOL
        let (sol_b, sol_f, sol_m) =
            coin::initialize<SOL>(admin,
                utf8(b"Solana"), utf8(b"SOL"), 8, true);
        // Initialize BNB
        let (bnb_b, bnb_f, bnb_m) =
            coin::initialize<BNB>(admin,
                utf8(b"Binance Coin"), utf8(b"BNB"), 8, true);

        // Store the capabilities for each coin type under the admin account.
        move_to(admin, Caps<BTC> { mint: btc_m, freeze: btc_f, burn: btc_b });
        move_to(admin, Caps<USDT> { mint: usdt_m, freeze: usdt_f, burn: usdt_b });
        move_to(admin, Caps<USDC> { mint: usdc_m, freeze: usdc_f, burn: usdc_b });
        move_to(admin, Caps<ETH> { mint: eth_m, freeze: eth_f, burn: eth_b });
        move_to(admin, Caps<SOL> { mint: sol_m, freeze: sol_f, burn: sol_b });
        move_to(admin, Caps<BNB> { mint: bnb_m, freeze: bnb_f, burn: bnb_b });

        // Register all coins for the admin account.
        register_coins_all(admin);
    }

    // Register all coins for a given account if they are not already registered.
    public entry fun register_coins_all(account: &signer) {
        let account_addr = signer::address_of(account);
        // Register BTC if not already registered
        if (!coin::is_account_registered<BTC>(account_addr)) {
            coin::register<BTC>(account);
        };
        // Register USDT if not already registered
        if (!coin::is_account_registered<USDT>(account_addr)) {
            coin::register<USDT>(account);
        };
        // Register USDC if not already registered
        if (!coin::is_account_registered<USDC>(account_addr)) {
            coin::register<USDC>(account);
        };
        // Register ETH if not already registered
        if (!coin::is_account_registered<ETH>(account_addr)) {
            coin::register<ETH>(account);
        };
        // Register SOL if not already registered
        if (!coin::is_account_registered<SOL>(account_addr)) {
            coin::register<SOL>(account);
        };
        // Register BNB if not already registered
        if (!coin::is_account_registered<BNB>(account_addr)) {
            coin::register<BNB>(account);
        };
    }

    // Mint a new coin of a specific type and deposit it into a given account.
    public entry fun mint_coin<CoinType>(admin: &signer, acc_addr: address, amount: u64) acquires Caps {
        let admin_addr = signer::address_of(admin);
        // Borrow the capabilities for the coin type from the admin account.
        let caps = borrow_global<Caps<CoinType>>(admin_addr);
        // Mint the coin and deposit it into the account.
        let coins = coin::mint<CoinType>(amount, &caps.mint);
        coin::deposit(acc_addr, coins);
    }
}