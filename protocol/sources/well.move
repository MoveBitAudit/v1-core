module bucket_protocol::well {

    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::table_vec::{Self, TableVec};

    friend bucket_protocol::buck;

    struct Info has store {
        max_level: u64,
        current_level: u64,
    }

    struct Well<phantom T> has store, key {
        id: UID,
        pool: Balance<T>,
        info_table: TableVec<Info>,
    }

    public(friend) fun create<T>(ctx: &mut TxContext) {
        transfer::share_object(new<T>(ctx));
    }

    public(friend) fun collect_fee<T>(well: &mut Well<T>, input: Balance<T>) {
        balance::join(&mut well.pool, input);
    }

    fun new<T>(ctx: &mut TxContext): Well<T> {
        Well {
            id: object::new(ctx),
            pool: balance::zero(),
            info_table: table_vec::empty(ctx),
        }
    } 

    #[test_only]
    public fun new_for_testing<T>(ctx: &mut TxContext): Well<T> {
        new<T>(ctx)
    }
}
