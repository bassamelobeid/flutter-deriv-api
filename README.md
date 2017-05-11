# bom-rpc

RPC server

# TEST

    # run all test scripts
    make test
    # run one script
    prove t/BOM/001_structure.t
    # run one script with perl
    perl -It/lib -MBOM::Test -MBOM::Test::RPC::BomRpc -MBOM::Test::RPC::PricingRpc t/BOM/001_structure.t
