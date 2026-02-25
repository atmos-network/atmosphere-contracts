/// Core ATMOS token, treasury management, mint/burn operations.
/// Friend-accessible by all protocol modules.
module atmos::token {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};

    // ─── Errors ─────────────────────────────────────────────────────────────────
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_ZERO_AMOUNT:    u64 = 2;
    const E_INSUFFICIENT:   u64 = 3;
    const E_CAP_EXCEEDED:   u64 = 4;

    // ─── Constants ───────────────────────────────────────────────────────────────
    const MAX_SUPPLY: u64 = 20_000_000_000_000_000; // 20 billion ATMOS (9 decimals)
    const DECIMALS:   u8  = 9;

    // ─── One-time witness ────────────────────────────────────────────────────────
    struct ATMOS has drop {}

    // ─── Shared objects ──────────────────────────────────────────────────────────
    struct Treasury has key {
        id:            UID,
        cap:           TreasuryCap<ATMOS>,
        total_minted:  u64,
        total_burned:  u64,
        admin:         address,
    }

    // ─── Events ──────────────────────────────────────────────────────────────────
    struct MintEvent has copy, drop {
        amount:    u64,
        recipient: address,
        minted_by: address,
    }

    struct BurnEvent has copy, drop {
        amount:  u64,
        burned_by: address,
    }

    struct TreasuryDepositEvent has copy, drop {
        amount: u64,
        from:   address,
    }

    // ─── Init ────────────────────────────────────────────────────────────────────
    fun init(witness: ATMOS, ctx: &mut TxContext) {
        let (cap, metadata) = coin::create_currency(
            witness,
            DECIMALS,
            b"ATMOS",
            b"ATMOS Governance Token",
            b"Governance and utility token for the ATMOS protocol",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(metadata);

        let treasury = Treasury {
            id:           object::new(ctx),
            cap,
            total_minted: 0,
            total_burned:  0,
            admin:        tx_context::sender(ctx),
        };
        transfer::share_object(treasury);
    }

    // ─── Mint ────────────────────────────────────────────────────────────────────
    public(friend) fun mint(
        t:      &mut Treasury,
        amount: u64,
        ctx:    &mut TxContext,
    ): Coin<ATMOS> {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(t.total_minted + amount <= MAX_SUPPLY, E_CAP_EXCEEDED);
        t.total_minted = t.total_minted + amount;
        event::emit(MintEvent {
            amount,
            recipient:  tx_context::sender(ctx),
            minted_by:  tx_context::sender(ctx),
        });
        coin::mint(&mut t.cap, amount, ctx)
    }

    /// Admin-gated public mint for bootstrapping/testing.
    public entry fun admin_mint(
        t:         &mut Treasury,
        amount:    u64,
        recipient: address,
        ctx:       &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == t.admin, E_NOT_AUTHORIZED);
        let coin = mint(t, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    // ─── Burn ────────────────────────────────────────────────────────────────────
    public(friend) fun burn(t: &mut Treasury, coin: Coin<ATMOS>, ctx: &mut TxContext) {
        let amount = coin::value(&coin);
        assert!(amount > 0, E_ZERO_AMOUNT);
        t.total_burned = t.total_burned + amount;
        coin::burn(&mut t.cap, coin);
        event::emit(BurnEvent { amount, burned_by: tx_context::sender(ctx) });
    }

    public entry fun user_burn(t: &mut Treasury, coin: Coin<ATMOS>, ctx: &mut TxContext) {
        burn(t, coin, ctx);
    }

    // ─── Split / Join helpers ────────────────────────────────────────────────────
    public fun split_coin(
        coin:   &mut Coin<ATMOS>,
        amount: u64,
        ctx:    &mut TxContext,
    ): Coin<ATMOS> {
        assert!(coin::value(coin) >= amount, E_INSUFFICIENT);
        coin::split(coin, amount, ctx)
    }

    // ─── View helpers ────────────────────────────────────────────────────────────
    public fun total_minted(t: &Treasury): u64 { t.total_minted }
    public fun total_burned(t: &Treasury):  u64 { t.total_burned }
    public fun circulating(t: &Treasury):   u64 { t.total_minted - t.total_burned }
    public fun max_supply():                u64 { MAX_SUPPLY }

    // ─── Friend declarations ─────────────────────────────────────────────────────
    friend atmos::locking;
    friend atmos::rewards;
    friend atmos::futarchy;
    friend atmos::atmospay;
}
