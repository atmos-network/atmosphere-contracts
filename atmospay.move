/// AtmosPay Agents: autonomous, non-custodial transaction execution.
/// Agents can onramp, offramp, swap, and trade on behalf of their owners.
/// Fully integrated with treasury, rewards, governance, and event logging.
module atmos::atmospay {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use atmos::token::{Self, ATMOS, Treasury};
    use atmos::rewards::{Self, RewardAccount};
    use atmos::governance::{Self, GovernanceParams};

    // ─── Errors ──────────────────────────────────────────────────────────────────
    const E_NOT_OWNER:           u64 = 1;
    const E_AGENT_INACTIVE:      u64 = 2;
    const E_ZERO_AMOUNT:         u64 = 3;
    const E_UNSUPPORTED_ACTION:  u64 = 4;
    const E_DAILY_LIMIT_EXCEEDED:u64 = 5;
    const E_COOLDOWN_ACTIVE:     u64 = 6;

    // ─── Constants ───────────────────────────────────────────────────────────────
    const COOLDOWN_MS:        u64 = 60 * 1000;   // 1 minute between txs
    const DAY_MS:             u64 = 86_400_000;
    const AGENT_REWARD_BPS:   u64 = 10;           // 0.1% of tx accrues as reward
    const BPS_DENOM:          u64 = 10_000;

    // ─── Action type constants ────────────────────────────────────────────────────
    const ACTION_ONRAMP:  vector<u8> = b"onramp";
    const ACTION_OFFRAMP: vector<u8> = b"offramp";
    const ACTION_SWAP:    vector<u8> = b"swap";
    const ACTION_TRADE:   vector<u8> = b"trade";

    // ─── Agent object (owned by user) ────────────────────────────────────────────
    struct Agent has key {
        id:            UID,
        owner:         address,
        active:        bool,
        daily_limit:   u64,         // max ATMOS per day (0 = unlimited)
        spent_today:   u64,
        day_start_ms:  u64,
        last_tx_ms:    u64,
        total_volume:  u64,
        tx_count:      u64,
    }

    /// Capability to authorize agent actions on behalf of owner.
    struct AgentCap has key, store {
        id:       UID,
        agent_id: ID,
        owner:    address,
    }

    // ─── Events ──────────────────────────────────────────────────────────────────
    struct AgentCreated has copy, drop {
        agent_id:    ID,
        owner:       address,
        daily_limit: u64,
    }
    struct AgentTxEvent has copy, drop {
        agent_id:  ID,
        to:        address,
        amount:    u64,
        action:    vector<u8>,
        timestamp: u64,
    }
    struct AgentDeactivated has copy, drop { agent_id: ID }
    struct AgentReactivated has copy, drop { agent_id: ID }
    struct DailyLimitUpdated has copy, drop { agent_id: ID, new_limit: u64 }

    // ─── Create agent ─────────────────────────────────────────────────────────────
    public entry fun create_agent(
        daily_limit: u64,
        clock:       &Clock,
        ctx:         &mut TxContext,
    ) {
        let owner = tx_context::sender(ctx);
        let now   = clock::timestamp_ms(clock);

        let agent = Agent {
            id:           object::new(ctx),
            owner,
            active:       true,
            daily_limit,
            spent_today:  0,
            day_start_ms: now,
            last_tx_ms:   0,
            total_volume: 0,
            tx_count:     0,
        };

        let agent_id = object::uid_to_inner(&agent.id);

        event::emit(AgentCreated { agent_id, owner, daily_limit });

        let cap = AgentCap {
            id:       object::new(ctx),
            agent_id,
            owner,
        };

        transfer::transfer(cap, owner);
        transfer::transfer(agent, owner);
    }

