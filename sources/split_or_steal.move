/*
    The quest is a representation of Prisoners Dilemma game from game theory. The contract deployer can create a game
    providing addresses of two players that will take part in the game and sends funds to the smart contract, that will
    be a prize for participating in the game. Next, both players submit their decisions representing their intentions to
    either try to split or try to steal the prize. After that, they have a fixed amount of time to reveal their
    decisions. There are multiple possible outcomes of the game:
        - Both players decide to split the prize. Both players receive half of the prize
        - One of the players decides to split and the other one to steal. The player that decided to steal gets
            the whole prize, while the other one gets nothing
        - Both players decide to steal the prize. The prize is transferred back to the contract deployer and
            both players get nothing
        - Only one player reveals the decision on time. The player that revealed the decision gets the prize and
            the other gets nothing
        - No one reveals the decision on time. The prize is transferred back to the contract deployer and
            both players get nothing
*/

module overmind::split_or_steal {

    //==============================================================================================
    // Dependencies
    //==============================================================================================

    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;

    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::guid;
    #[test_only]
    use std::hash::sha3_256;

    //==============================================================================================
    // Constants - DO NOT MODIFY
    //==============================================================================================

    const SEED: vector<u8> = b"SplitOrSteal";
    const EXPIRATION_TIME_IN_SECONDS: u64 = 60 * 60;

    const DECISION_NOT_MADE: u64 = 0;
    const DECISION_SPLIT: u64 = 1;
    const DECISION_STEAL: u64 = 2;

    //==============================================================================================
    // Error codes
    //==============================================================================================

    const EStateIsNotInitialized: u64 = 0;
    const ESignerIsNotDeployer: u64 = 1;
    const ESignerHasInsufficientAptBalance: u64 = 2;
    const EGameDoesNotExist: u64 = 3;
    const EPlayerDoesNotParticipateInTheGame: u64 = 4;
    const EIncorrectHashValue: u64 = 5;
    const EGameNotExpiredYet: u64 = 6;
    const EBothPlayersDoNotHaveDecisionsSubmitted: u64 = 7;
    const EPlayerHasDecisionSubmitted: u64 = 8;

    //==============================================================================================
    // Module Structs
    //==============================================================================================

    /*
        The main resource holding data about all games and events
    */
    struct State has key {
        // ID of the next game that will be created
        next_game_id: u128,
        // A map of games
        games: SimpleMap<u128, Game>,
        // Resource account's SignerCapability instance
        cap: SignerCapability,
        // Events
        create_game_events: EventHandle<CreateGameEvent>,
        submit_decision_events: EventHandle<SubmitDecisionEvent>,
        reveal_decision_events: EventHandle<RevealDecisionEvent>,
        conclude_game_events: EventHandle<ConcludeGameEvent>,
        release_funds_after_expiration_events: EventHandle<ReleaseFundsAfterExpirationEvent>
    }

    /*
        A struct representing a single game
    */
    struct Game has store, copy, drop {
        // Amount of APT that can be won
        prize_pool_amount: u64,
        // Instance of PlayerData representing the first player
        player_one: PlayerData,
        // Instance of PlayerData representing the second player
        player_two: PlayerData,
        // Timestamp, after which a game can be terminated calling `release_funds_after_expiration` function
        expiration_timestamp_in_seconds: u64,
    }

    /*
        A struct representing a player
    */
    struct PlayerData has store, copy, drop {
        // Address of the player
        player_address: address,
        // Hash of the player's decision created from the decision and the player's salt
        decision_hash: Option<vector<u8>>,
        // Hash of the player's salt
        salt_hash: Option<vector<u8>>,
        // Decision made by the player (can be either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        decision: u64
    }

    //==============================================================================================
    // Event structs
    //==============================================================================================

