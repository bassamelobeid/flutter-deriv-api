# NAME

BOM::Test - Do things before test

# DESCRIPTION

This module is used to prepare test environment. It should be used before any other bom modules in the test file.

# Environment Variables

- $ENV{DB\_POSTFIX}

    This variable will be set if test is running on qa devbox. If it is set the system will use test database instead of development database.

# Functions

## purge\_redis

Purge Redis database before running a test script. Give it a clear environment.

Parameters: none
Return: 1

# TEST

    # test this repo
    make test
    # test all repo under regentmarkets and binary-com
    make test_all
