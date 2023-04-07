module bucket_protocol::bucket {

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use std::option::{Self, Option};

    use bucket_framework::linked_table::{Self, LinkedTable};
    use bucket_protocol::mock_oracle::{PriceFeed, get_price};
    use bucket_protocol::bottle::{Self, Bottle, get_buck_amount};
    use sui::tx_context;

    friend bucket_protocol::buck;

    const ECannotBorrowWithFlashLoan: u64 = 0;
    const ERepayerNoDebt: u64 = 1;
    const EBottleNotFound: u64 = 1;
    const ERepayTooMuch: u64 = 4;
    const EFlashFeeNotEnough: u64 = 5;
    const ENotEnoughToRedeem: u64 = 6;

    const FLASH_LOAN_FEE_DIVISOR: u64 = 10000; // 0.01% fee

    struct Bucket<phantom T> has key, store {
        id: UID,
        vault: Balance<T>,
        min_collateral_ratio: u64,
        bottle_table: LinkedTable<address, Bottle>,
        flash_lock: bool,
    }

    struct FlashRecipit<phantom T> {
        amount: u64,
        fee: u64,
    }

    public(friend) fun new<T>(min_collateral_ratio: u64, ctx: &mut TxContext): Bucket<T> {
        Bucket {
            id: object::new(ctx),
            vault: balance::zero(),
            min_collateral_ratio,
            bottle_table: linked_table::new(ctx),
            flash_lock: false,
        }
    }

    public(friend) fun handle_borrow<T>(
        bucket: &mut Bucket<T>,
        oracle: &PriceFeed<T>,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        prev_debtor: Option<address>,
        ctx: &TxContext,
    ) {
        let borrower = tx_context::sender(ctx);
        let bottle = borrow_internal(bucket, oracle, borrower, collateral_input, buck_output_amount);
        bottle::insert_bottle(&mut bucket.bottle_table, borrower, bottle, prev_debtor);
    }

    public(friend) fun handle_auto_borrow<T>(
        bucket: &mut Bucket<T>,
        oracle: &PriceFeed<T>,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        ctx: &TxContext,
    ) {
        let borrower = tx_context::sender(ctx);
        let bottle = borrow_internal(bucket, oracle, borrower, collateral_input, buck_output_amount);
        let prev_debtor = find_valid_insertion(&bucket.bottle_table, &bottle, option::none());
        linked_table::insert_back(&mut bucket.bottle_table, prev_debtor, borrower, bottle);
    }

    public(friend) fun handle_repay<T>(
        bucket: &mut Bucket<T>,
        debtor: address,
        buck_input_amount: u64,
    ): Balance<T> {
        let bottle = linked_table::borrow_mut(&mut bucket.bottle_table, debtor);
        assert!(bottle::get_buck_amount(bottle) >= buck_input_amount, ERepayTooMuch);
        let (is_fully_repaid, return_amount) = bottle::record_repay(bottle, buck_input_amount);
        if (is_fully_repaid) {
            bottle::destroy(linked_table::remove(&mut bucket.bottle_table, debtor));
        };
        balance::split(&mut bucket.vault, return_amount)
    }

    public(friend) fun handle_auto_redeem<T>(
        bucket: &mut Bucket<T>,
        oracle: &PriceFeed<T>,
        buck_input_amount: u64,
    ): Balance<T> {
        let remain_buck_amount = buck_input_amount;
        let (price, denominator) = get_price(oracle);
        let bottle_table = &mut bucket.bottle_table;
        let collateral_output = balance::zero();
        while(remain_buck_amount > 0 && linked_table::length(bottle_table) > 0) {
            let (debtor, bottle) = linked_table::pop_front(bottle_table);
            let bottle_buck_amount = get_buck_amount(&bottle);
            if (remain_buck_amount >= bottle_buck_amount) {
                let redeemed_amount = bottle::record_redeem(&mut bottle, price, denominator, bottle_buck_amount);
                balance::join(&mut collateral_output, balance::split(&mut bucket.vault, redeemed_amount));
                remain_buck_amount = remain_buck_amount - bottle_buck_amount;
                linked_table::push_back(bottle_table, debtor, bottle);
            } else {
                let redeemed_amount = bottle::record_redeem(&mut bottle, price, denominator, remain_buck_amount);
                balance::join(&mut collateral_output, balance::split(&mut bucket.vault, redeemed_amount));
                let prev_debtor = find_valid_insertion(bottle_table, &bottle, option::none());
                linked_table::insert_back(bottle_table, prev_debtor, debtor, bottle);
                break
            };
        };

        assert!(remain_buck_amount == 0, ENotEnoughToRedeem);
        collateral_output
    }

    public(friend) fun handle_flash_borrow<T>(
        bucket: &mut Bucket<T>,
        amount: u64
    ): (Balance<T>, FlashRecipit<T>) {
        bucket.flash_lock = true;
        let fee = amount / FLASH_LOAN_FEE_DIVISOR;
        if (fee == 0) fee = 1;
        (balance::split(&mut bucket.vault, amount), FlashRecipit { amount, fee })
    }

    public(friend) fun handle_flash_repay<T>(
        bucket: &mut Bucket<T>,
        repayment: Balance<T>,
        recipit: FlashRecipit<T>,
    ): Balance<T> {
        bucket.flash_lock = false;
        let FlashRecipit { amount, fee } = recipit;
        assert!(balance::value(&repayment) >= amount + fee, EFlashFeeNotEnough);
        let repayment_to_vault = balance::split(&mut repayment, amount);
        balance::join(&mut bucket.vault, repayment_to_vault);
        repayment
    }

    public fun debt_exists<T>(bucket: &Bucket<T>, debtor: address): bool {
        linked_table::contains(&bucket.bottle_table, debtor)
    }

    public fun get_bottle_info<T>(bucket: &Bucket<T>, debtor: address): (u64, u64) {
        let bottle = linked_table::borrow(&bucket.bottle_table, debtor);
        (bottle::get_collateral_amount(bottle), bottle::get_buck_amount(bottle))
    }

    public fun get_size<T>(bucket: &Bucket<T>): u64 {
        linked_table::length(&bucket.bottle_table)
    }

    public fun is_liquidateable<T>(
        bucket: &Bucket<T>,
        oracle: &PriceFeed<T>,
        debtor: address,
    ): bool {
        let (price, denominator) = get_price(oracle);
        assert!(debt_exists(bucket, debtor), EBottleNotFound);
        let (bottle_collateral_amount, bottle_buck_amount) = get_bottle_info(bucket, debtor);
        bottle_collateral_amount * price / denominator <=
            bottle_buck_amount * bucket.min_collateral_ratio / 100
    }

    fun borrow_internal<T>(
        bucket: &mut Bucket<T>,
        oracle: &PriceFeed<T>,
        borrower: address,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
    ): Bottle {
        assert!(!bucket.flash_lock, ECannotBorrowWithFlashLoan);
        let bottle = if(linked_table::contains(&bucket.bottle_table, borrower)) {
            linked_table::remove(&mut bucket.bottle_table, borrower)
        } else {
            bottle::new()
        };

        let collateral_amount = balance::value(&collateral_input);
        let (price, denominator) = get_price(oracle);

        bottle::record_borrow(
            &mut bottle,
            price, denominator, bucket.min_collateral_ratio,
            collateral_amount, buck_output_amount
        );

        balance::join(&mut bucket.vault, collateral_input);
        bottle
    }

    fun find_valid_insertion(
        bottle_table: &LinkedTable<address, Bottle>,
        bottle: &Bottle,
        start_debtor: Option<address>,
    ): Option<address> {

        let curr_debtor_opt = if (option::is_some(&start_debtor)) {
            start_debtor
        } else {
            *linked_table::front(bottle_table)
        };

        while (option::is_some(&curr_debtor_opt)) {
            let curr_debtor = *option::borrow(&curr_debtor_opt);
            let curr_bottle = linked_table::borrow(bottle_table, curr_debtor);
            if (bottle::cr_less_or_equal(bottle, curr_bottle)) {
                return option::none()
            };
            let next_debtor_opt = linked_table::next(bottle_table, curr_debtor);
            if (option::is_none(next_debtor_opt)) break;
            let next_debtor = *option::borrow(next_debtor_opt);
            let next_bottle = linked_table::borrow(bottle_table, next_debtor);
            if (bottle::cr_greater(bottle, curr_bottle) &&
                bottle::cr_less_or_equal(bottle, next_bottle)
            ) {
                break
            };
            curr_debtor_opt = *next_debtor_opt;
        };
        curr_debtor_opt
    }

    #[test_only]
    public fun check_bottle_order_in_bucket<T>(bucket: &Bucket<T>) {
        let bottle_table = &bucket.bottle_table;
        let debtor_opt = *linked_table::front(bottle_table);
        while(option::is_some(&debtor_opt)) {
            let curr_debtor = *option::borrow(&debtor_opt);
            let curr_bottle = linked_table::borrow(bottle_table, curr_debtor);
            bottle::print_bottle(curr_bottle);
            let next_debtor_opt = linked_table::next(bottle_table, curr_debtor);
            if (option::is_some(next_debtor_opt)) {
                let next_debtor = *option::borrow(next_debtor_opt);
                let next_bottle = linked_table::borrow(bottle_table, next_debtor);
                assert!(bottle::cr_less_or_equal(curr_bottle, next_bottle), 0);
            };
            debtor_opt = *next_debtor_opt;
        };
    }
}