    /*
        Event emitted in every `create_game` function call
    */
    struct CreateGameEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Amount of APT that can be won
        prize_pool_amount: u64,
        // Address of the first player
        player_one_address: address,
        // Address of the second player
        player_two_address: address,
        // Timestamp, after which a game can be terminated calling `release_funds_after_expiration` function
        expiration_timestamp_in_seconds: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `submit_decision` function call
    */
    struct SubmitDecisionEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Address of the player calling the function
        player_address: address,
        // Hash of the player's decision created from the decision and the player's salt
        decision_hash: vector<u8>,
        // Hash of the player's salt
        salt_hash: vector<u8>,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `reveal_decision` function call
    */
    struct RevealDecisionEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Address of the player calling the function
        player_address: address,
        // Decision made by the player (either DECISION_SPLIT or DECISION_STEAL)
        decision: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in `reveal_decision` function call if both players' decisions were revealed
    */
    struct ConcludeGameEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Decision made by the first player (either DECISION_SPLIT or DECISION_STEAL)
        player_one_decision: u64,
        // Decision made by the second player (either DECISION_SPLIT or DECISION_STEAL)
        player_two_decision: u64,
        // Amount of APT that could be won in the game
        prize_pool_amount: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `release_funds_after_expiration` function call
    */
    struct ReleaseFundsAfterExpirationEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Decision made by the first player (either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        player_one_decision: u64,
        // Decision made by the second player (either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        player_two_decision: u64,
        // Amount of APT that could be won in the game
        prize_pool_amount: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /*
    Function called at the deployment of the module
    @param account - deployer of the module
    */
    fun init_module(account: &signer) {
        // Create a resource account (utilize SEED const)
        let resource_account_address = signer::address_from_encoded_string(SEED);

        // Register the resource account with AptosCoin
        AptosCoin::register_account(&resource_account_address);

        // Create a new State instance and move it to `account` signer
        let state = State {
            next_game_id: 0,
            games: SimpleMap::new(),
            cap: signer::get_cap(),
            create_game_events: EventHandle::new(),
            submit_decision_events: EventHandle::new(),
            reveal_decision_events: EventHandle::new(),
            conclude_game_events: EventHandle::new(),
            release_funds_after_expiration_events: EventHandle::new(),
        };

        move_to(account, state);
    }

    /*
        Creates a new game
        @param account - deployer of the module
        @param prize_pool_amount - amount of APT that can be won in the game
        @param player_one_address - address of the first player participating in the game
        @param player_two_address - address of the second player participating in the game
    */
    public entry fun create_game(
        account: &signer,
        prize_pool_amount: u64,
        player_one_address: address,
        player_two_address: address
    ) acquires State {
        // Call `check_if_state_exists` function
        check_if_state_exists();

        // Call `check_if_signer_is_contract_deployer` function
        check_if_signer_is_contract_deployer(account);

        // Call `check_if_signer_has_enough_apt_coins` function
        check_if_account_has_enough_apt_coins(account, prize_pool_amount);

        // Call `get_next_game_id` function
        let game_id = get_next_game_id(&mut move_from<&mut State>(account).next_game_id);

        // Create a new instance of Game
        let game = Game {
            prize_pool_amount,
            player_one: PlayerData {
                player_address: player_one_address,
                decision_hash: None,
                salt_hash: None,
                decision: DECISION_NOT_MADE,
            },
            player_two: PlayerData {
                player_address: player_two_address,
                decision_hash: None,
                salt_hash: None,
                decision: DECISION_NOT_MADE,
            },
            expiration_timestamp_in_seconds: timestamp::now().seconds() + EXPIRATION_TIME_IN_SECONDS,
        };

        // Add the game to the State's games SimpleMap instance
        move_to(account, game, &mut move_from<&mut State>(account).games[&game_id]);

        // Transfer `prize_pool_amount` amount of APT from `account` to the resource account
        AptosCoin::transfer_from_sender(account, &resource_account(), prize_pool_amount);

        // Emit `CreateGameEvent` event
        emit CreateGameEvent {
            game_id,
            prize_pool_amount,
            player_one_address,
            player_two_address,
            expiration_timestamp_in_seconds: game.expiration_timestamp_in_seconds,
            event_creation_timestamp_in_seconds: timestamp::now().seconds(),
        };
    }

    /*
        Saves a player's decision in their PlayerData instance in the game with the provided `game_id`
        @param player - player participating in the game
        @param game_id - ID of the game
        @param decision_hash - SHA3_256 hash of the combination of the player's decision and the player's salt
        @param salt_hash - SHA3_256 hash of the player's salt
    */
    public entry fun submit_decision(
        player: &signer,
        game_id: u128,
        decision_hash: vector<u8>,
        salt_hash: vector<u8>
    ) acquires State {
        // Call `check_if_state_exists` function
        check_if_state_exists();

        // Call `check_if_game_exists` function
        check_if_game_exists(&move_from<State>(player).games, &game_id);

        // Call `check_if_player_participates_in_the_game` function
        let game = &mut move_from<State>(player).games[&game_id];
        check_if_player_participates_in_the_game(player, game);

        // Call `check_if_player_does_not_have_a_decision_submitted` function
        let player_address = signer::address_of(player);
        check_if_player_does_not_have_a_decision_submitted(game, player_address);

        // Set the player's PlayerData decision_hash and salt_hash fields to the values provided in the params
        if player_address == game.player_one.player_address {
            game.player_one.decision_hash = Some(decision_hash);
            game.player_one.salt_hash = Some(salt_hash);
        } else {
            game.player_two.decision_hash = Some(decision_hash);
            game.player_two.salt_hash = Some(salt_hash);
        }

        // Emit `SubmitDecisionEvent` event
        emit SubmitDecisionEvent {
            game_id,
            player_address,
            event_creation_timestamp_in_seconds: timestamp::now().seconds(),
        };
    }

    /*
        Reveals the decision made by a player in `submit_decision` function and concludes the game if both players
        call this function.
        @param player - player participating in the game
        @param game_id - ID of the game
        @param salt - salt that the player used to hash their decision
    */
    public entry fun reveal_decision(
        player: &signer,
        game_id: u128,
        salt: String
    ) acquires State {
        // Call `check_if_state_exists` function
        check_if_state_exists();

        // Call `check_if_game_exists` function
        let games = &mut move_from<State>(player).games;
        check_if_game_exists(games, &game_id);

        // Call `check_if_player_participates_in_the_game` function
        let game = &mut games[&game_id];
        check_if_player_participates_in_the_game(player, game);

        // Call `check_if_both_players_have_a_decision_submitted` function
        check_if_both_players_have_a_decision_submitted(game);

        // Call `make_decision` function with appropriate PlayerData instance depending on the player's address
        let player_address = signer::address_of(player);
        let decision = if player_address == game.player_one.player_address {
            make_decision(&mut game.player_one, &salt)
        } else {
            make_decision(&mut game.player_two, &salt)
        };

        // Emit `RevealDecisionEvent` event
        emit RevealDecisionEvent {
            game_id,
            player_address,
            decision,
            event_creation_timestamp_in_seconds: timestamp::now().seconds(),
        };

        // If both players submitted their decisions:
        if game.player_one.decision_hash.is_some() && game.player_two.decision_hash.is_some() {
            // Remove the game from the State's game SimpleMap instance
            games.remove(&game_id);

            // If both players decided to split, send half of the game's `prize_pool_amount` of APT to both of them
            if game.player_one.decision == DECISION_SPLIT && game.player_two.decision == DECISION_SPLIT {
                let prize = game.prize_pool_amount / 2;
                AptosCoin::transfer_from_sender(account, &game.player_one.player_address, prize);
                AptosCoin::transfer_from_sender(account, &game.player_two.player_address, prize);
            }
            // If one of the players decided to steal and the other one to split, send
            // the game's `prize_pool_amount` of APT to the player that decided to steal
            else if (game.player_one.decision == DECISION_SPLIT && game.player_two.decision == DECISION_STEAL) ||
                    (game.player_one.decision == DECISION_STEAL && game.player_two.decision == DECISION_SPLIT) {
                AptosCoin::transfer_from_sender(account, &game.player_two.player_address, game.prize_pool_amount);
            }
            // If both players decided to steal, send the game's `prize_pool_amount` of APT to the deployer
            // of the contract
            else if game.player_one.decision == DECISION_STEAL && game.player_two.decision == DECISION_STEAL {
                AptosCoin::transfer_from_sender(account, &resource_account(), game.prize_pool_amount);
            }

            // Emit `ConcludeGameEvent` event
            emit ConcludeGameEvent {
                game_id,
                event_creation_timestamp_in_seconds: timestamp::now().seconds(),
            };
        }
    }

    /*
        Releases the funds if a game expired depending on revealed decisions
        @param _account - any account signer
        @param game_id - ID of the game
    */
    public entry fun release_funds_after_expiration(_account: &signer, game_id: u128) acquires State {
        // Call `check_if_state_exists` function
        check_if_state_exists();

        // Call `check_if_game_exists` function
        let games = &mut move_from<State>(_account).games;
        check_if_game_exists(games, &game_id);

        // Remove the game from the State's games SimpleMap instance
        games.remove(&game_id);

        // Call `check_if_game_expired` function
        let game = games[&game_id];
        check_if_game_expired(&game);

        // Transfer the game's `prize_pool_amount` APT amount to:
        // 1) The deployer of the contract if both players' decisions were not revealed
        // 2) The first player if the second player did not reveal their decision
        // 3) The second player if the first player did not reveal their decision
        if game.player_one.decision_hash.is_none() || game.player_two.decision_hash.is_none() {
            AptosCoin::transfer_from_sender(account, &resource_account(), game.prize_pool_amount);
        } else {
            AptosCoin::transfer_from_sender(account, &game.player_one.player_address, game.prize_pool_amount);
        }

        // Emit `ReleaseFundsAfterExpirationEvent` event
        emit ReleaseFundsAfterExpirationEvent {
            game_id,
            event_creation_timestamp_in_seconds: timestamp::now().seconds(),
        };
    }


    //==============================================================================================
    // Helper functions
    //==============================================================================================

    
    /*
    Sets the PlayerData's decision field's value to either DECISION_SPLIT or DECISION_STEAL depending on the value of
    the PlayerData's decision_hash value
    @param player_data - instance of PlayerData struct
    @param salt - salt that the player used to hash their decision
    @return - the decision made and submitted in `submit_decision` function
        (either DECISION_SPLIT or DECISION_STEAL)
    */
    inline fun make_decision(player_data: &mut PlayerData, salt: &String): u64 {
        if let Some(decision_hash) = &player_data.decision_hash {
            // Call `check_if_hash_is_correct` function
            check_if_hash_is_correct(decision_hash, bcs::to_bytes(player_data.decision).unwrap() + salt.as_bytes());

            // Create a SHA3_256 hash of a split decision from a vector containing serialized DECISION_SPLIT const
            // and bytes of the salt
            let split_decision_hash = sha3_256(bcs::to_bytes(DECISION_SPLIT).unwrap() + salt.as_bytes());

            // Create a SHA3_256 hash of a steal decision from a vector containing serialized DECISION_STEAL const
            // and bytes of the salt
            let steal_decision_hash = sha3_256(bcs::to_bytes(DECISION_STEAL).unwrap() + salt.as_bytes());

            // Compare the hashes with the PlayerData's `decision_hash` and return either DECISION_SPLIT
            // or DECISION_STEAL depending on the result
            if decision_hash == &split_decision_hash {
                return DECISION_SPLIT;
            } else if decision_hash == &steal_decision_hash {
                return DECISION_STEAL;
            }
        }

        // In case the decision_hash does not match any of the expected hashes or is None, the decision is considered not made
        DECISION_NOT_MADE
    }

    /*
        Increments `next_game_id` param and returns its previous value
        @param next_game_id - `next_game_id` field from State resource
        @return - value of `next_game_id` field from State resource before the increment
    */
    inline fun get_next_game_id(next_game_id: &mut u128): u128 {
        // Create a variable holding a copy of the current value of `next_game_id` param
        let prev_game_id = *next_game_id;

        // Increment `next_game_id` param
        *next_game_id += 1;

        // Return the previously created variable
        prev_game_id
    }


    //==============================================================================================
    // Validation functions
    //==============================================================================================

    inline fun check_if_state_exists() {
        // Assert that State resource exists under the contract deployer's address
        assert(exists<State>(signer::address_of(signer::address())), EStateDoesNotExist);
    }

    inline fun check_if_signer_is_contract_deployer(signer: &signer) {
        // Assert that address of `signer` is the same as address of `overmind` located in Move.toml file
        assert(signer::address_of(signer) == signer::address_from_encoded_string(OVERMIND_ADDRESS), ENotAuthorized);
    }

    inline fun check_if_account_has_enough_apt_coins(account: &signer, amount: u64) {
        // Assert that AptosCoin balance of `account` address equals or is greater than `amount` param
        let account_balance = AptosCoin::balance_of(&signer::address_of(account));
        assert(account_balance >= amount, ENotEnoughBalance);
    }

    inline fun check_if_game_exists(games: &SimpleMap<u128, Game>, game_id: &u128) {
        // Assert that `games` SimpleMap contains `game_id` key
        assert(games.contains_key(game_id), EGameDoesNotExist);
    }

    inline fun check_if_player_participates_in_the_game(player: &signer, game: &Game) {
        // Assert that address of `player` is the same as either address of the first player or address of
        // the second player stored in the Game instance
        assert(signer::address_of(player) == game.player_one.player_address || 
            signer::address_of(player) == game.player_two.player_address, EPlayerDoesNotParticipateInTheGame);
    }

    inline fun check_if_both_players_have_a_decision_submitted(game: &Game) {
        // Assert that both PlayerData's `decision_hash` fields are option::some
        assert(game.player_one.decision_hash.is_some() && game.player_two.decision_hash.is_some(), EDecisionNotSubmitted);
    }

    inline fun check_if_player_does_not_have_a_decision_submitted(game: &Game, player_address: address) {
        // Assert that the player's PlayerData's `decision_hash` is option::none depending on `player_address`
        // param's value
        let player_data = if player_address == game.player_one.player_address {
            &game.player_one
        } else if player_address == game.player_two.player_address {
            &game.player_two
        } else {
            panic("Invalid player address")
        };
        assert(player_data.decision_hash.is_none(), EDecisionAlreadySubmitted);
    }

    inline fun check_if_hash_is_correct(hash: vector<u8>, value: vector<u8>) {
        // Assert that `hash` param equals SHA3_256 hash of `value` param
        assert(hash == hash::sha3_256(&value), EIncorrectHashValue);
    }

    inline fun check_if_game_expired(game: &Game) {
        // Assert that the Game's `expiration_timestamp_in_seconds` is smaller than the current timestamp
        let current_timestamp = timestamp::now().seconds();
        assert(game.expiration_timestamp_in_seconds < current_timestamp, EGameNotExpired);
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test]
    fun test_init() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 0, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 0, 2);
        assert!(event::counter(&state.submit_decision_events) == 0, 3);
        assert!(event::counter(&state.reveal_decision_events) == 0, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 6);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            8
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );
        assert!(coin::is_account_registered<AptosCoin>(resource_account_address), 12);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 13);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 524303, location = aptos_framework::account)]
    fun test_init_again() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);
        init_module(&account);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_create_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 1, 1);
        assert!(simple_map::contains_key(&state.games, &0), 2);
        assert!(event::counter(&state.create_game_events) == 1, 3);
        assert!(event::counter(&state.submit_decision_events) == 0, 4);
        assert!(event::counter(&state.reveal_decision_events) == 0, 5);
        assert!(event::counter(&state.conclude_game_events) == 0, 6);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            8
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            9
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            11
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            12
        );

        let game = *simple_map::borrow(&state.games, &0);
        assert!(game.prize_pool_amount == prize_pool_amount, 13);
        assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);
        assert!(game.player_one.player_address == player_one_address, 15);
        assert!(option::is_none(&game.player_one.decision_hash), 16);
        assert!(option::is_none(&game.player_one.salt_hash), 17);
        assert!(game.player_one.decision == DECISION_NOT_MADE, 18);

        assert!(game.player_two.player_address == player_two_address, 19);
        assert!(option::is_none(&game.player_two.decision_hash), 20);
        assert!(option::is_none(&game.player_two.salt_hash), 21);
        assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 25);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_create_game_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@overmind);
        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_game_signer_is_not_deployer() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let account = account::create_account_for_test(@0x6234834325);
        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_game_signer_has_insufficient_apt_balance() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_submit_decision() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, 0, decision_hash, salt_hash);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 1, 1);
        assert!(simple_map::contains_key(&state.games, &0), 2);
        assert!(event::counter(&state.create_game_events) == 1, 3);
        assert!(event::counter(&state.submit_decision_events) == 1, 4);
        assert!(event::counter(&state.reveal_decision_events) == 0, 5);
        assert!(event::counter(&state.conclude_game_events) == 0, 6);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            8
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            9
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            11
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            12
        );

        let game = simple_map::borrow(&state.games, &0);
        assert!(game.prize_pool_amount == prize_pool_amount, 13);
        assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

        assert!(game.player_one.player_address == player_one_address, 15);
        assert!(option::contains(&game.player_one.decision_hash, &decision_hash), 16);
        assert!(option::contains(&game.player_one.salt_hash, &salt_hash), 17);
        assert!(game.player_one.decision == DECISION_NOT_MADE, 18);

        assert!(game.player_two.player_address == player_two_address, 19);
        assert!(option::is_none(&game.player_two.decision_hash), 20);
        assert!(option::is_none(&game.player_two.salt_hash), 21);
        assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 23);
        assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 24);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 25);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_submit_decision_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&account, game_id, decision_hash, salt_hash);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_submit_decision_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_submit_decision_player_does_not_participate_in_the_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let another_player = account::create_account_for_test(@0xACE123);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&another_player, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_submit_decision_player_one_has_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_submit_decision_player_two_has_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_two = account::create_account_for_test(@0xCAFE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_two, game_id, decision_hash, salt_hash);
        submit_decision(&player_two, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_split() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_SPLIT, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount / 2, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount / 2, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_player_one_steals() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_STEAL, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_player_two_steals() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_SPLIT, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_both_players_steal() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_STEAL, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == prize_pool_amount, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_reveal_decision_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&account, game_id, salt);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_reveal_decision_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&player_one, game_id, salt);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_reveal_decision_player_does_not_participate_in_the_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let another_player = account::create_account_for_test(@0xACE123);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&another_player, game_id, salt);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_both_players_do_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&player_one, game_id, salt);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_player_two_does_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);
        reveal_decision(&player_one, game_id, string::utf8(player_one_salt));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_player_one_does_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_two = account::create_account_for_test(@0xCAFE);
        let game_id = 0;
        let player_two_salt = b"saltsaltsalt";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);
        reveal_decision(&player_two, game_id, string::utf8(player_two_salt));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_overmind() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        coin::register<AptosCoin>(&player_one);

        let player_two = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player_two);

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, 0);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 0, 3);
        assert!(event::counter(&state.reveal_decision_events) == 0, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == prize_pool_amount, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_player_one() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, game_id, string::utf8(player_one_salt));

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, game_id);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 2, 3);
        assert!(event::counter(&state.reveal_decision_events) == 1, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_player_two() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_two, game_id, string::utf8(player_two_salt));

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, game_id);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 2, 3);
        assert!(event::counter(&state.reveal_decision_events) == 1, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_release_funds_after_expiration_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&account, game_id);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_release_funds_after_expiration_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&player_one, game_id);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_release_funds_after_expiration_game_not_expired_yet() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&player_one, game_id);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_make_decision() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(salt)),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        let decision = make_decision(&mut player_data, &string::utf8(salt));
        assert!(decision == DECISION_SPLIT, 0);
        assert!(player_data.player_address == @0x123123123, 1);
        assert!(option::contains(&player_data.salt_hash, &hash::sha3_256(salt)), 2);
        assert!(option::contains(&player_data.decision_hash, &hash::sha3_256(decision_bytes)), 3);
        assert!(player_data.decision == DECISION_SPLIT, 4);
    }

    #[test]
    #[expected_failure(abort_code = 0x40001, location = std::option)]
    fun test_make_decision_salt_hash_is_none() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::none(),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_make_decision_incorrect_hash_value() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(b"salt")),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    #[expected_failure(abort_code = 0x40001, location = std::option)]
    fun test_make_decision_decision_hash_is_none() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(salt)),
            decision_hash: option::none(),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    fun test_get_next_game_id() {
        let next_game_id_counter = 7328723;
        let next_game_id = get_next_game_id(&mut next_game_id_counter);

        assert!(next_game_id_counter == 7328724, 0);
        assert!(next_game_id == 7328723, 1);
    }
}