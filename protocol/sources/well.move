module bucket_protocol::well {

    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use sui::object::{Self, UID};
    use bucket_framework::math::mul_factor;
    use bucket_protocol::bkt::BKT;

    friend bucket_protocol::buck;

    const S_FACTOR: u64 = 1000000000;

    struct Info has store {
        max_level: u64,
        current_level: u64,
    }

    struct Well<phantom T> has store, key {
        id: UID,
        pool: Balance<T>,
        staked: Balance<BKT>,
        current_s: u64,
    }

    struct WellToken<phantom T> has store, key {
        id: UID,
        stake_amount: u64,
        start_s: u64,
    }

    public(friend) fun new<T>(ctx: &mut TxContext): Well<T> {
        Well {
            id: object::new(ctx),
            pool: balance::zero(),
            staked: balance::zero(),
            current_s: 0,
        }
    }

    public fun stake<T>(well: &mut Well<T>, bkt_input: Balance<BKT>, ctx: &mut TxContext): WellToken<T> {
        let stake_amount = balance::value(&bkt_input);
        balance::join(&mut well.staked, bkt_input);
        
        WellToken {
            id: object::new(ctx),
            stake_amount,
            start_s: well.current_s,
        }
    }

    public(friend) fun collect_fee<T>(well: &mut Well<T>, input: Balance<T>) {
        let fee_amount = balance::value(&input);
        let total_staked_amount = balance::value(&well.staked);
        balance::join(&mut well.pool, input);
        well.current_s = well.current_s + mul_factor(fee_amount, S_FACTOR, total_staked_amount);
        std::debug::print(well);
    }

    public fun unstake<T>(well: &mut Well<T>, well_token: WellToken<T>): (Balance<BKT>, Balance<T>) {
        let WellToken { id, stake_amount, start_s } = well_token;
        object::delete(id);
        let reward_amount = mul_factor(stake_amount, well.current_s - start_s, S_FACTOR);
        (
            balance::split(&mut well.staked, stake_amount),
            balance::split(&mut well.pool, reward_amount),
        )
    }

    public fun claim<T>(well: &mut Well<T>, well_token: &mut WellToken<T>): Balance<T> {
        let reward_amount = mul_factor(well_token.stake_amount, well.current_s - well_token.start_s, S_FACTOR);
        well_token.start_s = well.current_s;
        balance::split(&mut well.pool, reward_amount)
    }

    public fun get_balance<T>(well: &Well<T>): u64 {
        balance::value(&well.pool)
    }

    #[test_only]
    public fun new_for_testing<T>(ctx: &mut TxContext): (Well<T>, WellToken<T>) {
        let well = new<T>(ctx);
        let init_bkt = balance::create_for_testing<BKT>(1000);
        let well_token = stake(&mut well, init_bkt, ctx);
        (well, well_token)
    }

    #[test_only]
    public fun destroy_for_testing<T>(well_token: WellToken<T>) {
        let WellToken { id, stake_amount: _, start_s: _ } = well_token;
        object::delete(id);
    }
}
