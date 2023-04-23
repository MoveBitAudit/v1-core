module bucket_protocol::tank {

    use sui::object::{Self, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;
    use sui::clock::{Self, Clock};
    use bucket_framework::math::mul_factor;
    use bucket_protocol::bkt::{Self, BKT, BktTreasury};

    friend bucket_protocol::buck;

    const BKT_FACTOR: u64 = 1000000;

    struct Tank<phantom BUCK, phantom T> has store, key {
        id: UID,
        reserve: Balance<BUCK>,
        liquidated: Balance<T>,
        current_p: u64,
        current_s: u64,
    }

    struct TankToken<phantom BUCK, phantom T> has store, key {
        id: UID,
        deposit_amount: u64,
        start_p: u64,
        start_s: u64,
        latest_claim_time: u64,
    }

    public(friend) fun new<BUCK, T>(ctx: &mut TxContext): Tank<BUCK, T> {
        Tank {
            id: object::new(ctx),
            reserve: balance::zero(),
            liquidated: balance::zero(),
            current_p: 1,
            current_s: 0,
        }
    }

    public fun deposit<BUCK, T>(
        clock: &Clock,
        tank: &mut Tank<BUCK, T>,
        deposit_input: Balance<BUCK>,
        ctx: &mut TxContext,
    ): TankToken<BUCK, T> {
        let deposit_amount = balance::value(&deposit_input);
        balance::join(&mut tank.reserve, deposit_input);
        TankToken {
            id: object::new(ctx),
            deposit_amount,
            start_p: tank.current_p,
            start_s: tank.current_s,
            latest_claim_time: clock::timestamp_ms(clock),
        }        
    }

    public(friend) fun absorb<BUCK, T>(
        tank: &mut Tank<BUCK, T>,
        collateral_input: Balance<T>,
        debt_amount: u64,
    ): Balance<BUCK> {
        let collateral_amount = balance::value(&collateral_input);
        let tank_reserve_amount = balance::value(&tank.reserve);
        tank.current_s = tank.current_s + mul_factor(
            tank.current_p,
            collateral_amount,
            tank_reserve_amount
        );
        tank.current_p = mul_factor(
            tank.current_p,
            tank_reserve_amount - debt_amount,
            tank_reserve_amount,
        );
        balance::join(&mut tank.liquidated, collateral_input);
        balance::split(&mut tank.reserve, debt_amount)
    }

    public fun withdraw<BUCK, T>(
        clock: &Clock,
        tank: &mut Tank<BUCK, T>,
        bkt_treasury: &mut BktTreasury,
        tank_token: TankToken<BUCK, T>,
    ): (Balance<BUCK>, Balance<T>, Balance<BKT>) {
        let TankToken { id, deposit_amount, start_p, start_s, latest_claim_time } = tank_token;
        object::delete(id);

        let withdrawal_amount = mul_factor(
            deposit_amount,
            tank.current_p,
            start_p,
        );
        let collateral_amount = mul_factor(
            deposit_amount,
            tank.current_s - start_s,
            start_p,
        );
        let bkt_output_amount = mul_factor(
            deposit_amount,
            clock::timestamp_ms(clock) - latest_claim_time,
            BKT_FACTOR,
        );
        (
            balance::split(&mut tank.reserve, withdrawal_amount),
            balance::split(&mut tank.liquidated, collateral_amount),
            bkt::claim(bkt_treasury, bkt_output_amount),
        )
    }

    public fun claim<BUCK, T>(
        clock: &Clock,
        bkt_treasury: &mut BktTreasury,
        tank_token: &mut TankToken<BUCK, T>,
    ): Balance<BKT> {
        let current_timestamp = clock::timestamp_ms(clock);
        let bkt_output_amount = mul_factor(
            tank_token.deposit_amount,
            current_timestamp - tank_token.latest_claim_time,
            BKT_FACTOR,
        );
        tank_token.latest_claim_time = current_timestamp;
        bkt::claim(bkt_treasury, bkt_output_amount)
    }

    public fun get_reserve_amount<BUCK, T>(tank: &Tank<BUCK, T>): u64 {
        balance::value(&tank.reserve)
    }
}
