module bucket_framework::utils {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::transfer;
    use sui::tx_context::TxContext;

    public fun transfer_non_zero_coin<T>(coin: Coin<T>, recipient: address) {
        if (coin::value(&coin) == 0) {
            coin::destroy_zero(coin);
        } else {
            transfer::public_transfer(coin, recipient);
        }
    }

    public fun transfer_non_zero_balance<T>(balance: Balance<T>, recipient: address, ctx: &mut TxContext) {
        if (balance::value(&balance) == 0) {
            balance::destroy_zero(balance);
        } else {
            transfer::public_transfer(coin::from_balance(balance, ctx), recipient);
        }

    }

    #[test]
    fun test_transfer_non_zero() {
        use sui::test_scenario;
        use sui::sui::SUI;
        use std::vector;
        use std::debug;

        let sender = @0xde1;
        let recipient_1 = @0x111;
        let recipient_2 = @0x222;

        let scenario_val = test_scenario::begin(sender);
        let scenario = &mut scenario_val;

        let transfer_amount = 1000;

        test_scenario::next_tx(scenario, sender);
        {
            let sui_balance_0 = balance::create_for_testing<SUI>(0);
            let sui_balance_1 = balance::create_for_testing<SUI>(transfer_amount);
            transfer_non_zero_balance(sui_balance_0, recipient_1, test_scenario::ctx(scenario));
            transfer_non_zero_balance(sui_balance_1, recipient_1, test_scenario::ctx(scenario));
        };

        test_scenario::next_tx(scenario, recipient_1);
        {
            let sui_coin_ids = test_scenario::ids_for_sender<Coin<SUI>>(scenario);
            debug::print(&sui_coin_ids);
            assert!(vector::length(&sui_coin_ids) == 1, 0);
            let coin_id = *vector::borrow(&sui_coin_ids, 0);
            let sui_coin = test_scenario::take_from_sender_by_id<Coin<SUI>>(scenario, coin_id);
            debug::print(&sui_coin);
            assert!(coin::value(&sui_coin) == transfer_amount, 1);
            test_scenario::return_to_sender(scenario, sui_coin);
        };

        let transfer_amount = 2500;

        test_scenario::next_tx(scenario, sender);
        {
            let sui_coin_0 = coin::from_balance(
                balance::create_for_testing<SUI>(transfer_amount),
                test_scenario::ctx(scenario),
            );
            let sui_coin_1 = coin::from_balance(
                balance::create_for_testing<SUI>(0),
                test_scenario::ctx(scenario),
            );

            transfer_non_zero_coin(sui_coin_0, recipient_2);
            transfer_non_zero_coin(sui_coin_1, recipient_2);
        };

        test_scenario::next_tx(scenario, recipient_2);
        {
            let sui_coin_ids = test_scenario::ids_for_sender<Coin<SUI>>(scenario);
            debug::print(&sui_coin_ids);
            assert!(vector::length(&sui_coin_ids) == 1, 0);
            let coin_id = *vector::borrow(&sui_coin_ids, 0);
            let sui_coin = test_scenario::take_from_sender_by_id<Coin<SUI>>(scenario, coin_id);
            debug::print(&sui_coin);
            assert!(coin::value(&sui_coin) == transfer_amount, 1);
            test_scenario::return_to_sender(scenario, sui_coin);
        };

        test_scenario::end(scenario_val);
    }
}