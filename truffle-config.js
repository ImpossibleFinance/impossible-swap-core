const HDWalletProvider = require('@truffle/hdwallet-provider')
require('dotenv').config();

module.exports = {
    networks: {
        testnet: {
            provider: () => new HDWalletProvider(`${process.env.MNEMONIC}`, `https://data-seed-prebsc-1-s1.binance.org:8545`),
            network_id: 97
        },
        mainnet: {
            provider: () => new HDWalletProvider(`${process.env.MNEMONIC}`, `https://bsc-dataseed4.binance.org`),
            network_id: 56
        }
    },
    plugins: [
        'truffle-plugin-verify'
    ],
    api_keys: {
        etherscan: process.env.API_KEY,
        bscscan: process.env.BSCSCAN
    },

    // Set default mocha options here, use special reporters etc.
    mocha: {
        // timeout: 100000
    },

    // Configure your compilers
    compilers: {
        solc: {
            version: '0.7.6', // Fetch exact version from solc-bin (default: truffle's version)
            settings: {
                // See the solidity docs for advice about optimization and evmVersion
                optimizer: {
                    enabled: true,
                    runs: 200
                }
            }
        }
    }
}
