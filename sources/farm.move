module staking_protocol::farm{

    use sui::coin::{Self, TreasuryCap};
    use std::option;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct FARM has drop{}

    fun init(witness: FARM, ctx: &mut TxContext) {

        // Create FARM currency with specified parameters
        let (treasury_cap, metadata) = coin::create_currency<FARM>(witness, 9, b"FARM", b"FARM", b"", option::none(), ctx);

        // Freeze the metadata object
        transfer::public_freeze_object(metadata);

         // Transfer treasury cap to contract owner
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    public entry fun mint(treasury_cap: &mut TreasuryCap<FARM>, amount: u64, recipient: address, ctx: &mut TxContext) {
        
        // Mint and transfer specified amount of tokens from the treasury to the recipient.
        coin::mint_and_transfer(treasury_cap, amount, recipient, ctx);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(FARM {}, ctx);
    }
}