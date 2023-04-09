module bucket_protocol::bkt {

    use sui::tx_context::TxContext;
    use sui::coin;
    use sui::transfer;
    use std::option;
    use sui::object::{Self, UID};
    use sui::balance::Balance;

    const BKT_TOTAL_SUPPLY: u64 = 100000000000000;

    struct BKT has drop {}

    struct BktDepository has key {
        id: UID,
        vault: Balance<BKT>,
    }

    fun init(witness: BKT, ctx: &mut TxContext) {
        let (bkt_treasury, bkt_metadata) = coin::create_currency(
            witness,
            8,
            b"BKT",
            b"Bucket Coin",
            b"incentive token minted by bucketprotocol.io",
            option::none(),
            ctx,
        );

        transfer::public_freeze_object(bkt_metadata);
        transfer::share_object(BktDepository {
            id: object::new(ctx),
            vault: coin::mint_balance(&mut bkt_treasury, BKT_TOTAL_SUPPLY),
        });
        transfer::public_freeze_object(bkt_treasury);
    }
}