    // ─── Core transact ────────────────────────────────────────────────────────────
    public entry fun transact(
        agent:     &mut Agent,
        _cap:      &AgentCap,
        t:         &mut Treasury,
        params:    &GovernanceParams,
        acc:       &mut RewardAccount,
        recipient: address,
        amount:    u64,
        action:    vector<u8>,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ) {
        let now = clock::timestamp_ms(clock);

        // ── Auth & state guards ──
        assert!(agent.active, E_AGENT_INACTIVE);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(now >= agent.last_tx_ms + COOLDOWN_MS || agent.last_tx_ms == 0, E_COOLDOWN_ACTIVE);
        assert!(
            action == ACTION_ONRAMP  ||
            action == ACTION_OFFRAMP ||
            action == ACTION_SWAP    ||
            action == ACTION_TRADE,
            E_UNSUPPORTED_ACTION
        );

        // ── Daily limit reset ──
        if (now >= agent.day_start_ms + DAY_MS) {
            agent.spent_today  = 0;
            agent.day_start_ms = now;
        };

        // ── Daily limit check ──
        if (agent.daily_limit > 0) {
            assert!(agent.spent_today + amount <= agent.daily_limit, E_DAILY_LIMIT_EXCEEDED);
        };

        // ── Burn fee (governance-configured burn rate) ──
        let burn_bps  = governance::burn_rate_bps(params);
        let burn_amt  = amount * burn_bps / BPS_DENOM;
        let net_amt   = amount - burn_amt;

        // Mint full amount from treasury
        let mut coin = token::mint(t, amount, ctx);

        // Split and burn fee portion
        if (burn_amt > 0) {
            let burn_coin = coin::split(&mut coin, burn_amt, ctx);
            token::burn(t, burn_coin, ctx);
        };

        // ── Accrue agent reward to owner ──
        let reward_amt  = amount * AGENT_REWARD_BPS / BPS_DENOM;
        let agent_id    = object::uid_to_inner(&agent.id);
        rewards::accrue_agent_reward(acc, reward_amt, agent_id, ctx);

        // ── Update agent state ──
        agent.last_tx_ms   = now;
        agent.spent_today  = agent.spent_today + amount;
        agent.total_volume = agent.total_volume + amount;
        agent.tx_count     = agent.tx_count + 1;

        event::emit(AgentTxEvent {
            agent_id,
            to:        recipient,
            amount:    net_amt,
            action,
            timestamp: now,
        });

        transfer::public_transfer(coin, recipient);
    }

    // ─── Batch transact ───────────────────────────────────────────────────────────
    /// Execute multiple transactions in one PTB.
    public entry fun batch_transact(
        agent:      &mut Agent,
        _cap:       &AgentCap,
        t:          &mut Treasury,
        params:     &GovernanceParams,
        acc:        &mut RewardAccount,
        recipients: vector<address>,
        amounts:    vector<u64>,
        action:     vector<u8>,
        clock:      &Clock,
        ctx:        &mut TxContext,
    ) {
        let n = vector::length(&recipients);
        assert!(n == vector::length(&amounts), E_ZERO_AMOUNT);
        let mut i = 0;
        while (i < n) {
            let recipient = *vector::borrow(&recipients, i);
            let amount    = *vector::borrow(&amounts, i);
            transact(agent, _cap, t, params, acc, recipient, amount, action, clock, ctx);
            i = i + 1;
        };
    }

    // ─── Lifecycle management ─────────────────────────────────────────────────────
    public entry fun deactivate(agent: &mut Agent, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == agent.owner, E_NOT_OWNER);
        agent.active = false;
        event::emit(AgentDeactivated { agent_id: object::uid_to_inner(&agent.id) });
    }

    public entry fun reactivate(agent: &mut Agent, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == agent.owner, E_NOT_OWNER);
        agent.active = true;
        event::emit(AgentReactivated { agent_id: object::uid_to_inner(&agent.id) });
    }

    public entry fun update_daily_limit(
        agent:     &mut Agent,
        new_limit: u64,
        ctx:       &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == agent.owner, E_NOT_OWNER);
        agent.daily_limit = new_limit;
        event::emit(DailyLimitUpdated { agent_id: object::uid_to_inner(&agent.id), new_limit });
    }

    // ─── View helpers ─────────────────────────────────────────────────────────────
    public fun is_active(a: &Agent):      bool { a.active }
    public fun owner(a: &Agent):          address { a.owner }
    public fun daily_limit(a: &Agent):    u64 { a.daily_limit }
    public fun spent_today(a: &Agent):    u64 { a.spent_today }
    public fun total_volume(a: &Agent):   u64 { a.total_volume }
    public fun tx_count(a: &Agent):       u64 { a.tx_count }
    public fun last_tx_ms(a: &Agent):     u64 { a.last_tx_ms }
}
