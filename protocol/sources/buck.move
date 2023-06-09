module bucket_protocol::buck {

    // Dependecies

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, TreasuryCap};
    use sui::sui::SUI;
    use sui::dynamic_object_field as dof;
    use std::option::{Self, Option};

    use bucket_framework::math::mul_factor;
    use bucket_protocol::well::{Self, Well, WellToken};
    use bucket_protocol::bucket::{Self, Bucket, FlashRecipit};
    use bucket_protocol::tank::{Self, Tank};
    use bucket_protocol::bkt::BKT;
    use bucket_oracle::oracle::BucketOracle;

    // Constant
    const BORROW_BASE_FEE: u64 = 5; // 0.5%
    const REDEMTION_BASE_FEE: u64 = 5; // 0.5%
    const LIQUIDATION_REBATE: u64 = 5; // 0.5%

    // Errors
    const EBorrowTooSmall: u64 = 0;
    const ERepayerNoDebt: u64 = 1;
    const ENotLiquidateable: u64 = 2;
    const EBucketAlreadyExists: u64 = 3;
    const ETankNotEnough: u64 = 4;

    // Types

    struct BUCK has drop {}

    struct BucketProtocol has key {
        id: UID,
        buck_treasury_cap: TreasuryCap<BUCK>,
    }

    struct BucketType<phantom T> has copy, drop, store {}

    struct WellType<phantom T> has copy, drop, store {}

    struct AdminCap has key { id: UID } // Admin can create new bucket

    // Init

    fun init(witness: BUCK, ctx: &mut TxContext) {     
        let protocol = new_protocol(witness, ctx);

        // create wells for SUI and BUCK
        dof::add(&mut protocol.id, WellType<BUCK> {}, well::new<BUCK>(ctx));
        dof::add(&mut protocol.id, WellType<SUI> {}, well::new<SUI>(ctx));

        transfer::share_object(protocol);
        transfer::transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
    }

    fun new_protocol(witness: BUCK, ctx: &mut TxContext): BucketProtocol {
        let (buck_treasury_cap, buck_metadata) = coin::create_currency(
            witness,
            9,
            b"BUCK",
            b"Bucket USD",
            b"stable coin minted by bucketprotocol.io",
            option::some(url::new_unsafe_from_bytes(
                b"https://ipfs.io/ipfs/QmTgFBXPfTHj3Ao4MjZ3JhaDbZQBpSMiNwksQ1xUT3yhZX")
            ),
            ctx,
        );

        transfer::public_freeze_object(buck_metadata);
        let id = object::new(ctx);

        // create SUI bucket
        dof::add(&mut id, BucketType<SUI> {}, bucket::new<SUI>(110, ctx));

        BucketProtocol { id, buck_treasury_cap }
    } 

    // Functions

    public fun borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &BucketOracle,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        prev_debtor: Option<address>,
        ctx: &mut TxContext,
    ): Balance<BUCK> {
        // handle collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_borrow(bucket, oracle, collateral_input, buck_output_amount, prev_debtor, ctx);
        // mint BUCK and charge borrow fee
        let buck_output = mint_buck(protocol, buck_output_amount);
        let fee_amount = mul_factor(buck_output_amount, BORROW_BASE_FEE, 1000);
        let fee = balance::split(&mut buck_output, fee_amount);
        well::collect_fee(get_well_mut<BUCK>(protocol), fee);
        buck_output
    }

    // for testing or when small size of bottle table, O(n) time complexity
    public fun auto_borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &BucketOracle,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        ctx: &mut TxContext,
    ): Balance<BUCK> {
        // handle collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_auto_borrow(bucket, oracle, collateral_input, buck_output_amount, ctx);
        // mint BUCK
        let buck_output = mint_buck(protocol, buck_output_amount);
        let fee_amount = mul_factor(buck_output_amount, BORROW_BASE_FEE, 1000);
        let fee = balance::split(&mut buck_output, fee_amount);
        well::collect_fee(get_well_mut<BUCK>(protocol), fee);
        buck_output
    }

    public fun repay<T>(
        protocol: &mut BucketProtocol,
        buck_input: Balance<BUCK>,
        ctx: &TxContext,
    ): Balance<T> {
        let debtor = tx_context::sender(ctx);
        let buck_input_amount = balance::value(&buck_input);

        // burn BUCK
        burn_buck(protocol, buck_input);
        // return collateral
        let bucket = get_bucket_mut<T>(protocol);
        assert!(bucket::debt_exists(bucket, debtor), ERepayerNoDebt);
        bucket::handle_repay<T>(bucket, debtor, buck_input_amount)
    }

    public fun auto_redeem<T>(
        protocol: &mut BucketProtocol,
        oracle: &BucketOracle,
        buck_input: Balance<BUCK>,
    ): Balance<T> {
        let buck_input_amount = balance::value(&buck_input);

        // burn BUCK
        burn_buck(protocol, buck_input);
        // return Redemption
        let bucket = get_bucket_mut<T>(protocol);
        let collateral_output = bucket::handle_auto_redeem<T>(bucket, oracle, buck_input_amount);
        let collateral_output_amount = balance::value(&collateral_output);
        let fee_amount = mul_factor(collateral_output_amount, REDEMTION_BASE_FEE, 1000);
        let fee = balance::split(&mut collateral_output, fee_amount);
        well::collect_fee(get_well_mut<T>(protocol), fee);
        collateral_output
    }

    public fun is_liquidateable<T>(
        protocol: &BucketProtocol,
        oracle: &BucketOracle,
        debtor: address
    ): bool {
        let bucket = get_bucket<T>(protocol);
        bucket::is_liquidateable<T>(bucket, oracle, debtor)
    }

    public fun liquidate_with_tank<T>(
        protocol: &mut BucketProtocol,
        oracle: &BucketOracle,
        tank: &mut Tank<BUCK, T>,
        debtor: address,
    ): Balance<T> {
        assert!(is_liquidateable<T>(protocol, oracle, debtor), ENotLiquidateable);
        let bucket = get_bucket_mut<T>(protocol);
        let (collateral_amount, buck_amount) = bucket::get_bottle_info(bucket, debtor);
        let collateral_return = bucket::handle_repay<T>(bucket, debtor, buck_amount);
        let rebate_amount = mul_factor(collateral_amount, LIQUIDATION_REBATE, 1000);
        let rebate = balance::split(&mut collateral_return, rebate_amount);

        // absorb debt
        assert!(tank::get_reserve_amount(tank) > buck_amount, ETankNotEnough);
        let buck_to_burn = tank::absorb(tank, collateral_return, buck_amount);

        // burn BUCK
        burn_buck(protocol, buck_to_burn);
        // return rebate
        rebate
    }

    public fun liquidate<T>(
        protocol: &mut BucketProtocol,
        oracle: &BucketOracle,
        tank: &Tank<BUCK, T>,
        buck_input: Balance<BUCK>,
        debtor: address,
    ): Balance<T> {
        assert!(is_liquidateable<T>(protocol, oracle, debtor), ENotLiquidateable);
        let (_, buck_amount) = get_bottle_info<T>(protocol, debtor);
        assert!(tank::get_reserve_amount(tank) <= buck_amount, ETankNotEnough);
        let buck_input_amount = balance::value(&buck_input);

        // burn BUCK
        burn_buck(protocol, buck_input);
        // return collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_repay<T>(bucket, debtor, buck_input_amount)
    }

    public fun flash_borrow<T>(
        protocol: &mut BucketProtocol,
        amount: u64
    ): (Balance<T>, FlashRecipit<T>) {
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_flash_borrow(bucket, amount)
    }

    public fun flash_repay<T>(
        protocol: &mut BucketProtocol,
        repayment: Balance<T>,
        recipit: FlashRecipit<T>
    ) {
        let bucket = get_bucket_mut<T>(protocol);
        let fee = bucket::handle_flash_repay(bucket, repayment, recipit);

        let well = get_well_mut<T>(protocol);
        well::collect_fee(well, fee);
    }

    public fun stake<T>(
        protocol: &mut BucketProtocol,
        bkt_input: Balance<BKT>,
        ctx: &mut TxContext,
    ): WellToken<T> {
        let well = get_well_mut<T>(protocol);
        well::stake(well, bkt_input, ctx)
    }

    public fun unstake<T>(
        protocol: &mut BucketProtocol,
        well_token: WellToken<T>,
    ): (Balance<BKT>, Balance<T>) {
        let well = get_well_mut<T>(protocol);
        well::unstake(well, well_token)
    }

    public fun claim<T>(
        protocol: &mut BucketProtocol,
        well_token: &mut WellToken<T>,
    ): Balance<T> {
        let well = get_well_mut<T>(protocol);
        well::claim(well, well_token)
    }

    public fun get_bottle_info<T>(protocol: &BucketProtocol, debtor: address): (u64, u64) {
        let bucket = get_bucket<T>(protocol);
        bucket::get_bottle_info(bucket, debtor)
    }

    public fun get_bucket_size<T>(protocol: &BucketProtocol): u64 {
        bucket::get_size(get_bucket<T>(protocol))
    }

    public fun get_bucket_balance<T>(protocol: &BucketProtocol): u64 {
        bucket::get_balance(get_bucket<T>(protocol))
    }

    public fun get_well_balance<T>(protocol: &BucketProtocol): u64 {
        well::get_balance(get_well<T>(protocol))
    }

    public entry fun create_bucket<T>(
        protocol: &mut BucketProtocol,
        _:&AdminCap,
        min_collateral_ratio: u64,
        ctx: &mut TxContext,
    ) {
        let bucket_type = BucketType<T> {};
        let well_type = WellType<T> {};
        assert!(
            !dof::exists_with_type<BucketType<T>, Bucket<T>>(&protocol.id, bucket_type) &&
                !dof::exists_with_type<WellType<T>, Well<T>>(&protocol.id, well_type),
            EBucketAlreadyExists,
        );
        dof::add(&mut protocol.id, bucket_type, bucket::new<T>(min_collateral_ratio, ctx));
        dof::add(&mut protocol.id, well_type, well::new<T>(ctx));
        transfer::public_share_object(tank::new<BUCK, T>(ctx));
    }

    fun get_bucket<T>(protocol: &BucketProtocol): &Bucket<T> {
        dof::borrow<BucketType<T>, Bucket<T>>(&protocol.id, BucketType<T> {})
    }

    fun get_bucket_mut<T>(protocol: &mut BucketProtocol): &mut Bucket<T> {
        dof::borrow_mut<BucketType<T>, Bucket<T>>(&mut protocol.id, BucketType<T> {})
    }

    fun get_well<T>(protocol: &BucketProtocol): &Well<T> {
        dof::borrow<WellType<T>, Well<T>>(&protocol.id, WellType<T> {})
    }

    fun get_well_mut<T>(protocol: &mut BucketProtocol): &mut Well<T> {
        dof::borrow_mut<WellType<T>, Well<T>>(&mut protocol.id, WellType<T> {})
    }

    fun mint_buck(protocol: &mut BucketProtocol, buck_amount: u64): Balance<BUCK> {
        coin::mint_balance(&mut protocol.buck_treasury_cap, buck_amount)
    }

    fun burn_buck(protocol: &mut BucketProtocol, buck: Balance<BUCK>) {
        balance::decrease_supply(coin::supply_mut(&mut protocol.buck_treasury_cap), buck);
    }

    #[test_only]
    public fun new_for_testing(witness: BUCK, ctx: &mut TxContext): (BucketProtocol, WellToken<BUCK>, WellToken<SUI>) {
        let protocol = new_protocol(witness, ctx);
        let (buck_well, buck_well_token) = well::new_for_testing<BUCK>(ctx);
        let (sui_well, sui_well_token) = well::new_for_testing<SUI>(ctx);
        dof::add(&mut protocol.id, WellType<BUCK> {}, buck_well);
        dof::add(&mut protocol.id, WellType<SUI> {}, sui_well);
        (protocol, buck_well_token, sui_well_token)
    }

    #[test_only]
    use bucket_oracle::oracle;
    use sui::url;

    #[test]
    fun test_borrow(): (BucketOracle, oracle::AdminCap) {
        use sui::test_scenario;
        use sui::test_utils;
        use sui::test_random;
        use sui::address;
        use std::vector;

        let dev = @0xde1;
        let borrowers = vector<address>[];
        let borrower_count = 12;
        let idx = 1u8;
        while (idx <= borrower_count) {
            vector::push_back(&mut borrowers, address::from_u256((idx as u256) + 10));
            idx = idx + 1;
        };

        let scenario_val = test_scenario::begin(dev);
        let scenario = &mut scenario_val;
        {
            init(test_utils::create_one_time_witness<BUCK>(), test_scenario::ctx(scenario));
        };

        let (oracle, ocap) = oracle::new_for_testing<SUI>(1000,test_scenario::ctx(scenario));

        test_scenario::next_tx(scenario, dev);
        {
            let protocol = test_scenario::take_shared<BucketProtocol>(scenario);
            let buck_wt = stake<BUCK>(&mut protocol, balance::create_for_testing<BKT>(1000), test_scenario::ctx(scenario));
            let sui_wt = stake<SUI>(&mut protocol, balance::create_for_testing<BKT>(1000), test_scenario::ctx(scenario));
            transfer::public_transfer(buck_wt, dev);
            transfer::public_transfer(sui_wt, dev);
            test_scenario::return_shared(protocol);
        };

        let seed = b"bucket protocol";
        vector::push_back(&mut seed, borrower_count);
        let rang = test_random::new(seed);
        let rangr = &mut rang;
        let cumulative_fee_amount = 0;
        idx = 0;
        while (idx < borrower_count) {
            let borrower = *vector::borrow(&borrowers, (idx as u64));
            test_scenario::next_tx(scenario, borrower);
            {
                let protocol = test_scenario::take_shared<BucketProtocol>(scenario);

                let oracle_price = 500 + test_random::next_u64(rangr) % 2000;
                oracle::update_price<SUI>(&ocap, &mut oracle, oracle_price);

                let sui_input_amount = 1000000 * (test_random::next_u8(rangr) as u64) + test_random::next_u64(rangr) % 100000000;
                let sui_input = balance::create_for_testing<SUI>(sui_input_amount);

                let buck_output_amount = test_random::next_u64(rangr) % 50000000;

                let buck_output = auto_borrow(
                    &mut protocol,
                    &oracle,
                    sui_input,
                    buck_output_amount,
                    test_scenario::ctx(scenario),
                );
                let fee_amount = mul_factor(buck_output_amount, BORROW_BASE_FEE, 1000);
                cumulative_fee_amount = cumulative_fee_amount + fee_amount;
                assert!(balance::value(&buck_output) == buck_output_amount - fee_amount, 0);
                assert!(get_well_balance<BUCK>(&protocol) == cumulative_fee_amount, 1);
                assert!(get_bucket_size<SUI>(&protocol) == (idx as u64) + 1, 2);
                balance::destroy_for_testing(buck_output);

                test_scenario::return_shared(protocol);
            };
            idx = idx + 1;
        };

        test_scenario::next_tx(scenario, dev);
        {
            let protocol = test_scenario::take_shared<BucketProtocol>(scenario);
            test_utils::print(b"---------- Bottle Table Result ----------");
            bucket::check_bottle_order_in_bucket(get_bucket<SUI>(&protocol));
            test_scenario::return_shared(protocol);
        };

        test_scenario::end(scenario_val);
        (oracle, ocap)
    }
}
