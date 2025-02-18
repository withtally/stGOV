.PHONY: test

clean:
	forge clean

build:
	forge build

test:
	forge test

list-gas:
	WRITE_REPORT=true forge test --mp test/gas-reports/GovLst.g.sol --isolate

fixed-gas:
	WRITE_REPORT=true forge test --mp test/gas-reports/FixedGovLst.g.sol --isolate

gas:
	$(MAKE) list-gas
	$(MAKE) fixed-gas
