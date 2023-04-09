#[test_only]
module bucket_protocol::test_redeem {

    use sui::balance;
    use sui::test_scenario;
    use sui::sui::SUI;
    use sui::test_utils;
    use std::debug;
    use bucket_framework::math::mul_factor;
    use bucket_protocol::buck::{Self, BUCK, BucketProtocol};
    use bucket_oracle::oracle::{Self, BucketOracle, AdminCap};

    #[test]
    fun test_redeem(): (BucketProtocol, BucketOracle, AdminCap) {
        let dev = @0xde1;
        let borrower = @0x111;
        let redeemer = @0x222;

        let scenario_val = test_scenario::begin(dev);
        let scenario = &mut scenario_val;

        let protocol = buck::new_for_testing( test_utils::create_one_time_witness<BUCK>(), test_scenario::ctx(scenario));
        let (oracle, ocap) = oracle::new_for_testing<SUI>(1000,test_scenario::ctx(scenario));

        let sui_input_amount = 1000000;
        let buck_output_amount = 1200000;
        let buck_for_redemption_amount = buck_output_amount / 2;

        test_scenario::next_tx(scenario, borrower);
        {
            oracle::update_price<SUI>(&ocap, &mut oracle, 2000);
            let sui_input = balance::create_for_testing<SUI>(sui_input_amount);
            let buck_output = buck::auto_borrow(&mut protocol, &oracle, sui_input, buck_output_amount, test_scenario::ctx(scenario));
            debug::print(&buck_output);
            test_utils::assert_eq(balance::value(&buck_output), mul_factor(buck_output_amount,995, 1000));
            balance::destroy_for_testing(buck_output);
        };

        test_scenario::next_tx(scenario, redeemer);
        {
            oracle::update_price<SUI>(&ocap, &mut oracle, 4000);
            let (price, denominator) = oracle::get_price<SUI>(&oracle);
            let buck_input = balance::create_for_testing<BUCK>(buck_for_redemption_amount);
            let sui_output = buck::auto_redeem<SUI>(&mut protocol, &oracle, buck_input);
            debug::print(&sui_output);
            let sui_value = mul_factor(balance::value(&sui_output), price, denominator);
            test_utils::assert_eq(sui_value, mul_factor(buck_for_redemption_amount, 995, 1000));
            balance::destroy_for_testing(sui_output);
        };

        test_scenario::end(scenario_val);
        (protocol, oracle, ocap)
    }
}
