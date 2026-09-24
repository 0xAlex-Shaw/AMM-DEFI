.PHONY: help setup build test test-deep fmt lint clean

help:
	@echo "  make setup      install contract dependencies (forge) and node modules"
	@echo "  make build      compile contracts"
	@echo "  make test       run the contract test suite"
	@echo "  make test-deep  20k fuzz runs"
	@echo "  make fmt        format Solidity"
	@echo "  make lint       solhint over contracts"

setup:
	forge install foundry-rs/forge-std --no-git
	forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
	npm install

build:
	forge build --sizes

test:
	forge test -vv

test-deep:
	FOUNDRY_PROFILE=deep forge test

fmt:
	forge fmt

lint:
	npx solhint 'contracts/**/*.sol'

clean:
	forge clean
