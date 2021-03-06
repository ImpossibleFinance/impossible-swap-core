import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import { AddressZero } from 'ethers/constants'
import { bigNumberify } from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'

import { getCreate2Address } from './shared/utilities'
import { factoryFixture } from './shared/fixtures'

import ImpossiblePair from '../build/ImpossiblePair.json'

chai.use(solidity)

let sortedTokens: [string, string]
// Changed from 0x100, 0x200 test because we call Pair(pair).init()

describe('ImpossibleSwapFactory', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 9999999,
  })
  const [wallet, other] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet, other])

  let factory: Contract
  beforeEach(async () => {
    const fixture = await loadFixture(factoryFixture)
    factory = fixture.factory
    await factory.changeTokenAccess(fixture.token0.address, true)
    await factory.changeTokenAccess(fixture.token1.address, true)
    sortedTokens = [fixture.token0.address, fixture.token1.address]
  })

  it('feeTo, governance, allPairsLength', async () => {
    expect(await factory.feeTo()).to.eq(AddressZero)
    expect(await factory.governance()).to.eq(wallet.address)
    expect(await factory.allPairsLength()).to.eq(0)
  })

  async function createPair(tokens: [string, string]) {
    const bytecode = `0x${ImpossiblePair.evm.bytecode.object}`
    const create2Address = getCreate2Address(factory.address, tokens, bytecode)
    await expect(factory.createPair(...tokens))
      .to.emit(factory, 'PairCreated')
      .withArgs(sortedTokens[0], sortedTokens[1], create2Address, bigNumberify(1))

    await expect(factory.createPair(...tokens)).to.be.reverted // UniswapV2: PAIR_EXISTS
    await expect(factory.createPair(...tokens.slice().reverse())).to.be.reverted // UniswapV2: PAIR_EXISTS
    expect(await factory.getPair(...tokens)).to.eq(create2Address)
    expect(await factory.getPair(...tokens.slice().reverse())).to.eq(create2Address)
    expect(await factory.allPairs(0)).to.eq(create2Address)
    expect(await factory.allPairsLength()).to.eq(1)

    const pair = new Contract(create2Address, JSON.stringify(ImpossiblePair.abi), provider)
    expect(await pair.factory()).to.eq(factory.address)
    expect(await pair.token0()).to.eq(sortedTokens[0])
    expect(await pair.token1()).to.eq(sortedTokens[1])
  }

  it('createPair', async () => {
    await createPair(sortedTokens)
  })

  it('createPair:reverse', async () => {
    await createPair(sortedTokens.slice().reverse() as [string, string])
  })

  it('createPair:gas', async () => {
    const tx = await factory.createPair(...sortedTokens)
    const receipt = await tx.wait()
    expect(receipt.gasUsed).to.eq(4408238) // Uni v2 was 3051505. NOTE: this gas is a probably only a within-1% approx since live deployment has diff values
  })

  it('setFeeTo', async () => {
    await expect(factory.connect(other).setFeeTo(other.address)).to.be.revertedWith('IF: FORBIDDEN')
    await factory.setFeeTo(wallet.address)
    expect(await factory.feeTo()).to.eq(wallet.address)
  })

  it('setGovernance', async () => {
    await expect(factory.connect(other).setGovernance(other.address)).to.be.revertedWith('IF: FORBIDDEN')
    await factory.setGovernance(other.address)
    expect(await factory.governance()).to.eq(other.address)
    await expect(factory.setGovernance(wallet.address)).to.be.revertedWith('IF: FORBIDDEN')
  })
})
