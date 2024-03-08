# Compile all sui packages
sui move build --path ./src/m2-coins
sui move build --path ./src/m2-dex

# Compile all aptos packages
aptos move compile --package-dir ./src/m1-coins
aptos move compile --package-dir ./src/m1-faucet
aptos move compile --package-dir ./src/m1-dex