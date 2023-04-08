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

    use bucket_protocol::well::{Self, Well};
    use bucket_protocol::bucket::{Self, Bucket, FlashRecipit};
    use bucket_oracle::oracle::Oracle;

    // Constant

    const BORROW_BASE_FEE: u64 = 5; // 0.5%
    const REDEMTION_FEE: u64 = 5; // 0.5%

    // Errors
    const ERepayerNoDebt: u64 = 0;
    const ENotLiquidateable: u64 = 1;

    // Types

    struct BUCK has drop {}

    struct BucketType<phantom T> has copy, drop, store {}

    struct WellType<phantom T> has copy, drop, store {}

    struct BucketProtocol has key {
        id: UID,
        buck_treasury: TreasuryCap<BUCK>,
        buck_well: Well<BUCK>,
    }

    // Init

    fun init(witness: BUCK, ctx: &mut TxContext) {        
        transfer::share_object(new_protocol(witness, ctx));
    }

    fun new_protocol(witness: BUCK, ctx: &mut TxContext): BucketProtocol {
        let (buck_treasury, buck_metadata) = coin::create_currency(
            witness,
            8,
            b"BUCK",
            b"Bucket USD",
            b"stable coin minted by bucketprotocol.io",
            option::none(),
            ctx,
        );

        transfer::public_freeze_object(buck_metadata);
        let id = object::new(ctx);

        // first list SUI bucket and well for sure
        dof::add(&mut id, BucketType<SUI> {}, bucket::new<SUI>(115, ctx)); // MCR: 115%
        dof::add(&mut id, WellType<SUI> {}, well::new<SUI>(ctx));
        
        BucketProtocol {
            id,
            buck_treasury,
            buck_well: well::new(ctx),
        }
    } 

    // Functions

    public fun borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &Oracle,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        prev_debtor: Option<address>,
        ctx: &TxContext,
    ): Balance<BUCK> {
        // handle collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_borrow(bucket, oracle, collateral_input, buck_output_amount, prev_debtor, ctx);
        // mint BUCK
        mint_buck(protocol, buck_output_amount)
    }

    // for testing or when small size of bottle table, O(n) time complexity
    public fun auto_borrow<T>(
        protocol: &mut BucketProtocol,
        oracle: &Oracle,
        collateral_input: Balance<T>,
        buck_output_amount: u64,
        ctx: &TxContext,
    ): Balance<BUCK> {
        // handle collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_auto_borrow(bucket, oracle, collateral_input, buck_output_amount, ctx);
        // mint BUCK
        mint_buck(protocol, buck_output_amount)
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
        oracle: &Oracle,
        buck_input: Balance<BUCK>,
    ): Balance<T> {
        let buck_input_amount = balance::value(&buck_input);

        // burn BUCK
        burn_buck(protocol, buck_input);
        // return Redemption
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_auto_redeem<T>(bucket, oracle, buck_input_amount)
    }

    public fun is_liquidateable<T>(
        protocol: &BucketProtocol,
        oracle: &Oracle,
        debtor: address
    ): bool {
        let bucket = get_bucket<T>(protocol);
        bucket::is_liquidateable<T>(bucket, oracle, debtor)
    }

    public fun liquidate<T>(
        protocol: &mut BucketProtocol,
        oracle: &Oracle,
        buck_input: Balance<BUCK>,
        debtor: address,
    ): Balance<T> {
        assert!(is_liquidateable<T>(protocol, oracle, debtor), ENotLiquidateable);
        let buck_input_amount = balance::value(&buck_input);

        // burn BUCK
        burn_buck(protocol, buck_input);
        // return collateral
        let bucket = get_bucket_mut<T>(protocol);
        bucket::handle_repay<T>(bucket, debtor, buck_input_amount)
    }

    public fun get_bottle_info<T>(protocol: &BucketProtocol, debtor: address): (u64, u64) {
        let bucket = get_bucket<T>(protocol);
        bucket::get_bottle_info(bucket, debtor)
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
        coin::mint_balance(&mut protocol.buck_treasury, buck_amount)
    }

    fun burn_buck(protocol: &mut BucketProtocol, buck: Balance<BUCK>) {
        balance::decrease_supply(coin::supply_mut(&mut protocol.buck_treasury), buck);
    }

    #[test_only]
    public fun new_for_testing(witness: BUCK, ctx: &mut TxContext): BucketProtocol {
        new_protocol(witness, ctx)
    }

    #[test_only]
    use bucket_oracle::oracle;

    #[test]
    fun test_borrow(): (Oracle, oracle::AdminCap) {
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

        let seed = b"bucket protocol";
        vector::push_back(&mut seed, borrower_count);
        let rang = test_random::new(seed);
        let rangr = &mut rang;
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
                test_utils::assert_eq(balance::value(&buck_output), buck_output_amount);
                test_utils::assert_eq(bucket::get_size(get_bucket<SUI>(&protocol)), (idx as u64) + 1);
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