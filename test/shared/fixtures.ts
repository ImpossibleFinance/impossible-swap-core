import { Contract, Wallet } from 'ethers'
import { Web3Provider } from 'ethers/providers'
import { deployContract } from 'ethereum-waffle'

import { expandTo18Decimals } from './utilities'

import WETH9 from '../../build/WETH9.json'
import ERC20 from '../../build/ERC20.json'
import ImpossibleSwapFactory from '../../build/ImpossibleSwapFactory.json'
import ImpossibleWrapperFactory from '../../build/ImpossibleWrapperFactory.json'
import ImpossiblePair from '../../build/ImpossiblePair.json'
import ImpossibleRouter from '../../build/ImpossibleRouter.json'
import ImpossibleRouterExtension from '../../build/ImpossibleRouterExtension.json'

interface FactoryFixture {
  factory: Contract
  token0: Contract
  token1: Contract
}

const overrides = {
  gasLimit: 9999999
}

export async function factoryFixture(_: Web3Provider, [wallet]: Wallet[]): Promise<FactoryFixture> {
  const factory = await deployContract(wallet, ImpossibleSwapFactory, [wallet.address], overrides)
  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(10000)], overrides)
  const token0 = tokenA.address.toLowerCase() < tokenB.address.toLowerCase() ? tokenA : tokenB
  const token1 = tokenA.address.toLowerCase() < tokenB.address.toLowerCase() ? tokenB : tokenA

  return { factory, token0, token1 }
}

interface PairFixture extends FactoryFixture {
  pair: Contract
}

export async function pairFixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<PairFixture> {
  const { factory, token0, token1 } = await factoryFixture(provider, [wallet])

  await factory.setRouterAndExtension(wallet.address, wallet.address)
  await factory.createPair(token0.address, token1.address, overrides)
  const pairAddress = await factory.getPair(token0.address, token1.address)
  const pair = new Contract(pairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)

  return { factory, token0, token1, pair }
}

interface V2Fixture {
  tokenA: Contract
  tokenB: Contract
  WETH: Contract
  WETHPartner: Contract
  pairFactory: Contract
  wrapFactory: Contract
  router: Contract
  routerExtension: Contract
}

export async function v2Fixture(provider: Web3Provider, [wallet]: Wallet[]): Promise<V2Fixture> {
  // deploy tokens
  const tokenA = await deployContract(wallet, ERC20, [expandTo18Decimals(1000000)])
  const tokenB = await deployContract(wallet, ERC20, [expandTo18Decimals(1000000)])
  const WETH = await deployContract(wallet, WETH9)
  const WETHPartner = await deployContract(wallet, ERC20, [expandTo18Decimals(1000000)])

  // deploy pair factory and approve all trading tokens
  const pairFactory = await deployContract(wallet, ImpossibleSwapFactory, [wallet.address], overrides)
  await pairFactory.changeTokenAccess(tokenA.address, true);
  await pairFactory.changeTokenAccess(tokenB.address, true);
  await pairFactory.changeTokenAccess(WETH.address, true);
  await pairFactory.changeTokenAccess(WETHPartner.address, true);

  // deploy wrap
  const wrapFactory = await deployContract(wallet, ImpossibleWrapperFactory, [wallet.address])

  // deploy routers
  const routerExtension = await deployContract(wallet, ImpossibleRouterExtension, [pairFactory.address], overrides)

  const router = await deployContract(wallet, ImpossibleRouter, [pairFactory.address, wrapFactory.address, wallet.address], overrides)
  await router.setUtilities(WETH.address, routerExtension.address)


  return {
    tokenA,
    tokenB,
    WETH,
    WETHPartner,
    pairFactory,
    wrapFactory,
    router,
    routerExtension
  }
}
