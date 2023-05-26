module staking_protocol::vault {

    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext}; 
    use sui::transfer;
    use sui::vec_map::{Self, VecMap};
    use sui::math;
    use sui::clock::{Self, Clock};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::event;
    use staking_protocol::farm::{FARM};

    /* ========== OBJECTS ========== */

    struct RewardState has key {
        id: UID,

        duration: u64, // Set by the Owner: Duration of rewards to be paid out (in seconds)

        finishAt: u64, // Timestamp of when the rewards finish

        updatedAt: u64, // Minimum of last updated time and reward finish time

        rewardRate: u64, // Reward to be paid out per second: determined by the duration & amount of rewards
    }

    struct UserState has key {
        id: UID,

        rewardPerTokenStored: u64, // Sum of (reward rate * dt * 1^(token_decimal) / total staked supply) where dt is the time difference between current time and last updated time

        userRewardPerTokenPaid: VecMap<address, u64>, // Mapping that keeps track of users' rewardPerTokenStored

        balanceOf: VecMap<address, u64>, // Mapping that keeps track of users' staked amount 

        rewards: VecMap<address, u64>, // Mapping that keeps track of users' rewards to be claimed
    }

    struct Treasury has key {
        id: UID,

        rewardsTreasury: Balance<FARM>, // Staking rewards held in the treasury

        stakedCoinsTreasury: Balance<SUI>, // Staked Sui coins held in the treasury
    }

     struct AdminCap has key { // Gives access to admin-only functions
        id: UID
    }

    /* ========== EVENTS ========== */

    struct RewardAdded has copy, drop{
        reward: u64
    }

    struct RewardDurationUpdated has copy, drop {
         newDuration: u64
    }

    struct Staked has copy, drop{
        user: address,
        amount: u64
    }

    struct Withdrawn has copy, drop {
        user: address,
        amount: u64
    }

    struct RewardPaid has copy, drop {
        user: address,
        reward: u64
    }

    /* ========== ERRORS ========== */

    const ERewardDurationNotExpired: u64 = 100;
    const EZeroRewardRate: u64 = 101;
    const EZeroAmount: u64 = 102;
    const ELowRewardsTreasuryBalance: u64 = 103;
    const ERequestedAmountExceedsStaked: u64 = 104;
    const ENoRewardsToClaim: u64 = 105;
    const ENoStakedTokens: u64 = 106;
    const ENoPriorTokenStake: u64 = 107;

    /* ========== CONSTRUCTOR ========== */

    fun init (ctx: &mut TxContext){
       
        transfer::share_object(RewardState{
            id: object::new(ctx),
            duration: 0,
            finishAt: 0,
            updatedAt: 0,
            rewardRate: 0
        });

        transfer::share_object(UserState{
            id: object::new(ctx),
            rewardPerTokenStored: 0,
            userRewardPerTokenPaid: vec_map::empty<address, u64>(),
            balanceOf: vec_map::empty<address, u64>(),
            rewards: vec_map::empty<address, u64>()
        });

        transfer::share_object(Treasury{
            id: object::new(ctx),
            rewardsTreasury: balance::zero<FARM>(),
            stakedCoinsTreasury: balance::zero<SUI>(),
        });

        transfer::transfer(AdminCap {id: object::new(ctx)}, tx_context::sender(ctx));
    }

    /* ========== USER FUNCTIONS ========== */
    
    /**
    * @notice Stake user specified amount of Sui Coins 
    * @dev This function allows the user to stake a user specified amount of Sui coins 
      and updates their balances and rewards.
    * @param payment The Coin<SUI> payment to be staked.
    * @param userState The mutable UserState reference.
    * @param rewardState The mutable RewardState reference.
    * @param treasury The mutable Treasury reference.
    * @param clock The Clock reference.
    * @param ctx The mutable transaction context.
    */
    public entry fun stake (payment: Coin<SUI>, userState: &mut UserState, rewardState: &mut RewardState, treasury: &mut Treasury, clock: &Clock, ctx: &mut TxContext) {

        let account = tx_context::sender(ctx);
        let totalStakedSupply = balance::value(&treasury.stakedCoinsTreasury);
        let amount = coin::value(&payment);

        // Initialize user mappings if not already present
        if(!vec_map::contains(&userState.balanceOf, &account)){
            vec_map::insert(&mut userState.balanceOf, account, 0);
            vec_map::insert(&mut userState.userRewardPerTokenPaid, account, 0);
            vec_map::insert(&mut userState.rewards, account, 0);
        };

        // Update user and reward state parameters 
        updateReward(totalStakedSupply, account, userState, rewardState, clock);

        // Transfer payment to treasury
        let balance = coin::into_balance(payment);
        balance::join(&mut treasury.stakedCoinsTreasury, balance);

        // Update user's balances
        let balanceOf_account = vec_map::get_mut(&mut userState.balanceOf, &account);
        *balanceOf_account = *balanceOf_account + amount;

        event::emit(Staked{user:tx_context::sender(ctx), amount});
    }

    /**
    * @notice Withdraw the user specified amount of staked Sui coins
    * @dev This function allows the user to withdraw a user specified amount of staked tokens and updates their balances and rewards.
    * @param userState The mutable UserState reference.
    * @param rewardState The mutable RewardState reference.
    * @param treasury The mutable Treasury reference.
    * @param amount The amount of tokens to be withdrawn.
    * @param clock The Clock reference.
    * @param ctx The mutable transaction context.
    */
    public entry fun withdraw(userState: &mut UserState, rewardState: &mut RewardState, treasury: &mut Treasury, amount: u64, clock: &Clock, ctx: &mut TxContext) {
        
        let account = tx_context::sender(ctx);
        let balanceOf_account_imut = vec_map::get(&mut userState.balanceOf, &account);
        let totalStakedSupply = balance::value(&treasury.stakedCoinsTreasury);

        // Check if the user has staked tokens
        let userStakedTokensExist = vec_map::contains(&userState.balanceOf, &account);
        assert!(userStakedTokensExist, ENoStakedTokens);

         // Ensure the withdrawal amount is less than the staked balance and greater than zero
        assert!(amount > 0, EZeroAmount);
        assert!(amount <= *balanceOf_account_imut, ERequestedAmountExceedsStaked);
        
        // Update user and reward state parameters 
        updateReward(totalStakedSupply, account, userState, rewardState, clock);

        // Update user's balance
        let balanceOf_account = vec_map::get_mut(&mut userState.balanceOf, &account);
        *balanceOf_account = *balanceOf_account - amount;

        // Transfer the staked tokens to the user
        let withdrawalAmount = coin::take<SUI>(&mut treasury.stakedCoinsTreasury, amount, ctx);
        transfer::public_transfer(withdrawalAmount, tx_context::sender(ctx));

        event::emit(Withdrawn{user:tx_context::sender(ctx), amount});
    }

    /**
    * @notice Claim the rewards for the user
    * @dev This function allows the user to claim their rewards and updates their balances and reward states.
    * @param userState The mutable UserState reference.
    * @param rewardState The mutable RewardState reference.
    * @param treasury The mutable Treasury reference.
    * @param clock The Clock reference.
    * @param ctx The mutable transaction context.
    */
    public entry fun getReward(userState: &mut UserState, rewardState: &mut RewardState, treasury: &mut Treasury, clock: &Clock, ctx: &mut TxContext) {

        let account = tx_context::sender(ctx);
        let totalStakedSupply = balance::value(&treasury.stakedCoinsTreasury);

        // Check if the user has a prior token stake
        let userHasPriorStake = vec_map::contains(&userState.rewards, &account);
        assert!(userHasPriorStake, ENoPriorTokenStake);

        // Check if the user has rewards to claim
        let rewards_account_imut = vec_map::get(&mut userState.rewards, &account);
        assert!(*rewards_account_imut > 0, ENoRewardsToClaim);

        // Update user and reward state parameters 
        updateReward(totalStakedSupply, account, userState, rewardState, clock);

        // Update user's rewards mapping and transfer rewards
        let rewards_account = vec_map::get_mut(&mut userState.rewards, &account);
        let stakingRewards = coin::take<FARM>(&mut treasury.rewardsTreasury, *rewards_account, ctx);
        
        event::emit(RewardPaid{user:tx_context::sender(ctx), reward: *rewards_account});

        *rewards_account = 0;
        transfer::public_transfer(stakingRewards, tx_context::sender(ctx));
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /**
    * @notice Set the duration of the reward period
    * @dev This function allows the admin to set the duration of the reward period
    * @param _ The AdminCap reference.
    * @param rewardState The mutable RewardState reference.
    * @param duration The new duration of the reward period.
    * @param clock The Clock reference.
    */
    public entry fun setRewardDuration(_: &AdminCap, rewardState: &mut RewardState, duration: u64, clock: &Clock) {

         // Ensure that the reward duration has expired
        assert!(rewardState.finishAt < clock::timestamp_ms(clock), ERewardDurationNotExpired);

        rewardState.duration = duration;
        event::emit(RewardDurationUpdated{newDuration: duration});
    }

    /**
    * @notice Set the amount and consequently the rate of the reward
    * @dev This function allows the admin to set the amount and as a result the rate of the reward, updates user and reward states
    * @param _ The AdminCap reference.
    * @param reward The reward amount to be added.
    * @param userState The mutable UserState reference.
    * @param rewardState The mutable RewardState reference.
    * @param treasury The mutable Treasury reference.
    * @param clock The Clock reference.
    */
    public entry fun setRewardAmount(_: &AdminCap, reward: Coin<FARM>, userState: &mut UserState, rewardState: &mut RewardState, treasury: &mut Treasury, clock: &Clock) {

        let totalStakedSupply = balance::value(&treasury.stakedCoinsTreasury);
        let amount = coin::value(&reward);

        // Update user and reward state parameters 
        updateReward(totalStakedSupply, @0x0, userState, rewardState, clock);

        // Add rewards to treasury
        let balance = coin::into_balance(reward);
        balance::join(&mut treasury.rewardsTreasury, balance);

        // Compute the reward rate
        if(clock::timestamp_ms(clock) >= rewardState.finishAt){
            rewardState.rewardRate = amount / rewardState.duration;
        }
        else{
            let remaining_reward = (rewardState.finishAt - clock::timestamp_ms(clock)) * rewardState.rewardRate;
            rewardState.rewardRate = (amount + remaining_reward) / rewardState.duration;
        };

        // Ensure that the reward rate has been computed correctly
        assert!(rewardState.rewardRate > 0, EZeroRewardRate);
        assert!(rewardState.rewardRate * rewardState.duration <= balance::value(&treasury.rewardsTreasury), ELowRewardsTreasuryBalance);

        // Update the Last Updated Time and Finish Time
        rewardState.finishAt = clock::timestamp_ms(clock) + rewardState.duration;
        rewardState.updatedAt = clock::timestamp_ms(clock);

        event::emit(RewardAdded{reward: amount});
    }

    /* ========== HELPER FUNCTIONS ========== */

    /**
    * @notice Update the reward for a specific user 
    * @dev This function calculates and updates the reward for a specific user based on the total staked supply and reward state parameters.
    * @param totalStakedSupply The total staked supply.
    * @param account The user account address.
    * @param userState The mutable UserState reference.
    * @param rewardState The mutable RewardState reference.
    * @param clock The Clock reference.
    */
    fun updateReward(totalStakedSupply: u64, account: address, userState: &mut UserState, rewardState: &mut  RewardState, clock :&Clock){

        // Calculate rewardPerTokenStored
        userState.rewardPerTokenStored = rewardPerToken(totalStakedSupply, userState, rewardState, clock);

        // Update the Last Updated Time
        rewardState.updatedAt = math::min(clock::timestamp_ms(clock), rewardState.finishAt); // lastTimeRewardApplicable

        if (account != @0x0){
            // Update the user's rewards earned
            let new_reward_value = earned(totalStakedSupply, account, userState, rewardState, clock);
            let rewards_account = vec_map::get_mut(&mut userState.rewards, &account);
            *rewards_account = new_reward_value;

            // Update the user's userRewardPerTokenPaid
            let userRewardPerTokenPaid_account = vec_map::get_mut(&mut userState.userRewardPerTokenPaid, &account);
            *userRewardPerTokenPaid_account = userState.rewardPerTokenStored;
        }
    }

    /**
    * @notice Calculate the rewards earned for a specific user
    * @dev This function calculates the rewards earned for a specific user based on the total staked supply and reward state parameters.
    * @param totalStakedSupply The total staked supply.
    * @param account The user account address.
    * @param userState The immutable UserState reference.
    * @param rewardState The immutable RewardState reference.
    * @param clock The immutable Clock reference.
    * @return The rewards earned for the user.
    */
    fun earned(totalStakedSupply: u64, account: address, userState: &UserState, rewardState: &RewardState, clock: &Clock): u64{
        
        // Typecast to u256 to avoid arithmetic overflow
        let balanceOf_account = (*vec_map::get(&userState.balanceOf, &account) as u256);
        let userRewardPerTokenPaid_account = (*vec_map::get(&userState.userRewardPerTokenPaid, &account) as u256);
        let rewards_account = (*vec_map::get(&userState.rewards, &account) as u256);
        let token_decimals = (math::pow(10, 9) as u256);

        // Update the rewards earned
        let rewards_earned  = ((balanceOf_account * ((rewardPerToken(totalStakedSupply, userState, rewardState, clock) as u256) - userRewardPerTokenPaid_account)) / token_decimals) + rewards_account;

        return (rewards_earned as u64)
    }

    /**
    * @notice Calculate the reward per token at time t
    * @dev This function calculates the reward per token at time t based on the total staked supply and reward state parameters.
    * @param totalStakedSupply The total staked supply.
    * @param userState The immutable UserState reference.
    * @param rewardState The immutable RewardState reference.
    * @param clock The immutable Clock reference.
    * @return The reward per token.
    */
    fun rewardPerToken(totalStakedSupply: u64, userState: &UserState, rewardState: &RewardState, clock: &Clock): u64 {
    
        if (totalStakedSupply == 0) { 
            return userState.rewardPerTokenStored
        };

        let token_decimals = (math::pow(10, 9) as u256);
        let lastTimeRewardApplicable = (math::min(clock::timestamp_ms(clock), rewardState.finishAt) as u256);

        // Typecast to u256 to avoid arithmetic overflow
        let computedRewardPerToken = (userState.rewardPerTokenStored as u256) + ((rewardState.rewardRate as u256) * (lastTimeRewardApplicable - (rewardState.updatedAt as u256)) * token_decimals)/ (totalStakedSupply as u256);

        return (computedRewardPerToken as u64)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun getRewardRate(rewardState: &RewardState):u64 {
        rewardState.rewardRate
    }

    #[test_only]
    public fun getRewardBalance(treasury: &Treasury):u64 {
        balance::value(&treasury.rewardsTreasury)
    }

    #[test_only] 
    public fun getUserRewardBalance(userState: &UserState, ctx: &mut TxContext): u64{
        let account = tx_context::sender(ctx);
        *vec_map::get(&userState.rewards, &account)
    }
}