/// ============================================================
/// ATMOS Protocol — Full Test Suite (25 test cases)
/// Run with: sui move test
/// ============================================================
#[test_only]
module atmos::tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID};
    use atmos::token::{Self, ATMOS, Treasury};
    use atmos::locking::{Self, VeLock};
    use atmos::delegation::{Self, DelegationReceipt};
    use atmos::voting::{Self, Proposal};
    use atmos::futarchy::{Self, Market, Bet};
    use atmos::rewards::{Self, RewardPool, RewardAccount};
    use atmos::governance::{Self, GovernanceParams};
    use atmos::atmospay::{Self, Agent, AgentCap};

    // ─── Test addresses ───────────────────────────────────────────────────────────
    const ADMIN:     address = @0xAA;
    const ALICE:     address = @0xA1;
    const BOB:       address = @0xB0;
    const CHARLIE:   address = @0xC0;
    const RESOLVER:  address = @0xRE;

    const MINT_AMOUNT: u64 = 1_000_000_000; // 1000 ATMOS

    // ─── Helpers ──────────────────────────────────────────────────────────────────

    fun setup(scenario: &mut Scenario): Clock {
        let clock = clock::create_for_testing(ts::ctx(scenario));
        clock
    }

    fun advance_time(clock: &mut Clock, ms: u64) {
        clock::increment_for_testing(clock, ms);
    }

    fun mint_to(scenario: &mut Scenario, recipient: address, amount: u64) {
        ts::next_tx(scenario, ADMIN);
        let mut t = ts::take_shared<Treasury>(scenario);
        token::admin_mint(&mut t, amount, recipient, ts::ctx(scenario));
        ts::return_shared(t);
    }

    // ─── TOKEN TESTS ──────────────────────────────────────────────────────────────

    /// TEST 1: Treasury initializes with correct state
    #[test]
    fun test_treasury_init() {
        let mut scenario = ts::begin(ADMIN);
        let clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let t = ts::take_shared<Treasury>(&scenario);
            assert!(token::total_minted(&t) == 0, 0);
            assert!(token::total_burned(&t) == 0, 1);
            assert!(token::max_supply() == 1_000_000_000_000_000, 2);
            ts::return_shared(t);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 2: Admin can mint tokens to recipient
    #[test]
    fun test_admin_mint() {
        let mut scenario = ts::begin(ADMIN);
        let clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            assert!(coin::value(&coin) == MINT_AMOUNT, 0);
            ts::return_to_sender(&scenario, coin);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let t = ts::take_shared<Treasury>(&scenario);
            assert!(token::total_minted(&t) == MINT_AMOUNT, 1);
            ts::return_shared(t);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 3: User can burn own tokens
    #[test]
    fun test_user_burn() {
        let mut scenario = ts::begin(ADMIN);
        let clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            token::user_burn(&mut t, coin, ts::ctx(&mut scenario));
            assert!(token::total_burned(&t) == MINT_AMOUNT, 0);
            ts::return_shared(t);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 4: Mint fails when max supply exceeded
    #[test]
    #[expected_failure(abort_code = token::E_CAP_EXCEEDED)]
    fun test_mint_exceeds_cap() {
        let mut scenario = ts::begin(ADMIN);
        let _clock = setup(&mut scenario);
        // Try to mint more than max supply
        mint_to(&mut scenario, ALICE, 1_000_000_000_000_001);
        ts::end(scenario);
    }

    // ─── LOCKING TESTS ────────────────────────────────────────────────────────────

    /// TEST 5: Lock creates veATMOS with correct voting power
    #[test]
    fun test_lock_creates_velock() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            let lock_duration = 365 * 24 * 60 * 60 * 1000u64; // 1 year
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve = ts::take_from_sender<VeLock>(&scenario);
            assert!(locking::amount(&ve) == MINT_AMOUNT, 0);
            let vp = locking::voting_power(&ve, &clock);
            assert!(vp > 0, 1);
            ts::return_to_sender(&scenario, ve);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 6: Voting power decays over time
    #[test]
    fun test_voting_power_decays() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        let vp_initial = {
            let ve = ts::take_from_sender<VeLock>(&scenario);
            let vp = locking::voting_power(&ve, &clock);
            ts::return_to_sender(&scenario, ve);
            vp
        };

        // Advance 180 days
        advance_time(&mut clock, 180 * 24 * 60 * 60 * 1000);

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve = ts::take_from_sender<VeLock>(&scenario);
            let vp_later = locking::voting_power(&ve, &clock);
            assert!(vp_later < vp_initial, 0);
            ts::return_to_sender(&scenario, ve);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 7: Early unlock charges 30% penalty
    #[test]
    fun test_early_unlock_penalty() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve = ts::take_from_sender<VeLock>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::early_unlock(&mut t, ve, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let expected = MINT_AMOUNT * 70 / 100; // 70% returned
            assert!(coin::value(&coin) == expected, 0);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 8: Normal unlock after expiry returns full amount
    #[test]
    fun test_normal_unlock_full_return() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 7 * 24 * 60 * 60 * 1000u64; // min lock: 7 days

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        // Advance past unlock time
        advance_time(&mut clock, lock_duration + 1);

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve = ts::take_from_sender<VeLock>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::unlock(&mut t, ve, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            assert!(coin::value(&coin) == MINT_AMOUNT, 0);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 9: Extend lock increases unlock time
    #[test]
    fun test_extend_lock() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);
        let lock_duration = 30 * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut ve = ts::take_from_sender<VeLock>(&scenario);
            let old_unlock = locking::unlock_time(&ve);
            locking::extend_lock(&mut ve, 30 * 24 * 60 * 60 * 1000, &clock, ts::ctx(&mut scenario));
            assert!(locking::unlock_time(&ve) > old_unlock, 0);
            ts::return_to_sender(&scenario, ve);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 10: Merge two locks combines amounts
    #[test]
    fun test_merge_locks() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 30 * 24 * 60 * 60 * 1000u64;

        // Create lock 1
        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        // Create lock 2
        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration * 2, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        // Merge
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut ve1 = ts::take_from_sender<VeLock>(&scenario);
            let ve2     = ts::take_from_sender<VeLock>(&scenario);
            locking::merge_locks(&mut ve1, ve2, ts::ctx(&mut scenario));
            assert!(locking::amount(&ve1) == MINT_AMOUNT * 2, 0);
            ts::return_to_sender(&scenario, ve1);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── DELEGATION TESTS ─────────────────────────────────────────────────────────

    /// TEST 11: Delegate voting power to another address
    #[test]
    fun test_delegate_voting_power() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut ve = ts::take_from_sender<VeLock>(&scenario);
            // Delegate 50% with 5% fee
            delegation::delegate(&mut ve, BOB, 5_000, 500, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, ve);
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let receipt = ts::take_from_sender<DelegationReceipt>(&scenario);
            assert!(delegation::receipt_delegate(&receipt) == BOB, 0);
            assert!(delegation::receipt_bps(&receipt) == 5_000, 1);
            ts::return_to_sender(&scenario, receipt);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── VOTING TESTS ─────────────────────────────────────────────────────────────

    /// TEST 12: Create and vote on proposal
    #[test]
    fun test_create_and_vote_proposal() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;
        let prop_duration = 7  * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve     = ts::take_from_sender<VeLock>(&scenario);
            let params = ts::take_shared<GovernanceParams>(&scenario);
            voting::create_proposal(
                &params, &ve,
                b"Increase Burn Rate", b"Proposal to increase burn rate to 1%",
                option::none(), prop_duration, &clock, ts::ctx(&mut scenario)
            );
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(params);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve          = ts::take_from_sender<VeLock>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            voting::vote(&mut proposal, &ve, true, &clock, ts::ctx(&mut scenario));
            assert!(voting::yes_votes(&proposal) > 0, 0);
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(proposal);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 13: Execute proposal after voting ends
    #[test]
    fun test_execute_proposal() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;
        let prop_duration = 7  * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve     = ts::take_from_sender<VeLock>(&scenario);
            let params = ts::take_shared<GovernanceParams>(&scenario);
            voting::create_proposal(&params, &ve, b"Test", b"Desc",
                option::none(), prop_duration, &clock, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(params);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve           = ts::take_from_sender<VeLock>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            voting::vote(&mut proposal, &ve, true, &clock, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(proposal);
        };

        advance_time(&mut clock, prop_duration + 1);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            let params       = ts::take_shared<GovernanceParams>(&scenario);
            voting::execute_proposal(&mut proposal, &params, &clock, ts::ctx(&mut scenario));
            // Check proposal resolved (status != 0)
            assert!(voting::status(&proposal) != 0, 0);
            ts::return_shared(proposal);
            ts::return_shared(params);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 14: Double voting is rejected
    #[test]
    #[expected_failure(abort_code = voting::E_ALREADY_VOTED)]
    fun test_double_vote_rejected() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;
        let prop_duration = 7  * 24 * 60 * 60 * 1000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve     = ts::take_from_sender<VeLock>(&scenario);
            let params = ts::take_shared<GovernanceParams>(&scenario);
            voting::create_proposal(&params, &ve, b"T", b"D",
                option::none(), prop_duration, &clock, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(params);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let ve           = ts::take_from_sender<VeLock>(&scenario);
            let mut proposal = ts::take_shared<Proposal>(&scenario);
            voting::vote(&mut proposal, &ve, true, &clock, ts::ctx(&mut scenario));
            voting::vote(&mut proposal, &ve, false, &clock, ts::ctx(&mut scenario)); // Should fail
            ts::return_to_sender(&scenario, ve);
            ts::return_shared(proposal);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── FUTARCHY TESTS ───────────────────────────────────────────────────────────

    /// TEST 15: Create market and place bets
    #[test]
    fun test_futarchy_bet() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);
        mint_to(&mut scenario, BOB, MINT_AMOUNT);

        let market_duration = 7 * 24 * 60 * 60 * 1000u64;
        let fake_proposal_id = object::id_from_address(@0x42);

        ts::next_tx(&mut scenario, ADMIN);
        {
            futarchy::create_market(
                fake_proposal_id, RESOLVER, market_duration, &clock, ts::ctx(&mut scenario)
            );
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut market = ts::take_shared<Market>(&scenario);
            futarchy::bet(&mut market, coin, true, &clock, ts::ctx(&mut scenario));
            ts::return_shared(market);
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut market = ts::take_shared<Market>(&scenario);
            futarchy::bet(&mut market, coin, false, &clock, ts::ctx(&mut scenario));
            assert!(futarchy::yes_pool_size(&market) == MINT_AMOUNT, 0);
            assert!(futarchy::no_pool_size(&market) == MINT_AMOUNT, 1);
            ts::return_shared(market);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 16: Resolve market and claim winnings
    #[test]
    fun test_futarchy_resolve_and_claim() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);
        mint_to(&mut scenario, BOB, MINT_AMOUNT);

        let market_duration = 7 * 24 * 60 * 60 * 1000u64;
        let fake_proposal_id = object::id_from_address(@0x42);

        ts::next_tx(&mut scenario, ADMIN);
        { futarchy::create_market(fake_proposal_id, RESOLVER, market_duration, &clock, ts::ctx(&mut scenario)); };

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut market = ts::take_shared<Market>(&scenario);
            futarchy::bet(&mut market, coin, true, &clock, ts::ctx(&mut scenario));
            ts::return_shared(market);
        };

        ts::next_tx(&mut scenario, BOB);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut market = ts::take_shared<Market>(&scenario);
            futarchy::bet(&mut market, coin, false, &clock, ts::ctx(&mut scenario));
            ts::return_shared(market);
        };

        advance_time(&mut clock, market_duration + 1);

        ts::next_tx(&mut scenario, RESOLVER);
        {
            let mut market = ts::take_shared<Market>(&scenario);
            futarchy::resolve(&mut market, true, &clock, ts::ctx(&mut scenario));
            assert!(futarchy::is_resolved(&market), 0);
            assert!(futarchy::yes_won(&market), 1);
            ts::return_shared(market);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut market = ts::take_shared<Market>(&scenario);
            let mut bet    = ts::take_from_sender<Bet>(&scenario);
            let mut t      = ts::take_shared<Treasury>(&scenario);
            futarchy::claim(&mut market, &mut bet, &mut t, ts::ctx(&mut scenario));
            ts::return_shared(market);
            ts::return_to_sender(&scenario, bet);
            ts::return_shared(t);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            // Alice bet 1000, Bob bet 1000. Alice wins → gets 2000 ATMOS
            assert!(coin::value(&coin) == MINT_AMOUNT * 2, 0);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── REWARDS TESTS ────────────────────────────────────────────────────────────

    /// TEST 17: Create reward account and deposit rewards
    #[test]
    fun test_reward_account_creation_and_deposit() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ADMIN, MINT_AMOUNT);

        ts::next_tx(&mut scenario, ALICE);
        { rewards::create_account(ts::ctx(&mut scenario)); };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin      = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut pool  = ts::take_shared<RewardPool>(&scenario);
            rewards::deposit_rewards(&mut pool, coin, ts::ctx(&mut scenario));
            assert!(rewards::pool_balance(&pool) == MINT_AMOUNT, 0);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 18: Advance epoch and accrue rewards
    #[test]
    fun test_reward_accrue_and_claim() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);
        mint_to(&mut scenario, ADMIN, MINT_AMOUNT);
        mint_to(&mut scenario, ALICE, MINT_AMOUNT);

        ts::next_tx(&mut scenario, ALICE);
        { rewards::create_account(ts::ctx(&mut scenario)); };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin     = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut pool = ts::take_shared<RewardPool>(&scenario);
            rewards::deposit_rewards(&mut pool, coin, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Lock ATMOS
        let lock_duration = 365 * 24 * 60 * 60 * 1000u64;
        ts::next_tx(&mut scenario, ALICE);
        {
            let coin = ts::take_from_sender<Coin<ATMOS>>(&scenario);
            let mut t = ts::take_shared<Treasury>(&scenario);
            locking::lock(&mut t, coin, lock_duration, &clock, ts::ctx(&mut scenario));
            ts::return_shared(t);
        };

        // Advance epoch
        advance_time(&mut clock, 7 * 24 * 60 * 60 * 1000 + 1);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<RewardPool>(&scenario);
            rewards::advance_epoch(&mut pool, 1_000_000, &clock, ts::ctx(&mut scenario));
            assert!(rewards::current_epoch(&pool) == 1, 0);
            ts::return_shared(pool);
        };

        // Accrue
        ts::next_tx(&mut scenario, ALICE);
        {
            let pool     = ts::take_shared<RewardPool>(&scenario);
            let mut acc  = ts::take_from_sender<RewardAccount>(&scenario);
            let ve       = ts::take_from_sender<VeLock>(&scenario);
            rewards::accrue(&pool, &mut acc, &ve, &clock, ts::ctx(&mut scenario));
            assert!(rewards::accrued(&acc) > 0, 0);
            ts::return_shared(pool);
            ts::return_to_sender(&scenario, acc);
            ts::return_to_sender(&scenario, ve);
        };

        // Claim
        ts::next_tx(&mut scenario, ALICE);
        {
            let mut pool = ts::take_shared<RewardPool>(&scenario);
            let mut acc  = ts::take_from_sender<RewardAccount>(&scenario);
            let mut t    = ts::take_shared<Treasury>(&scenario);
            rewards::claim(&mut pool, &mut acc, &mut t, ts::ctx(&mut scenario));
            assert!(rewards::accrued(&acc) == 0, 0);
            assert!(rewards::total_claimed(&acc) > 0, 1);
            ts::return_shared(pool);
            ts::return_to_sender(&scenario, acc);
            ts::return_shared(t);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── GOVERNANCE TESTS ─────────────────────────────────────────────────────────

    /// TEST 19: Update governance params (admin only)
    #[test]
    fun test_update_governance_params() {
        let mut scenario = ts::begin(ADMIN);
        let clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut params = ts::take_shared<GovernanceParams>(&scenario);
            governance::update_params(
                &mut params, 2_000, 100, 1_000, 14 * 24 * 60 * 60 * 1000,
                ts::ctx(&mut scenario)
            );
            assert!(governance::quorum(&params) == 2_000, 0);
            assert!(governance::burn_rate_bps(&params) == 100, 1);
            ts::return_shared(params);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 20: Non-admin cannot update params
    #[test]
    #[expected_failure(abort_code = governance::E_NOT_ADMIN)]
    fun test_non_admin_cannot_update_params() {
        let mut scenario = ts::begin(ADMIN);
        let clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut params = ts::take_shared<GovernanceParams>(&scenario);
            governance::update_params(&mut params, 0, 0, 0, 0, ts::ctx(&mut scenario));
            ts::return_shared(params);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ─── ATMOSPAY TESTS ───────────────────────────────────────────────────────────

    /// TEST 21: Create agent with daily limit
    #[test]
    fun test_create_agent() {
        let mut scenario = ts::begin(ALICE);
        let clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        {
            atmospay::create_agent(500_000_000, &clock, ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let agent = ts::take_from_sender<Agent>(&scenario);
            assert!(atmospay::is_active(&agent), 0);
            assert!(atmospay::owner(&agent) == ALICE, 1);
            assert!(atmospay::daily_limit(&agent) == 500_000_000, 2);
            ts::return_to_sender(&scenario, agent);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 22: Agent transacts onramp action
    #[test]
    fun test_agent_onramp() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        {
            atmospay::create_agent(0, &clock, ts::ctx(&mut scenario));
            rewards::create_account(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut agent  = ts::take_from_sender<Agent>(&scenario);
            let cap        = ts::take_from_sender<AgentCap>(&scenario);
            let mut t      = ts::take_shared<Treasury>(&scenario);
            let params     = ts::take_shared<GovernanceParams>(&scenario);
            let mut acc    = ts::take_from_sender<RewardAccount>(&scenario);

            atmospay::transact(
                &mut agent, &cap, &mut t, &params, &mut acc,
                BOB, 1_000_000, b"onramp", &clock, ts::ctx(&mut scenario)
            );

            assert!(atmospay::tx_count(&agent) == 1, 0);
            assert!(atmospay::total_volume(&agent) == 1_000_000, 1);

            ts::return_to_sender(&scenario, agent);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(t);
            ts::return_shared(params);
            ts::return_to_sender(&scenario, acc);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 23: Agent deactivation blocks transactions
    #[test]
    #[expected_failure(abort_code = atmospay::E_AGENT_INACTIVE)]
    fun test_inactive_agent_cannot_transact() {
        let mut scenario = ts::begin(ALICE);
        let mut clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        {
            atmospay::create_agent(0, &clock, ts::ctx(&mut scenario));
            rewards::create_account(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut agent = ts::take_from_sender<Agent>(&scenario);
            atmospay::deactivate(&mut agent, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, agent);
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut agent  = ts::take_from_sender<Agent>(&scenario);
            let cap        = ts::take_from_sender<AgentCap>(&scenario);
            let mut t      = ts::take_shared<Treasury>(&scenario);
            let params     = ts::take_shared<GovernanceParams>(&scenario);
            let mut acc    = ts::take_from_sender<RewardAccount>(&scenario);

            atmospay::transact(
                &mut agent, &cap, &mut t, &params, &mut acc,
                BOB, 100, b"swap", &clock, ts::ctx(&mut scenario)
            );

            ts::return_to_sender(&scenario, agent);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(t);
            ts::return_shared(params);
            ts::return_to_sender(&scenario, acc);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 24: Daily limit is enforced
    #[test]
    #[expected_failure(abort_code = atmospay::E_DAILY_LIMIT_EXCEEDED)]
    fun test_daily_limit_enforced() {
        let mut scenario = ts::begin(ALICE);
        let mut clock = setup(&mut scenario);
        let daily_limit = 100_000u64;

        ts::next_tx(&mut scenario, ALICE);
        {
            atmospay::create_agent(daily_limit, &clock, ts::ctx(&mut scenario));
            rewards::create_account(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut agent  = ts::take_from_sender<Agent>(&scenario);
            let cap        = ts::take_from_sender<AgentCap>(&scenario);
            let mut t      = ts::take_shared<Treasury>(&scenario);
            let params     = ts::take_shared<GovernanceParams>(&scenario);
            let mut acc    = ts::take_from_sender<RewardAccount>(&scenario);

            // Advance past cooldown
            advance_time(&mut clock, 90_000);

            // Try to send more than daily limit
            atmospay::transact(
                &mut agent, &cap, &mut t, &params, &mut acc,
                BOB, daily_limit + 1, b"trade", &clock, ts::ctx(&mut scenario)
            );

            ts::return_to_sender(&scenario, agent);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(t);
            ts::return_shared(params);
            ts::return_to_sender(&scenario, acc);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// TEST 25: Cooldown period between transactions
    #[test]
    #[expected_failure(abort_code = atmospay::E_COOLDOWN_ACTIVE)]
    fun test_cooldown_enforced() {
        let mut scenario = ts::begin(ALICE);
        let mut clock = setup(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        {
            atmospay::create_agent(0, &clock, ts::ctx(&mut scenario));
            rewards::create_account(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ALICE);
        {
            let mut agent  = ts::take_from_sender<Agent>(&scenario);
            let cap        = ts::take_from_sender<AgentCap>(&scenario);
            let mut t      = ts::take_shared<Treasury>(&scenario);
            let params     = ts::take_shared<GovernanceParams>(&scenario);
            let mut acc    = ts::take_from_sender<RewardAccount>(&scenario);

            // First tx
            atmospay::transact(
                &mut agent, &cap, &mut t, &params, &mut acc,
                BOB, 100, b"swap", &clock, ts::ctx(&mut scenario)
            );

            // Second tx immediately (no cooldown advance) — should fail
            atmospay::transact(
                &mut agent, &cap, &mut t, &params, &mut acc,
                BOB, 100, b"swap", &clock, ts::ctx(&mut scenario)
            );

            ts::return_to_sender(&scenario, agent);
            ts::return_to_sender(&scenario, cap);
            ts::return_shared(t);
            ts::return_shared(params);
            ts::return_to_sender(&scenario, acc);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
