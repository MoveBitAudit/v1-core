module bucket_protocol::tank {

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;

    friend bucket_protocol::buck;

    struct Tank<phantom T> has key {
        id: UID,
        vault: Balance<T>,
    }

    public(friend) fun new<T>(ctx: &mut TxContext): Tank<T> {
        Tank { id: object::new(ctx), vault: balance::zero() }
    }
}
