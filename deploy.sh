#!/bin/sh

# publish modules
movement move publish --package-dir ./src/coins/ --max-gas 100000000
movement move publish --package-dir ./src/faucet/ --max-gas 100000000
movement move publish --package-dir ./src/swap --max-gas 100000000



