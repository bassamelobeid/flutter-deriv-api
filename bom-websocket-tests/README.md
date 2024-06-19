# bom-websocket-tests

## To run Websocket API tests on a QA devbox
- cd `/home/git/regentmarkets/bom-websocket-tests`
- prove --rc `/home/git/regentmarkets/binary-websocket-api/.proverc` -vl `v3/[testfile].t`

Note: This will include dependencies from `.proverc` file in the `binary-websocket-api`

---

## JSON Schema Testing

The JSON Schema testing files are all located in `v3/schema_suite/`. In these files we use a number of functions listed below (with their description, usage and examples). The test modules are structured in a way where the request and expected response files are stored in `v3/schema_suite/config` and these files are used by the `test_sendrecv` function among others. To add a basic test, you first have to create a json file containing the request to be sent, another json file containing the expected response and call `test_sendrecv` or `test_sendrecv_params` to check if the actual response matches the expected response.

---
### start

You will encounter this function which initializes the entire test module. Certain following functions can only be called through this module (i.e. `get_token` and `get_stashed`). 

```
my $suite = start(
    title             => "example.t",
    test_app          => 'Binary::WebSocketAPI',
    suite_schema_path => __DIR__ . '/config/',
);
```

You want to save the result of the function in a variable ($suite) to be able to call `get_token` and `get_stashed` later on. (e.g. `$suite->get_token`).

### get_token

This function retrieves the latest token generated for a certain email. This includes `account_opening` verification code, `payment_withdraw` token and others.
Note that you will need to call `test_sendrecv_params` with the `verify_email` parameters along with the token type you wish to receive.

```
test_sendrecv_params 'verify_email/test_send.json', 'verify_email/test_receive.json', 'test@binary.com', 'account_opening';
$suite->get_token('test@binary.com');
```

### get_stashed

All responses generated are stored for each successful api call made. These responses are all accessible with the use of this fuction. The responses are stored in an object with the name of the call made. 

```
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
$suite->get_stashed('proposal/proposal/id');
```
```
test_sendrecv_params 'api_token/test_send_create.json', 'api_token/test_receive_create.json', 'test';
$suite->get_stashed('api_token/api_token/tokens/0/token');
```

### free_gift

Use this function to give an account a free gift of a specified amount in a specified currency. If no currency is provided, USD is chosen by default. If no amount is specified, 10000 is chosen by default.

```
$suite->free_gift("CR90000001", 'GBP', '12345');
```
However, in these test cases, it is highly recommended to use the stored login id from a previous call that was made.
```
$suite->free_gift($suite->get_stashed('new_account_real/new_account_real/client_id'), 'GBP', '12345');
```

### set_language

This function should be called at the beginning of every test module, passing in whichever language is relevant.

```
set_language 'EN';
```

### reset_app

This function can be called to reset the module with the same configuration defined in the `start` function.

```
reset_app;
```

### finish

This function should be called at the end of every test module.

```
finish;
```

### test_sendrecv // test_sendrecv_params

These functions takes in at least two variables, one for the request to be sent and one for the expected response received. If the response received from the call does not match the expected response, the test will fail. 

The request and response files will have to be defined in `v3/schema_suite/config`, categorized in their appropriate folder.

```
test_sendrecv 'proposal/test_send_buy.json', 'proposal/test_receive_buy.json';
```

Often times, multiple tests will have to be done for the same API call. These tests will involve very similar request save for a few parameters. Instead of making multiple files with these similar requests, we use `test_sendrecv_params` which takes in the path to a request file, a response file as well as additional parameters that are used in the json files. The parameters are used in the json files with `[_1]` for the first parameter, `[_2]` for the second, and so on.

```
test_sendrecv_params 'new_account_real/test_send.json',      'new_account_real/test_receive_cr.json', 'Peter', 'id';
```

In the example above, we are sending a request for a new real account with first name `Peter` and residence `Indonesia`. Using this structure, we can send new real account requests with different first names and residences by changing the parameters we pass into this function. Note that the file `new_account_real/test_send.json` has the first name parameter as `[_1]` and the residence parameter as `[_2]`.

For testing responses of subscribed calls, look at `test_last_stream`.

### fail_test_sendrecv // fail_test_sendrecv_params

These functions work in the same way `test_sendrecv` and `test_sendrecv_params` does, but instead expects the response not to match the second file passed in. 
