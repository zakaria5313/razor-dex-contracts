#!/bin/sh

# deployer address
Razor = "0xa60491f2e71c83ac63551c4e3f51c0933da0f926123175865c0741d03e1e1ea0"
ResourceAccount = "8511115e91e7f6bbb50cd51ee5469666a2e06eb041bbcac2544ce6b8d6b02ba1"

# Compile all packages
movement move compile --package-dir ./src/libs
movement move compile --package-dir ./src/resource_account
movement move compile --package-dir ./src/lp
movement move compile --package-dir ./src/swap
movement move compile --package-dir ./src/faucet