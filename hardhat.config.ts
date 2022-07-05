import '@nomiclabs/hardhat-waffle'
import '@nomiclabs/hardhat-etherscan'
import dotenv from 'dotenv'

dotenv.config()

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more

/**
 * @type import('hardhat/config').HardhatUserConfig
 */

module.exports = {
  solidity: {
    version: '0.7.6',
    settings: {
      optimizer: { enabled: true },
    },
  },
  etherscan: {
    apiKey: {
      goerli: process.env.ETHERSCAN_API_KEY,
      kovan: process.env.ETHERSCAN_API_KEY,
      bscTestnet: process.env.BSCSCAN_API_KEY,
    },
  },
  networks: {
    bsc_test: {
      url: 'https://data-seed-prebsc-1-s3.binance.org:8545',
      chainId: 97,
      gasPrice: 11000000000,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    bsc_main: {
      url: 'https://bsc-dataseed.binance.org/',
      chainId: 56,
      gasPrice: 5000000000,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    eth_goerli: {
      url: 'https://rpc.goerli.mudit.blog/',
      chainId: 5,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    eth_ropsten: {
      url: 'https://ropsten.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    eth_main: {
      url: 'https://mainnet.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    polygon_main: {
      url: 'https://polygon-rpc.com',
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    avax_main: {
      url: 'https://api.avax.network/ext/bc/C/rpc',
      chainId: 43114,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    moonriver_main: {
      url: 'https://rpc.moonriver.moonbeam.network',
      chainId: 1285,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    eth_kovan: {
      url: 'https://kovan.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161',
      chainId: 42,
      accounts: {
        mnemonic: process.env.MNEMONIC || '',
      },
    },
    aca_mandala: {
      url: "https://tc7-eth.aca-dev.network",
      chainId: 595,
      mnemonic: process.env.MNEMONIC || '',
    }
  },
}

