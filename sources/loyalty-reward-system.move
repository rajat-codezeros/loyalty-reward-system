module my_addr::loyalty_reward_system {
    use std::string;
    use std::vector;
    use std::table::{Table, Self};
    use std::signer::address_of;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, ObjectCore};
    use aptos_framework::account;

    const NOT_AUTHORISED: u64 = 1;

    struct LoyaltyCoin {}

    struct LoyaltyToken has key {
        balance: coin::Coin<LoyaltyCoin>,
        expiry: u64,
    }

    struct CustomerObjects has key {
        object_addresses: Table<address, AddressVector>
    }

    struct AddressVector has store {
        addresses: vector<address>
    }

    struct AdminCapability has key {
        cap: coin::MintCapability<LoyaltyCoin>,
        burn: coin::BurnCapability<LoyaltyCoin>,
        freeze: coin::FreezeCapability<LoyaltyCoin>,
    }

    fun assert_is_admin(addr: address) {
        assert!(addr == @my_addr, NOT_AUTHORISED);
    }

    fun init_module(admin: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LoyaltyCoin>(
            admin,
            string::utf8(b"Loyalty Token"),
            string::utf8(b"LT"),
            8,
            false
        );

        move_to(admin, AdminCapability {
            cap: mint_cap,
            burn: burn_cap,
            freeze: freeze_cap,
        });

        move_to(admin, CustomerObjects {
            object_addresses: table::new()
        });
    }

    public entry fun mint_tokens(admin: &signer, customer: address, amount: u64, expiry_days: u64) acquires AdminCapability, CustomerObjects {
        assert_is_admin(address_of(admin));

        let constructor_ref = object::create_object(address_of(admin));
        let object_signer = object::generate_signer(&constructor_ref);

        let cap = &borrow_global<AdminCapability>(address_of(admin)).cap;
        let expiry_timestamp = timestamp::now_seconds() + (expiry_days * 86400);

        let tokens = coin::mint<LoyaltyCoin>(amount, cap);

        move_to(&object_signer, LoyaltyToken {
            balance: tokens,
            expiry: expiry_timestamp
        });

        let loyalty_object = object::object_from_constructor_ref<ObjectCore>(&constructor_ref);
        let object_addr = object::object_address(&loyalty_object);

        if (!table::contains(&borrow_global<CustomerObjects>(@my_addr).object_addresses, customer)) {
            table::add(&mut borrow_global_mut<CustomerObjects>(@my_addr).object_addresses, customer, AddressVector { addresses: vector::empty() });
        };
        let entry = table::borrow_mut(&mut borrow_global_mut<CustomerObjects>(@my_addr).object_addresses, customer);
        vector::push_back(&mut entry.addresses, object_addr);

        object::transfer(admin, loyalty_object, customer);
    }

    public entry fun redeem_available_tokens(customer: &signer) acquires CustomerObjects, LoyaltyToken {
        let customer_addr = address_of(customer);
        let customer_objects = borrow_global_mut<CustomerObjects>(@my_addr);

        if (!table::contains(&customer_objects.object_addresses, customer_addr)) {
            return;
        };

        let address_vector = table::borrow_mut(&mut customer_objects.object_addresses, customer_addr);
        let length = vector::length(&address_vector.addresses);
        let i = 0;

        while (i < length) {
            let object_addr = *vector::borrow(&address_vector.addresses, i);

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
            i = i + 1;
        }
    }

    public fun withdraw_expired_tokens(admin: &signer) {
        assert_is_admin(address_of(admin));
    }

    #[test_only]
    fun register_coin(sender: &signer) {
        if (!coin::is_account_registered<LoyaltyCoin>(address_of(sender))) {
            coin::register<LoyaltyCoin>(sender);
        };
    }

    #[test(admin=@my_addr, customer=@0x123, aptos_framework=@aptos_framework)]
    public entry fun test_flow(admin: &signer, customer: &signer, aptos_framework: &signer) acquires AdminCapability, CustomerObjects, LoyaltyToken {
        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(customer));

        timestamp::set_time_has_started_for_testing(aptos_framework);
        
        init_module(admin);

        register_coin(admin);
        register_coin(customer);

        mint_tokens(admin, address_of(customer), 100, 30);

        redeem_available_tokens(customer);
    }

}
