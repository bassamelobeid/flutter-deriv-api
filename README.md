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