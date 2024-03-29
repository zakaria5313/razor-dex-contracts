module razor::sol {
  use std::option;

  use sui::object::{Self, UID, ID};
  use sui::tx_context::{TxContext};
  use sui::balance::{Self, Supply};
  use sui::transfer;
  use sui::coin::{Self, Coin};
  // use sui::url;
  use sui::vec_set::{Self, VecSet};
  use sui::tx_context;
  use sui::package::{Publisher};
  use sui::event::{emit};

  const SOL_PRE_MINT_AMOUNT: u64 = 444000000000000000;

  // Errors
  const ERROR_NOT_ALLOWED_TO_MINT: u64 = 1;
  const ERROR_NO_ZERO_ADDRESS: u64 = 2;

  struct SOL has drop {}

  struct SOLStorage has key {
    id: UID,
    supply: Supply<SOL>,
    minters: VecSet<ID> // List of publishers that are allowed to mint SOL
  }

  struct SOLAdminCap has key {
    id: UID
  }

  // Events 
  struct MinterAdded has copy, drop {
    id: ID
  }

  struct MinterRemoved has copy, drop {
    id: ID
  }

  struct NewAdmin has copy, drop {
    admin: address
  }

  fun init(witness: SOL, ctx: &mut TxContext) {
      // Create the SOL governance token with 9 decimals
      let (treasury, metadata) = coin::create_currency<SOL>(
            witness, 
            9,
            b"SOL",
            b"Solana Coin",
            b"",
            option::none(),
            ctx
        );
      // Transform the treasury_cap into a supply struct to allow this contract to mint/burn DNR
      let supply = coin::treasury_into_supply(treasury);

      // Pre-mint 60% of the supply to distribute
      transfer::public_transfer(
        coin::from_balance(
          balance::increase_supply(&mut supply, SOL_PRE_MINT_AMOUNT), ctx
        ),
        tx_context::sender(ctx)
      );

      transfer::transfer(
        SOLAdminCap {
          id: object::new(ctx)
        },
        tx_context::sender(ctx)
      );

      transfer::share_object(
        SOLStorage {
          id: object::new(ctx),
          supply,
          minters: vec_set::empty()
        }
      );

      // Freeze the metadata object
      transfer::public_freeze_object(metadata);
  }

  /**
  * @dev Only minters can create new Coin<SOL>
  * @param storage The SOLStorage
  * @param publisher The Publisher object of the package who wishes to mint SOL
  * @return Coin<SOL> New created SOL coin
  */
  public fun mint(storage: &mut SOLStorage, publisher: &Publisher, value: u64, ctx: &mut TxContext): Coin<SOL> {
    assert!(is_minter(storage, object::id(publisher)), ERROR_NOT_ALLOWED_TO_MINT);

    coin::from_balance(balance::increase_supply(&mut storage.supply, value), ctx)
  }

  /**
  * @dev This function allows anyone to burn their own SOL.
  * @param storage The SOLStorage shared object
  * @param c The SOL coin that will be burned
  */
  public fun burn(storage: &mut SOLStorage, c: Coin<SOL>): u64 {
    balance::decrease_supply(&mut storage.supply, coin::into_balance(c))
  }

  /**
  * @dev A utility function to transfer SOL to a {recipient}
  * @param c The Coin<SOL> to transfer
  * @param recipient The recipient of the Coin<SOL>
  */
  public entry fun transfer(c: coin::Coin<SOL>, recipient: address) {
    transfer::public_transfer(c, recipient);
  }

  /**
  * @dev It returns the total supply of the Coin<X>
  * @param storage The {SOLStorage} shared object
  * @return the total supply in u64
  */
  public fun total_supply(storage: &SOLStorage): u64 {
    balance::supply_value(&storage.supply)
  }


  /**
  * @dev It allows the holder of the {SOLAdminCap} to add a minter. 
  * @param _ The SOLAdminCap to guard this function 
  * @param storage The SOLStorage shared object
  * @param publisher The package that owns this publisher will be able to mint SOL
  *
  * It emits the MinterAdded event with the {ID} of the {Publisher}
  *
  */
  entry public fun add_minter(_: &SOLAdminCap, storage: &mut SOLStorage, id: ID) {
    vec_set::insert(&mut storage.minters, id);
    emit(
      MinterAdded {
        id
      }
    );
  }

  /**
  * @dev It allows the holder of the {SOLAdminCap} to remove a minter. 
  * @param _ The SOLAdminCap to guard this function 
  * @param storage The SOLStorage shared object
  * @param publisher The package that will no longer be able to mint SOL
  *
  * It emits the  MinterRemoved event with the {ID} of the {Publisher}
  *
  */
  entry public fun remove_minter(_: &SOLAdminCap, storage: &mut SOLStorage, id: ID) {
    vec_set::remove(&mut storage.minters, &id);
    emit(
      MinterRemoved {
        id
      }
    );
  } 


  /**
  * @dev It gives the admin rights to the recipient. 
  * @param admin_cap The SOLAdminCap that will be transferred
  * @recipient the new admin address
  *
  * It emits the NewAdmin event with the new admin address
  *
  */
  entry public fun transfer_admin(admin_cap: SOLAdminCap, recipient: address) {
    assert!(recipient != @0x0, ERROR_NO_ZERO_ADDRESS);
    transfer::transfer(admin_cap, recipient);

    emit(NewAdmin {
      admin: recipient
    });
  } 

  /**
  * @dev It indicates if a package has the right to mint SOL
  * @param storage The SOLStorage shared object
  * @param publisher of the package 
  * @return bool true if it can mint SOL
  */
  public fun is_minter(storage: &SOLStorage, id: ID): bool {
    vec_set::contains(&storage.minters, &id)
  }


  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(SOL {}, ctx);
  }
}