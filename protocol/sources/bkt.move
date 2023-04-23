module bucket_protocol::bkt {

    use sui::tx_context::TxContext;
    use sui::coin;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::url;
    use std::option;

    friend bucket_protocol::tank;
    friend bucket_protocol::buck;
    friend bucket_protocol::well;

    // TODO: token distribution
    const BKT_TOTAL_SUPPLY: u64 = 1000000000000000; // supply: 1M
    const FOR_TEAM: u64 = 200000000000000; // 20%
    const FOR_PARTNER: u64 = 70000000000000; // 7%
    const FOR_ADVISER: u64 = 30000000000000; // 3%
    const FOR_TANK_DEPOSITER: u64 = 700000000000000; // 70%

    struct BKT has drop {}

    struct BktTreasury has key {
        id: UID,
        vault: Balance<BKT>,
    }

    fun init(witness: BKT, ctx: &mut TxContext) {
        let (bkt_treasury_cap, bkt_metadata) = coin::create_currency(
            witness,
            9,
            b"BKT",
            b"Bucket Coin",
            b"incentive token minted by bucketprotocol.io",
            option::some(
                url::new_unsafe_from_bytes(b"https://ipfs.io/ipfs/QmTKZ2CX8RzkJeqCpaYPHbS5sFyCQdtasxyYb96Xmns1Cv"),
            ),
            ctx,
        );

        transfer::public_freeze_object(bkt_metadata);
        // TODO: change the receipients
        coin::mint_and_transfer(&mut bkt_treasury_cap, FOR_TEAM, @0x73c88d432ad4b2bfc5170148faae6f11f39550fb84f9b83c8d152dd89bc8eda3, ctx);
        coin::mint_and_transfer(&mut bkt_treasury_cap, FOR_PARTNER, @0xb5f59df8059cccb0f4f9a55e8adf60f0bbc16180cb9ccf5d50e0c1c3e2bd4401, ctx);
        coin::mint_and_transfer(&mut bkt_treasury_cap, FOR_ADVISER, @0xa5a60fec692a9fa0228d50b4a5df85f698ca939d362a97728133d20eeaec8cc1, ctx);
        transfer::share_object(BktTreasury {
            id: object::new(ctx),
            vault: coin::mint_balance(&mut bkt_treasury_cap, FOR_TANK_DEPOSITER),
        });
        assert!(coin::total_supply(&bkt_treasury_cap) == BKT_TOTAL_SUPPLY, 137);
        transfer::public_freeze_object(bkt_treasury_cap);
    }

    public(friend) fun claim(bkt_treasury: &mut BktTreasury, amount: u64): Balance<BKT> {
        let treasury_remaining = balance::value(&bkt_treasury.vault);
        if (amount >= treasury_remaining)
            amount = treasury_remaining;

        balance::split(&mut bkt_treasury.vault, amount)
    }
}
