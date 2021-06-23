const ImpossibleFactory = artifacts.require('ImpossibleFactory');

const fs = require('fs');
const Web3 = require('web3');

const web3 = new Web3();

module.exports = async (deployer, network, accounts) => {
    const feeSettler = accounts[1];
    await deployer.deploy(ImpossibleFactory, feeSettler);
};
