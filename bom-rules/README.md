# bom-rules
Contains hooks and logic for the various regulatory requirements

# SYNOPSIS

```
    use BOM::Rules::Engine;
    my $rule_engine = BOM::Rules::Engine->new(loginid => 'CR1234', landing_company => 'svg');

    try {
        $rule_engine->verify_action('new_account', {first_name => 'Sir John', last_name => 'Falstaff'});
        # we are happily compliant to rules
    } catch($error) {
        # return or handle the error
    }
```

# Repository Structure

- The rule engine's public API is exposed by the class `BOM::Rule::Engine`, which can verify an **action** (by applying its configured rule-set) or apply a single **rule** on demand.
- Rules are objects of class `BOM::Rules::Registry::Rule`, instantiated by declarations made in packages `BOM::Rules::RuleRepository::*`.
- Actions are objects of class `BOM::Rules::Registry::Action`, instantiated automatically from their configuration `.yml` files in `share/actions`.
- The module `BOM::Rules::Registry` contains methods for the validation and registration of **actions** and **rules** from their declarations when the rule engine class is imported.
- Each rule engine is accompanied by a `BOM::Rules::Context` object, which contains the context data about actions and rules, e.g., client login ID and object, landing company, residence, etc.


Certainly, I can help refine and expand these guidelines into a more structured format of "Dos and Don'ts". Here's an updated version:

### Dos

1. **Use Clear and Understandable Rule Names**: Ensure that the names of the rules are clear and understandable to both technical and non-technical individuals. Avoid overly technical jargon.

2. **Ensure Full Unit Test Coverage**: Accompany each new rule with a comprehensive set of unit tests. This ensures the rule's functionality and stability across various scenarios.

3. **Keep Rule Names Simple and Abstract**: Design the rules with simplicity and abstraction in mind. This approach enhances their versatility, allowing them to be easily integrated into different rule groups.

4. **Optimize Parameter Sharing**: When multiple rules share the same parameter, consider centralizing it in the context. This practice maintains a clean and efficient codebase.

5. **Test Cases for All Rules**: Ensure that every rule has associated test cases, and all these test cases must pass successfully to maintain the integrity of the rules.

### Don'ts

1. **Avoid Overly Complex Rule Names**: Do not use complex or obscure terminology in rule names that could confuse users.

2. **Avoid Over-Specificity in Rule Names**: Do not create rules with names that are too specific to a particular scenario, as this limits their applicability.

3. **Do Not Overlook Parameter Redundancies**: Avoid having redundant parameters across multiple rules, which can clutter the codebase and lead to inefficiencies.

4. **Do Not Ignore Failing Test Cases**: Do not overlook or ignore failing test cases. Address and resolve these issues promptly to ensure the rules work as intended.
