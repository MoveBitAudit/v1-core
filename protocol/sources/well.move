module bucket_protocol::well {

    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
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

    public fun new<T>(ctx: &mut TxContext): Well<T> {
        Well {
            id: object::new(ctx),
            pool: balance::zero(),
            info_table: table_vec::empty(ctx),
        }
    }

    public fun collect_fee<T>(well: &mut Well<T>, input: Balance<T>) {
        balance::join(&mut well.pool, input);
    }

    public fun get_balance<T>(well: &Well<T>): u64 {
        balance::value(&well.pool)
    }

    #[test_only]
    public fun new_for_testing<T>(ctx: &mut TxContext): Well<T> {
        new<T>(ctx)
    }
}
