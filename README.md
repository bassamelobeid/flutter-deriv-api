# NAME

BOM::Test - Do things before test

# DESCRIPTION

This module is used to prepare test environment. It should be used before any other bom modules in the test file.

- $ENV{DB\_POSTFIX}

    This variable will be set if test is running on qa devbox. If it is set the system will use test database instead of development database.

- $ENV{REDIS\_CACHE\_SERVER}

    This variable will be set if test is running on qa devbox. If it is set the Cache::RedisDB will use test redis instance instead of development.

- $ENV{BOM\_TEST\_REDIS\_RAND}

    This variable will be set if test is running on qa devbox. If it is set the BOM::Platform::Config::randsrv will use test redis instance instead of development.

- $ENV{BOM\_TEST\_REDIS\_REPLICATED}

    This variable will be set if test is running on qa devbox. If it is set the BOM::Platform::Redis and other bom services
    will use test redis instance instead of development.

# TEST

    # test this repo
    make test
    # test all repo under regentmarkets and binary-com
    make test_all
