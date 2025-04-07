module my_addr::loyalty_reward_system {
    use std::string;
    use std::vector;
    use std::table::{Table, Self};
    use std::signer::address_of;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, ObjectCore};
    use aptos_framework::account;

    /// When the caller is not authorised to perfom the action
    const ENOT_AUTHORISED: u64 = 1;

    /// When no tokens are available for the customer
    const ENO_TOKENS_FOR_CUSTOMER: u64 = 2;

    /// When there are no expired tokens to withdraw
    const ENO_EXPIRED_TOKENS: u64 = 3;

    struct LoyaltyCoin {}

    struct LoyaltyToken has key {
        balance: coin::Coin<LoyaltyCoin>,
        expiry: u64,
    }

    struct CustomerObjects has key {
        object_addresses: Table<address, ObjectAddresses>
    }

    struct ObjectAddresses has store, drop {
        addresses: vector<address>
    }

    struct AdminData has key {
        mint_cap: coin::MintCapability<LoyaltyCoin>,
        burn_cap: coin::BurnCapability<LoyaltyCoin>,
        freeze_cap: coin::FreezeCapability<LoyaltyCoin>,
        customer_addresses: vector<address>
    }

    fun assert_is_admin(addr: address) {
        assert!(addr == @my_addr, ENOT_AUTHORISED);
    }

    fun init_module(admin: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LoyaltyCoin>(
            admin,
            string::utf8(b"Loyalty Token"),
            string::utf8(b"LT"),
            8,
            false
        );

        move_to(admin, AdminData {
            mint_cap: mint_cap,
            burn_cap: burn_cap,
            freeze_cap: freeze_cap,
            customer_addresses: vector::empty()
        });

        move_to(admin, CustomerObjects {
            object_addresses: table::new()
        });
    }

    public entry fun mint_tokens(admin: &signer, customer: address, amount: u64, expiry_days: u64) acquires AdminData, CustomerObjects {
        let admin_addr = address_of(admin);
        assert_is_admin(admin_addr);

        let constructor_ref = object::create_object(admin_addr);
        let object_signer = object::generate_signer(&constructor_ref);

        let admin_data = borrow_global<AdminData>(admin_addr);
        let customer_objects = &mut borrow_global_mut<CustomerObjects>(@my_addr).object_addresses;
        let expiry_timestamp = timestamp::now_seconds() + (expiry_days * 86400);

        let tokens = coin::mint<LoyaltyCoin>(amount, &admin_data.mint_cap);

        move_to(&object_signer, LoyaltyToken {
            balance: tokens,
            expiry: expiry_timestamp
        });

        let loyalty_object = object::object_from_constructor_ref<ObjectCore>(&constructor_ref);
        let object_addr = object::object_address(&loyalty_object);

        if(!is_customer_exists(admin_data.customer_addresses, customer)) {
            vector::push_back(
                &mut borrow_global_mut<AdminData>(@my_addr).customer_addresses,
                customer
            );
        };

        if (!is_customer_object_exists(customer_objects, customer)) {
            table::add(
                customer_objects,
                customer,
                ObjectAddresses { addresses: vector::empty() }
            );
        };
        let customer_obj_addresses = table::borrow_mut(customer_objects, customer);
        vector::push_back(&mut customer_obj_addresses.addresses, object_addr);

        object::transfer(admin, loyalty_object, customer);
    }

    public entry fun redeem_available_tokens(customer: &signer) acquires CustomerObjects, LoyaltyToken {
        let customer_addr = address_of(customer);
        let customer_objects = borrow_global_mut<CustomerObjects>(@my_addr);

        assert!(is_customer_object_exists(&customer_objects.object_addresses, customer_addr), ENO_TOKENS_FOR_CUSTOMER);

        let address_vector = table::borrow_mut(&mut customer_objects.object_addresses, customer_addr);

        vector::for_each (
            address_vector.addresses,
            |object_addr| {
                if (exists<LoyaltyToken>(object_addr)) {
                    let loyalty_token = borrow_global_mut<LoyaltyToken>(object_addr);
                    let token_obj = object::address_to_object<LoyaltyToken>(object_addr);

                    if ((object::owner(token_obj) == customer_addr) && (timestamp::now_seconds() < loyalty_token.expiry)) {
                        let amount = coin::value(&loyalty_token.balance);
                        if (amount > 0) {
                            let tokens = coin::extract(&mut loyalty_token.balance, amount);
                            coin::deposit(customer_addr, tokens);
                        }
                    };
                };
            }
        );
    }

    public entry fun withdraw_expired_tokens(admin: &signer) acquires LoyaltyToken, CustomerObjects, AdminData {
        assert_is_admin(address_of(admin));
        let admin_data = borrow_global_mut<AdminData>(@my_addr);
        let customer_objects = borrow_global_mut<CustomerObjects>(@my_addr);
        let current_time = timestamp::now_seconds();
        let length = vector::length(&admin_data.customer_addresses);

        assert!(length > 0, ENO_EXPIRED_TOKENS);

        vector::for_each (
            admin_data.customer_addresses,
            | customer | {
                if (is_customer_exists(admin_data.customer_addresses, customer)) {
                    let address_vector = table::borrow_mut(&mut customer_objects.object_addresses, customer);

                    vector::for_each (
                        address_vector.addresses,
                        | token_addr | {
                            if (exists<LoyaltyToken>(token_addr)) {
                                let loyalty_token = borrow_global_mut<LoyaltyToken>(token_addr);

                                if (current_time > loyalty_token.expiry) {
                                    let balance = &mut loyalty_token.balance;
                                    let amount = coin::value(balance);
                                    let coins = coin::extract(balance, amount);
                                    coin::burn(coins, &admin_data.burn_cap);

                                    let (found, index) = vector::index_of(&mut address_vector.addresses, &token_addr);
                                    if (found) {
                                        vector::remove(&mut address_vector.addresses, index);
                                    }
                                    
                                };
                            };
                        }
                    );

                    // remove customer if no tokens left
                    if (vector::is_empty(&address_vector.addresses)) {
                        table::remove(&mut customer_objects.object_addresses, customer);
                        let (found, index) = vector::index_of(&mut admin_data.customer_addresses, &customer);
                        if (found) {
                            vector::remove(&mut admin_data.customer_addresses, index);
                        }
                    }
                };
            }
        );
    }

    #[view]
    public fun check_balance(customer_addr: address): u64 acquires CustomerObjects, LoyaltyToken {
        let customer_objects = borrow_global_mut<CustomerObjects>(@my_addr);
        let available = 0;

        if (!table::contains(&customer_objects.object_addresses, customer_addr)) {
            return available;
        };

        let address_vector = table::borrow_mut(&mut customer_objects.object_addresses, customer_addr);

        vector::for_each (
            address_vector.addresses,
            | object_addr | {
                if (exists<LoyaltyToken>(object_addr)) {
                    let loyalty_token = borrow_global_mut<LoyaltyToken>(object_addr);
                    let token_obj = object::address_to_object<LoyaltyToken>(object_addr);

                    if ((object::owner(token_obj) == customer_addr) && (timestamp::now_seconds() < loyalty_token.expiry)) {
                        let amount = coin::value(&loyalty_token.balance);
                        available = available + amount;
                        if (amount > 0) {
                            let tokens = coin::extract(&mut loyalty_token.balance, amount);
                            coin::deposit(customer_addr, tokens);
                        }
                    };
                };
            }
        );
        available
    }

    fun is_customer_exists(customer_addresses: vector<address>, customer: address): bool {
        vector::contains(&customer_addresses, &customer)
    }

    fun is_customer_object_exists(customers: &Table<address, ObjectAddresses>, customer: address): bool {
        table::contains(customers, customer)
    }

    #[test_only]
    fun register_coin(sender: &signer) {
        if (!coin::is_account_registered<LoyaltyCoin>(address_of(sender))) {
            coin::register<LoyaltyCoin>(sender);
        };
    }

    #[test(admin=@my_addr, customer=@0x123, customer2=@0x345, aptos_framework=@aptos_framework)]
    public entry fun test_flow(admin: &signer, customer: &signer, customer2: &signer, aptos_framework: &signer)
        acquires AdminData, CustomerObjects, LoyaltyToken {
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(customer));
        account::create_account_for_test(address_of(customer2));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);
        register_coin(customer);
        register_coin(customer2);

        // mint tokens to customer's address with 30 days expiration
        mint_tokens(admin, address_of(customer), 100, 30);

        let customer_objects = borrow_global<CustomerObjects>(@my_addr);
        let tokens = table::borrow(&customer_objects.object_addresses, address_of(customer));
        assert!(vector::length(&tokens.addresses) == 1, 10001);

        let object_addr = *vector::borrow(&tokens.addresses, 0);
        let token = borrow_global<LoyaltyToken>(object_addr);
        assert!(coin::value(&token.balance) == 100, 10002);

        // redeem by customer
        redeem_available_tokens(customer);

        let customer_objects = borrow_global<CustomerObjects>(@my_addr);
        let tokens = table::borrow(&customer_objects.object_addresses, address_of(customer));
        let object_addr = *vector::borrow(&tokens.addresses, 0);
        let token = borrow_global<LoyaltyToken>(object_addr);
        assert!(coin::value(&token.balance) == 0, 10003);
        assert!(coin::balance<LoyaltyCoin>(address_of(customer)) == 100, 10004);

        // expired tokens can't withdraw by customer
        mint_tokens(admin, address_of(customer2), 100, 10); // 10 days expiry
        mint_tokens(admin, address_of(customer2), 200, 30); // 30 days expiry

        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + (15 * 86400)); // 15 days forward

        redeem_available_tokens(customer2);

        assert!(coin::balance<LoyaltyCoin>(address_of(customer2)) == 200, 10005);

        // expired tokens withdraw by admin
        let customer_objects = borrow_global<CustomerObjects>(@my_addr);
        let tokens = table::borrow(&customer_objects.object_addresses, address_of(customer2));
        let object_addr = *vector::borrow(&tokens.addresses, 0);
        let token = borrow_global<LoyaltyToken>(object_addr);
        assert!(coin::value(&token.balance) == 100, 10006); // expired tokens of customer2

        withdraw_expired_tokens(admin);

        let customer_objects = borrow_global<CustomerObjects>(@my_addr);
        let tokens = table::borrow(&customer_objects.object_addresses, address_of(customer2));
        let object_addr = *vector::borrow(&tokens.addresses, 0);
        let token = borrow_global<LoyaltyToken>(object_addr);
        assert!(coin::value(&token.balance) == 0, 10007);
    }

    #[test(admin=@my_addr, customer=@0x123, customer2=@0x345, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = ENOT_AUTHORISED)]
    public entry fun fail_mint_tokens(admin: &signer, customer: &signer, aptos_framework: &signer)
        acquires CustomerObjects, AdminData {
        
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(customer));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);
        register_coin(customer);

        mint_tokens(customer, address_of(customer), 100, 10);
    }

    #[test(admin=@my_addr, customer=@0x123, customer2=@0x345, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = ENOT_AUTHORISED)]
    public entry fun fail_unauthorised_expired_tokens_withdraw(admin: &signer, customer: &signer, aptos_framework: &signer)
        acquires LoyaltyToken, CustomerObjects, AdminData {
        
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(customer));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);
        register_coin(customer);

        mint_tokens(admin, address_of(customer), 100, 10);

        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + (15 * 86400));

        withdraw_expired_tokens(customer);
    }

    #[test(admin=@my_addr, customer=@0x123, customer2=@0x345, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = ENO_TOKENS_FOR_CUSTOMER)]
    public entry fun fail_customer_redeem(admin: &signer, customer: &signer, aptos_framework: &signer)
        acquires LoyaltyToken, CustomerObjects {
        
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(customer));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);
        register_coin(customer);

        redeem_available_tokens(customer);
    }

    #[test(admin=@my_addr, aptos_framework=@aptos_framework)]
    #[expected_failure(abort_code = ENO_EXPIRED_TOKENS)]
    public entry fun fail_expired_tokens_withdraw(admin: &signer, aptos_framework: &signer)
        acquires LoyaltyToken, CustomerObjects, AdminData {
        
        account::create_account_for_test(address_of(admin));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);

        withdraw_expired_tokens(admin);
    }
}
