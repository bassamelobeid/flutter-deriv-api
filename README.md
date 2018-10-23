# bom-platform

This repo contains the Binary.com business-object library, implementing the core features of the website: account opening, log in and log out, clients, transactions, portfolio, statement.

# Dependencies

(TODO: make this happen)

* https://github.com/regentmarkets/cpan
* https://github.com/regentmarkets/bom-postgres

# TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -MBOM::Test t/BOM/001_structure.t
    
# Sanctions check for client

Sanctions checks are specialized searches that include a number of government sanction files that identify individuals who are prohibited from certain activities or industries.

* How does it work?

1. Client's information (first_name, last_name, date_of_birth) are passed in: `$sanctions->get_sanctioned_info($client->first_name, $client->last_name, $client->date_of_birth);`

2. Regex variants generated based on the following:

- Client's `first_name = 'Abdul'` and `last_name` = `Rahim`
- Two regex variants are generated: `ABDUL.*RAHIM` and `Rahim.*ABDUL`
- For the case of `ABDUL.RAHIM`: The part `.*` will match the whole string, with anything after (and including) `ABDUL` and before (and including) `RAHIM`.

3. Regex check

- Consider the name: `Abdullah Ibrahim Al-Faisal`
- After removing non-alphabets and whitespace, the following string is made: `ABDULLAHIBRAHIMALFAISAL`
- The regex `ABDUL.*RAHIM` captures this as a true positive because the parts **`ABDUL`LAHIB`RAHIM`ALFAISAL** matches

4. Date of birth check

- If a `date_of_birth` is passed, it is compared to the list of **date_of_birth** in the sanction lists, based on epoch value and the name.

Scenarios to consider:

Note that a positive result means `marked as prohibited` and negative result means `innocent`.

- `name matches and no date_of_birth value passed`: This returns a positive result
- `name matches and date_of_birth matches`: This retruns a positive result
- `name matches but date_of_birth does not match`: This returns a negative result
