import { Contract, Wallet } from 'ethers'
import { Web3Provider } from 'ethers/providers'
import { deployContract } from 'ethereum-waffle'

import { expandTo18Decimals } from './utilities'

import WETH9 from '../../build/WETH9.json'
import ERC20 from '../../build/ERC20.json'
import ImpossibleFactory from '../../build/ImpossibleFactory.json'
import IImpossiblePair from '../../build/IImpossiblePair.json'
import ImpossiblePair from '../../build/ImpossiblePair.json'
import ImpossibleRouter01 from '../../build/ImpossibleRouter01.json'
import ImpossibleRouter02 from '../../build/ImpossibleRouter02.json'
import RouterEventEmitter from '../../build/RouterEventEmitter.json'

interface FactoryFixture {
  factory: Contract
}
const overrides = {
  gasLimit: 9999999
}

export async function factoryFixture(_: Web3Provider, [wallet]: Wallet[]): Promise<FactoryFixture> {
  const factory = await deployContract(wallet, ImpossibleFactory, [wallet.address], overrides)
  return { factory }
}

interface PairFixture extends FactoryFixture {
  token0: Contract
  token1: Contract
  pair: Contract
}

export async function pairFixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<PairFixture> {
  const { factory } = await factoryFixture(provider, [wallet])

  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)

  await factory.setRouter(wallet.address)
  await factory.createPair(tokenA.address, tokenB.address, overrides)
  const pairAddress = await factory.getPair(tokenA.address, tokenB.address)
  const pair = new Contract(pairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)

  const token0Address = (await pair.token0()).address
  const token0 = tokenA.address === token0Address ? tokenA : tokenB
  const token1 = tokenA.address === token0Address ? tokenB : tokenA

  return { factory, token0, token1, pair }
}

interface V2Fixture {
  tokenA: Contract
  tokenB: Contract
  WETH: Contract
  WETHPartner: Contract
  factoryV2: Contract
  router01: Contract
  router02: Contract
  routerEventEmitter: Contract
  router: Contract
}

export async function v2Fixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<V2Fixture> {
  // deploy tokens
  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])
  const WETH = await deployContract(wallet, WETH9)
  const WETHPartner = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)])

  // deploy V2
  const factoryV2 = await deployContract(wallet, ImpossibleFactory, [wallet.address], overrides)

  // deploy routers
  const router01 = await deployContract(wallet, ImpossibleRouter01, [factoryV2.address, WETH.address], overrides)
  const router02 = await deployContract(wallet, ImpossibleRouter02, [factoryV2.address, WETH.address], overrides)

  const routerEventEmitter = await deployContract(wallet, RouterEventEmitter, [])

  return {
    tokenA,
    tokenB,
    WETH,
    WETHPartner,
    factoryV2,
    router01,
    router02,
    router: router02, // the default router, 01 had a minor bug,
    routerEventEmitter
  }
}
