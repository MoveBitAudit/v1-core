module bucket_protocol::bottle {

    use std::option::{Self, Option};
    use bucket_framework::linked_table::{Self, LinkedTable};

    friend bucket_protocol::buck;

    const EUnsortedInsertion: u64 = 0;
    const ECollateralRatioTooLow: u64 = 1;
    const ECannotRedeemFromBottle: u64 = 2;
    const EDestroyNonEmptyBottle: u64 = 3;

    struct Bottle has store {
        collateral_amount: u64,
        buck_amount: u64,
    }

    public(friend) fun new(): Bottle {
        Bottle { collateral_amount: 0, buck_amount: 0 }
    }

    public(friend) fun insert_bottle(
        bottle_table: &mut LinkedTable<address, Bottle>,
        debtor: address,
        bottle: Bottle,
        prev_debtor_opt: Option<address>,
    ) {
        if (option::is_some(&prev_debtor_opt)) {
            let prev_debtor = *option::borrow(&prev_debtor_opt);
            let prev_bottle = linked_table::borrow(bottle_table, prev_debtor);
            assert!(cr_greater(&bottle, prev_bottle), EUnsortedInsertion);
            let next_debtor = *linked_table::next(bottle_table, prev_debtor);
            if (option::is_some(&next_debtor)) {
                let next_debtor = option::destroy_some(next_debtor);
                let next_bottle = linked_table::borrow(bottle_table, next_debtor);
                assert!(cr_less_or_equal(&bottle, next_bottle), EUnsortedInsertion);
            };
        } else {
            let next_debtor = *linked_table::front(bottle_table);
            if (option::is_some(&next_debtor)) {
                let next_debtor = option::destroy_some(next_debtor);
                let next_bottle = linked_table::borrow(bottle_table, next_debtor);
                assert!(
                    cr_less_or_equal(&bottle, next_bottle),
                    EUnsortedInsertion,
                );
            }
        };
        linked_table::insert_back(bottle_table, prev_debtor_opt, debtor, bottle);
    }

    public(friend) fun record_borrow(
        bottle: &mut Bottle,
        price: u64,
        denominator: u64,
        minimal_cr: u64,
        collateral_amount: u64,
        expected_buck_amount: u64,
    ) {
        bottle.collateral_amount = bottle.collateral_amount + collateral_amount;
        bottle.buck_amount = bottle.buck_amount + expected_buck_amount;

        let new_collateral_ration = bottle.collateral_amount * price / bottle.buck_amount / denominator;
        assert!(new_collateral_ration * 100 > minimal_cr, ECollateralRatioTooLow);
    }

    public(friend) fun repay_result(bottle: &mut Bottle, repay_amount: u64): (bool, u64) {
        if (repay_amount >= bottle.buck_amount) {
            let return_sui_amount = bottle.collateral_amount;
            bottle.collateral_amount = 0;
            bottle.buck_amount = 0;
            // fully repaid
            (true, return_sui_amount)
        } else {
            let return_sui_amount = bottle.collateral_amount * repay_amount / bottle.buck_amount;
            bottle.collateral_amount = bottle.collateral_amount - return_sui_amount;
            bottle.buck_amount = bottle.buck_amount - repay_amount;
            // not fully repaid
            (false, return_sui_amount)
        }
    }

    public(friend) fun redeem_result(
        bottle: &mut Bottle,
        price: u64,
        denominator: u64,
        buck_amount: u64,
    ): (u64, u64, u64, bool) {
        let redeemer_sui_amount = buck_amount * denominator / price;
        assert!(bottle.collateral_amount >= redeemer_sui_amount, ECannotRedeemFromBottle);
        let debtor_sui_amount = bottle.collateral_amount - redeemer_sui_amount;

        if (buck_amount >= bottle.buck_amount) {
            bottle.collateral_amount = 0;
            bottle.buck_amount = 0;
            if (buck_amount == bottle.buck_amount)
                (buck_amount, redeemer_sui_amount, debtor_sui_amount, true)
            else
                (bottle.buck_amount, redeemer_sui_amount, debtor_sui_amount, false)
        } else {
            bottle.collateral_amount = bottle.collateral_amount - redeemer_sui_amount;
            bottle.buck_amount = bottle.buck_amount - buck_amount;
            (buck_amount, redeemer_sui_amount, 0, true)
        }
    }

    public(friend) fun destroyable(bottle: &Bottle): bool {
        bottle.collateral_amount == 0 && bottle.buck_amount == 0
    }

    public(friend) fun destroy(bottle: Bottle) {
        let Bottle { collateral_amount, buck_amount } = bottle;
        assert!(collateral_amount == 0 && buck_amount == 0, EDestroyNonEmptyBottle);
    }

    public fun get_collateral_amount(bottle: &Bottle): u64 {
        bottle.collateral_amount
    }

    public fun get_buck_amount(bottle: &Bottle): u64 {
        bottle.buck_amount
    }

    public fun cr_greater(bottle: &Bottle, bottle_cmp: &Bottle): bool {
        (bottle.collateral_amount as u256) * (bottle_cmp.buck_amount as u256) >
            (bottle_cmp.collateral_amount as u256) * (bottle.buck_amount as u256)
    }

    public fun cr_less_or_equal(bottle: &Bottle, bottle_cmp: &Bottle): bool {
        !cr_greater(bottle, bottle_cmp)
    }

    #[test_only]
    public fun print_bottle(bottle: &Bottle) {
        std::debug::print(&(100*bottle.collateral_amount/bottle.buck_amount));
        std::debug::print(bottle);
    }

    #[test_only]
    public fun print_bottle_table(bottle_table: &LinkedTable<address, Bottle>) {
        let curr_debtor = linked_table::front(bottle_table);
        while (option::is_some(curr_debtor)) {
            let debtor = *option::borrow(curr_debtor);
            std::debug::print(&debtor);
            print_bottle(linked_table::borrow(bottle_table, debtor));
            curr_debtor = linked_table::next(bottle_table, debtor);
        }
    }
}