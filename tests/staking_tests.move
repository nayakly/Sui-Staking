#[test_only]
module staking_protocol::staking_tests{

    use staking_protocol::farm::{Self, FARM};
    use staking_protocol::vault::{Self, RewardState, UserState, Treasury, AdminCap};
    use sui::clock;
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario;
    use sui::math;

    /*
     Scenario: 
     - At 1s, Owner sets 
        - Reward duration as 10s
        - Reward amount as 1000 FARM tokens at 1s.
     - At 2s, John stakes 10 SUI 
     - At 4s, Elise stakes 20 SUI 
     - At 6s, John stakes additional 30 SUI 
     - At 8s, Elise Withdraws stake of 20 SUI 
     - At 9s, John withdraws stake of 40 SUI 

     Expected Result:
     - Rewards are active from 1 to 11s
     - Reward Rate is 1000/10 = 100 FARM/s
     - John should earn 500 FARM tokens
     - Elise should earn 200 FARM tokens
     - Vault has 300 FARM tokens left
    */

    const EIncorrectRewardRate: u64 = 101;
    const EIncorrectRewardBalance: u64 = 102;
    const EIncorrectUserReward: u64 = 103;

    #[test]
    fun test_example(){

        let owner = @0x1;
        let john = @0x2;
        let elise = @0x3;

        let scenario_val = test_scenario::begin(owner);
        let scenario = &mut scenario_val;
        {   // Owner deploys the contracts
            let ctx = test_scenario::ctx(scenario);
            farm::init_for_testing(ctx);
            vault::init_for_testing(ctx);
        };
        test_scenario::next_tx(scenario, owner); // Owner initiates the staking rewards at 1s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);
            let adminCap = test_scenario::take_from_sender<AdminCap>(scenario);
            let duration = 10;

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 1);
            let num_coins = 1000 * math::pow(10, 9);
            let farm = coin::mint_for_testing<FARM>(num_coins, ctx);

            // Owner initiates the staking rewards 
            vault::setRewardDuration(&adminCap, &mut rewardState, duration, &clock);
            vault::setRewardAmount(&adminCap, farm, &mut userState, &mut rewardState, &mut treasury, &clock);
            
            // Check that the reward rate has been correctly set 
            let rewardRate = vault::getRewardRate(&rewardState);
            assert!(rewardRate == 100 * math::pow(10, 9), EIncorrectRewardRate);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            test_scenario::return_to_sender(scenario, adminCap);
            clock::destroy_for_testing(clock);
        };
        test_scenario::next_tx(scenario, john);  // John stakes 10 Sui at 2s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 2);
            let num_coins = 10 * math::pow(10, 9); 
            let sui = coin::mint_for_testing<SUI>(num_coins, ctx);

            // John stakes 10 Sui
            vault::stake(sui, &mut userState, &mut rewardState, &mut treasury, &clock, ctx);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        test_scenario::next_tx(scenario, elise); // Elise stakes 20 Sui at 4s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 4);
            let num_coins = 20 * math::pow(10, 9); 
            let sui = coin::mint_for_testing<SUI>(num_coins, ctx);

            // Elise stakes 20 Sui
            vault::stake(sui, &mut userState, &mut rewardState, &mut treasury, &clock, ctx);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        test_scenario::next_tx(scenario, john); // John stakes additional 30 Sui at 6s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 6);
            let num_coins = 30 * math::pow(10, 9); 
            let sui = coin::mint_for_testing<SUI>(num_coins, ctx);

            // John stakes 30 Sui
            vault::stake(sui, &mut userState, &mut rewardState, &mut treasury, &clock, ctx);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        test_scenario::next_tx(scenario, elise); // Elise withdraws her stake of 20 Sui at 8s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 8);
            let num_coins = 20 * math::pow(10, 9); 

            // Elise withdraws 20 Sui
            vault::withdraw(&mut userState, &mut rewardState, &mut treasury, num_coins, &clock, ctx);

            // Verify that Elise earns ~200 FARM tokens
            let userReward = vault::getUserRewardBalance(&userState, ctx);
            assert!(userReward <= 200 * math::pow(10, 9), EIncorrectUserReward);
            vault::getReward(&mut userState, &mut rewardState, &mut treasury, &clock, ctx);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
         test_scenario::next_tx(scenario, john); // John withdraws his stake of 40 SUI at 9s
        {   // Fetch necessary objects
            let rewardState = test_scenario::take_shared<RewardState>(scenario);
            let userState = test_scenario::take_shared<UserState>(scenario);
            let treasury = test_scenario::take_shared<Treasury>(scenario);

            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::increment_for_testing(&mut clock, 9);
            let num_coins = 40 * math::pow(10, 9); 
            
            // John withdraws 40 Sui
            vault::withdraw(&mut userState, &mut rewardState, &mut treasury, num_coins, &clock, ctx);

            // Verify that John earns ~500 FARM tokens
            let userReward = vault::getUserRewardBalance(&userState, ctx);
            assert!(userReward <= 500 * math::pow(10, 9), EIncorrectUserReward);
            vault::getReward(&mut userState, &mut rewardState, &mut treasury, &clock, ctx);

            // Verify that treasury has a reward balance of ~300 FARM tokens
            let rewardBalance = vault::getRewardBalance(&treasury);
            assert!(rewardBalance >= 300 * math::pow(10, 9), EIncorrectRewardBalance);

            // Return fetched objects
            test_scenario::return_shared(rewardState);
            test_scenario::return_shared(userState);
            test_scenario::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        test_scenario::end(scenario_val);
    }
}