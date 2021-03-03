# bom-rules
Contains hooks and logic for the various regulatory requirements

# SYNOPSIS

```
    use BOM::Rules::Engine;
    my $rule_engine = BOM::Rules::Engine->new(loginid => 'CR1234', landing_company => 'svg');

    my $result = $rule_engine->verify_action('new_account', {first_name => 'Sir John', last_name => 'Falstaff'});
    if ($result->{error}) {
        # return or handle the error
    } else {
        # we are happily compliant to rules
    }

```

# Repository structure

- The rule engine's public API is exposed by the class `BOM::Rule::Engine` which can verify an **action** (by applying it's configured rule-set) or apply a single **rule** on demand
- Rules are objects of class `BOM::Rules::Registry::Rule`, instantiated by declarations made in packages `BOM::Rules::RuleRepository::*`
- Actions are objects of class `BOM::Rules::Registry::Action`, instantiated automatically from their configuration .yml files in `share/actions`
- The module `BOM::Rules::Registry` contains methods for validation and registration of **actions** and **rules** from their declarations when the rule engine class is imported
- Each rule engine is accompanied by a `BOM::Rules::Context` object which contains the context data about actions and rules; e.g. client loginid and object, landing company, residence, etc. 
