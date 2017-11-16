# bom-websocket-tests

Websocket API tests

To run Websocket API tests on QA devbox, please do:
- cd `/home/git/regentmarkets/bom-websocket-tests`
- prove --rc `/home/git/regentmarkets/binary-websocket-api/.proverc` -vl `v3/[testfile].t`

It will include dependencies from `.proverc` file in the `binary-websocket-api`.
