import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'
import { BigNumber, bigNumberify } from 'ethers/utils'

import { expandTo18Decimals, mineBlock, encodePrice } from './shared/utilities'
import { pairFixture } from './shared/fixtures'
import { AddressZero } from 'ethers/constants'

const MINIMUM_LIQUIDITY = bigNumberify(10).pow(3)
const ONE_DAY = bigNumberify(86400)

chai.use(solidity)

interface boostRes {
  _boost0: BigNumber
  _boost1: BigNumber
}
let t: BigNumber
let boost: boostRes

const overrides = {
  gasLimit: 9999999,
}

describe('ImpossiblePair', () => {
  const provider = new MockProvider({
    hardfork: 'istanbul',
    mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
    gasLimit: 9999999,
  })
  const [wallet, other] = provider.getWallets()
  const loadFixture = createFixtureLoader(provider, [wallet])

  let factory: Contract
  let token0: Contract
  let token1: Contract
  let pair: Contract
  beforeEach(async () => {
    const fixture = await loadFixture(pairFixture)
    factory = fixture.factory
    token0 = fixture.token0
    token1 = fixture.token1
    pair = fixture.pair
  })

  // Minting/burning has no change in uni or xybk variant
  it('mint, xyk + xybk with 1 side being 0', async () => {
    const token0Amount = expandTo18Decimals(1)
    const token1Amount = expandTo18Decimals(4)
    await token0.transfer(pair.address, token0Amount)
    await token1.transfer(pair.address, token1Amount)

    const expectedLiquidity = expandTo18Decimals(2)
    await expect(pair.mint(wallet.address, overrides))
      .to.emit(pair, 'Transfer')
      .withArgs(AddressZero, AddressZero, MINIMUM_LIQUIDITY)
      .to.emit(pair, 'Transfer')
      .withArgs(AddressZero, wallet.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(pair, 'Sync')
      .withArgs(token0Amount, token1Amount)
      .to.emit(pair, 'Mint')
      .withArgs(wallet.address, token0Amount, token1Amount)

    expect(await pair.totalSupply()).to.eq(expectedLiquidity)
    expect(await pair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    expect(await token0.balanceOf(pair.address)).to.eq(token0Amount)
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount)
    const reserves = await pair.getReserves()
    expect(reserves[0]).to.eq(token0Amount)
    expect(reserves[1]).to.eq(token1Amount)
    expect(await pair.kLast()).to.eq(0)

    await pair.makeXybk(10, 10) // boost0=10, boost1=10
    t = bigNumberify((await provider.getBlock('latest')).timestamp) // Mine blocks till boost kicks in for boost=10
    await mineBlock(provider, t.add(ONE_DAY))

    await token1.transfer(pair.address, token1Amount)
    await pair.swap(token0Amount, 0, wallet.address, '0x', overrides)

    await token1.transfer(pair.address, token1Amount.mul(2))
    await expect(pair.mint(wallet.address, overrides))
      .to.emit(pair, 'Transfer')
      .withArgs(AddressZero, wallet.address, expectedLiquidity)
      .to.emit(pair, 'Sync')
      .withArgs(0, token1Amount.mul(4))
      .to.emit(pair, 'Mint')
      .withArgs(wallet.address, 0, token1Amount.mul(2))
  })

  it('burn, xyk', async () => {
    const token0Amount = expandTo18Decimals(3)
    const token1Amount = expandTo18Decimals(3)
    await addLiquidity(token0Amount, token1Amount)

    const expectedLiquidity = expandTo18Decimals(3)
    await pair.transfer(pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    await expect(pair.burn(wallet.address, overrides))
      .to.emit(pair, 'Transfer')
      .withArgs(pair.address, AddressZero, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      .to.emit(token0, 'Transfer')
      .withArgs(pair.address, wallet.address, token0Amount.sub(1000))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, token1Amount.sub(1000))
      .to.emit(pair, 'Sync')
      .withArgs(1000, 1000)
      .to.emit(pair, 'Burn')
      .withArgs(wallet.address, token0Amount.sub(1000), token1Amount.sub(1000), wallet.address)

    expect(await pair.balanceOf(wallet.address)).to.eq(0)
    expect(await pair.totalSupply()).to.eq(MINIMUM_LIQUIDITY)
    expect(await token0.balanceOf(pair.address)).to.eq(1000)
    expect(await token1.balanceOf(pair.address)).to.eq(1000)
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(1000))
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(1000))
  })

  it('burn, xybk with 1 side being 0', async () => {
    const token0Amount = expandTo18Decimals(1)
    const token1Amount = expandTo18Decimals(4)
    await addLiquidity(token0Amount, token1Amount)

    await pair.makeXybk(10, 10) // boost0=10, boost1=10
    t = bigNumberify((await provider.getBlock('latest')).timestamp) // Mine blocks till boost kicks in for boost=10
    await mineBlock(provider, t.add(ONE_DAY))

    await token1.transfer(pair.address, token1Amount)
    await pair.swap(token0Amount, 0, wallet.address, '0x', overrides)

    const expectedLiquidity = expandTo18Decimals(2)
    await pair.transfer(pair.address, expectedLiquidity.div(2))
    await expect(pair.burn(wallet.address, overrides))
      .to.emit(pair, 'Transfer')
      .withArgs(pair.address, AddressZero, expectedLiquidity.div(2))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, token1Amount)
      .to.emit(pair, 'Sync')
      .withArgs(0, token1Amount)
      .to.emit(pair, 'Burn')
      .withArgs(wallet.address, 0, token1Amount, wallet.address)

    expect(await pair.balanceOf(wallet.address)).to.eq(expectedLiquidity.div(2).sub(1000))
    expect(await pair.totalSupply()).to.eq(expectedLiquidity.div(2))
    expect(await token0.balanceOf(pair.address)).to.eq(0)
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount)
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0)
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(token1Amount))
  })

  async function addLiquidity(token0Amount: BigNumber, token1Amount: BigNumber) {
    await token0.transfer(pair.address, token0Amount)
    await token1.transfer(pair.address, token1Amount)
    await pair.mint(wallet.address, overrides)
  }

  // Test cases are with default fee of 30 basis pts
  const uniswapTestCases: BigNumber[][] = [
    [1, 100, 100, '987158034397061298'],
    [1, 1000, 1000, '996006981039903216'],
    [10, '982471445826763938256', '987471445826763938256', '9920071714348123486'],
  ].map((a) => a.map((n) => (typeof n === 'string' ? bigNumberify(n) : expandTo18Decimals(n))))

  uniswapTestCases.forEach((swapTestCase, i) => {
    it(`uni slippage test:${i}`, async () => {
      const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase
      await addLiquidity(token0Amount, token1Amount) // Simulated pool with ~10x extra liquidity
      await token0.transfer(pair.address, swapAmount)
      await expect(pair.swap(0, expectedOutputAmount.add(1), wallet.address, '0x', overrides)).to.be.revertedWith(
        'IF: INSUFFICIENT_UNI_K'
      )
      await pair.swap(0, expectedOutputAmount, wallet.address, '0x', overrides)
    })
  })

  const roundingMargin = bigNumberify(5) // Rounding error of 5 wei. Happens because K calculations have rounding errors

  // This test simulates a pool with 10x less liquidity but has boost=10 to match slippages in the uni invariant
  // Rounding margin is used to check because K calculations have rounding errors from int precision
  // Test cases are with default fee of 30 basis pts
  const ImpossibleswapTestCases: BigNumber[][] = [
    [1, 10, 10, '987158034397061298'], // 10:10 xybk pool with 10 boost behaves exactly like a uni pool with 100:100 tokens
    [1, 100, 100, '996006981039903216'], // 100:100 xybk pool with 10 boost behaves like a uni 1000:1000
    [10, 96, 101, '9920071714348123486'], // 96:101 xybk pool with 10 boost behaves like a uni 982:987
  ].map((a) => a.map((n) => (typeof n === 'string' ? bigNumberify(n) : expandTo18Decimals(n))))
  ImpossibleswapTestCases.forEach((swapTestCase, i) => {
    it(`xybk slippage test:${i}`, async () => {
      await pair.makeXybk(10, 10) // boost0=10, boost1=10
      t = bigNumberify((await provider.getBlock('latest')).timestamp)
      await mineBlock(provider, t.add(ONE_DAY))
      const [swapAmount, token0Amount, token1Amount, expectedOutputAmount] = swapTestCase
      await addLiquidity(token0Amount, token1Amount)
      await token0.transfer(pair.address, swapAmount)
      await expect(
        pair.swap(0, expectedOutputAmount.add(roundingMargin), wallet.address, '0x', overrides)
      ).to.be.revertedWith('IF: INSUFFICIENT_XYBK_K')
      await pair.swap(0, expectedOutputAmount, wallet.address, '0x', overrides)
    })
  })

  // Modified test to swap 1:1 just to make sure functionality works
  it('uni swap:token0', async () => {
    const token0Amount = expandTo18Decimals(50)
    const token1Amount = expandTo18Decimals(100)
    await addLiquidity(token0Amount, token1Amount)

    const swapAmount = expandTo18Decimals(1)
    await token0.transfer(pair.address, swapAmount)
    await expect(pair.swap(0, swapAmount, wallet.address, '0x', overrides))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, swapAmount)
      .to.emit(pair, 'Sync')
      .withArgs(token0Amount.add(swapAmount), token1Amount.sub(swapAmount))
      .to.emit(pair, 'Swap')
      .withArgs(wallet.address, swapAmount, 0, 0, swapAmount, wallet.address)

    const reserves = await pair.getReserves()
    expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
    expect(reserves[1]).to.eq(token1Amount.sub(swapAmount))
    expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(swapAmount))
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(token1Amount).add(swapAmount))
  })

  // Modified test to swap 1:1 just to make sure functionality works
  it('xybk swap:token0', async () => {
    const token0Amount = expandTo18Decimals(5)
    const token1Amount = expandTo18Decimals(10)
    await addLiquidity(token0Amount, token1Amount)
    await pair.makeXybk(10, 10) // boost0=10, boost1=10
    t = bigNumberify((await provider.getBlock('latest')).timestamp)
    await mineBlock(provider, t.add(ONE_DAY))

    const swapAmount = expandTo18Decimals(1)
    await token0.transfer(pair.address, swapAmount)
    await expect(pair.swap(0, swapAmount, wallet.address, '0x', overrides))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, swapAmount)
      .to.emit(pair, 'Sync')
      .withArgs(token0Amount.add(swapAmount), token1Amount.sub(swapAmount))
      .to.emit(pair, 'Swap')
      .withArgs(wallet.address, swapAmount, 0, 0, swapAmount, wallet.address)

    const reserves = await pair.getReserves()
    expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
    expect(reserves[1]).to.eq(token1Amount.sub(swapAmount))
    expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(swapAmount))
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(token1Amount).add(swapAmount))
  })

  // testing invariant conversion process
  it('invariant conversion and back', async () => {
    const token0Amount = expandTo18Decimals(50)
    const token1Amount = expandTo18Decimals(100)
    await addLiquidity(token0Amount, token1Amount)
    await pair.makeXybk(10, 10)
    await mineBlock(provider, bigNumberify((await provider.getBlock('latest')).timestamp).add(ONE_DAY))
    await expect(pair.makeUni()).to.be.revertedWith('IF: INVALID_BOOST')
    await pair.updateBoost(1, 1)
    t = bigNumberify((await provider.getBlock('latest')).timestamp)
    await mineBlock(
      provider,
      bigNumberify((await provider.getBlock('latest')).timestamp)
        .add(ONE_DAY)
        .sub(1)
    )
    await expect(pair.makeUni()).to.be.revertedWith('IF: BOOST_ALREADY_CHANGING')
    await mineBlock(provider, bigNumberify((await provider.getBlock('latest')).timestamp).add(1))
    await expect(pair.makeUni()).to.emit(pair, 'ChangeInvariant') // makeUni passed

    const swapAmount = expandTo18Decimals(1)
    await token0.transfer(pair.address, swapAmount)
    await expect(pair.swap(0, swapAmount, wallet.address, '0x', overrides))
      .to.emit(token1, 'Transfer')
      .withArgs(pair.address, wallet.address, swapAmount)
      .to.emit(pair, 'Sync')
      .withArgs(token0Amount.add(swapAmount), token1Amount.sub(swapAmount))
      .to.emit(pair, 'Swap')
      .withArgs(wallet.address, swapAmount, 0, 0, swapAmount, wallet.address)

    const reserves = await pair.getReserves()
    expect(reserves[0]).to.eq(token0Amount.add(swapAmount))
    expect(reserves[1]).to.eq(token1Amount.sub(swapAmount))
    expect(await token0.balanceOf(pair.address)).to.eq(token0Amount.add(swapAmount))
    expect(await token1.balanceOf(pair.address)).to.eq(token1Amount.sub(swapAmount))
    const totalSupplyToken0 = await token0.totalSupply()
    const totalSupplyToken1 = await token1.totalSupply()
    expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(token0Amount).sub(swapAmount))
    expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(token1Amount).add(swapAmount))
  })

  // Modified test to swap 1:1 token, just to check gas prices of swap
  it('uni swap:gas', async () => {
    const token0Amount = expandTo18Decimals(10)
    const token1Amount = expandTo18Decimals(5)
    await addLiquidity(token0Amount, token1Amount)

    const swapAmount = expandTo18Decimals(1)
    await token1.transfer(pair.address, swapAmount)
    await mineBlock(provider, bigNumberify((await provider.getBlock('latest')).timestamp).add(1))
    const tx = await pair.swap(swapAmount, 0, wallet.address, '0x', overrides)
    const receipt = await tx.wait()
    expect(receipt.gasUsed).to.eq(64406) // v2 uni was 73462
  })

  // Modified test to swap 1:1 token, just to check gas prices of swap
  it('xybk swap:gas', async () => {
    const token0Amount = expandTo18Decimals(10)
    const token1Amount = expandTo18Decimals(5)
    await addLiquidity(token0Amount, token1Amount)
    await pair.makeXybk(10, 10) // boost0=10, boost1=10
    t = bigNumberify((await provider.getBlock('latest')).timestamp)
    await mineBlock(provider, t.add(ONE_DAY))

    await pair.sync(overrides)

    const swapAmount = expandTo18Decimals(1)
    await token1.transfer(pair.address, swapAmount)
    await mineBlock(provider, bigNumberify((await provider.getBlock('latest')).timestamp).add(1))
    const tx = await pair.swap(swapAmount, 0, wallet.address, '0x', overrides) // Testing gas fee
    const receipt = await tx.wait()
    expect(receipt.gasUsed).to.eq(86544)
  })

  interface linInterpolateTestCase {
    b1: BigNumber
    b2: BigNumber
    tests: number[][]
  }

  const linInterpolate: linInterpolateTestCase[] = [
    {
      b1: bigNumberify(50).add(1),
      b2: bigNumberify(50).add(1).mul(2), // Interpolate between 1 and 51 -> increases 1 per block, 1 and 101 -> increases 2 per block
      tests: [
        [1, 2, 3],
        [2, 3, 5],
        [10, 11, 21],
      ],
    },
    {
      b1: bigNumberify(87),
      b2: bigNumberify(119),
      tests: [
        [1, 2, 3],
        [2, 4, 5],
        [3, 6, 8],
        [4, 7, 10],
        [5, 9, 12],
        [6, 11, 15],
        [7, 13, 17],
        [8, 14, 19],
        [30, 52, 71],
        [45, 78, 107],
      ],
    },
  ]

  /* Python code for testcase 2:
  import numpy as np
  x = np.arange(1, 51, 1)
  y = 1 + x*86/50
  z = 1 + x*118/50
  print(y)
  print(z)
  */

  linInterpolate.forEach((boostVals, i) => {
    it(`xybk lin interpolate test:${i}`, async () => {
      t = bigNumberify((await provider.getBlock('latest')).timestamp)
      await expect(pair.makeXybk(boostVals.b1, boostVals.b2))
        .to.emit(pair, 'ChangeInvariant')
        .withArgs(true, boostVals.b1, boostVals.b2)
        .to.emit(pair, 'UpdatedBoost')

      const currTimestamp = bigNumberify((await provider.getBlock('latest')).timestamp)
      expect(currTimestamp).to.eq(bigNumberify(await pair.startTime()))
      expect(currTimestamp.add(ONE_DAY)).to.eq(bigNumberify(await pair.endTime()))

      t = bigNumberify((await provider.getBlock('latest')).timestamp)

      for (var j = 0; j < boostVals.tests.length; j++) {
        await mineBlock(provider, t.add(bigNumberify(boostVals.tests[j][0]).mul(ONE_DAY).div(50)))
        boost = await pair.calcBoost()
        await expect(boost._boost0).to.equal(boostVals.tests[j][1])
        await expect(boost._boost1).to.equal(boostVals.tests[j][2])
      }

      // For 1st case, test interpolate downwards
      if (boost._boost0.toNumber() == 51) {
        t = bigNumberify((await provider.getBlock('latest')).timestamp)
        await expect(pair.makeXybk(1, 1))
          .to.emit(pair, 'ChangeInvariant')
          .withArgs(true, boostVals.b1, boostVals.b1)
          .to.emit(pair, 'UpdatedBoost')
          .withArgs(boostVals.b1, boostVals.b2, 1, 1, t, t)

        const expectedBoost = [
          [1, 50, 100],
          [2, 49, 98],
          [11, 39, 78],
        ]

        t = bigNumberify((await provider.getBlock('latest')).timestamp)
        for (var j = 0; j < expectedBoost.length; j++) {
          await mineBlock(provider, t.add(expectedBoost[j][0]))
          boost = await pair.calcBoost()
          await expect(boost._boost0.toNumber()).to.equal(expectedBoost[j][1])
          await expect(boost._boost1.toNumber()).to.equal(expectedBoost[j][2])
        }
      }
    })
  })

  // No change from uni
  it('feeTo:off', async () => {
    const token0Amount = expandTo18Decimals(1000)
    const token1Amount = expandTo18Decimals(1000)
    await addLiquidity(token0Amount, token1Amount)

    const swapAmount = expandTo18Decimals(1)
    const expectedOutputAmount = bigNumberify('996006981039903216')
    await token1.transfer(pair.address, swapAmount)
    await pair.swap(expectedOutputAmount, 0, wallet.address, '0x', overrides)

    const expectedLiquidity = expandTo18Decimals(1000)
    await pair.transfer(pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    await pair.burn(wallet.address, overrides)
    expect(await pair.totalSupply()).to.eq(MINIMUM_LIQUIDITY)
  })

  // Different from uni - we have higher fees
  it('feeTo:on', async () => {
    await factory.setFeeTo(other.address)

    const token0Amount = expandTo18Decimals(1000)
    const token1Amount = expandTo18Decimals(1000)
    await addLiquidity(token0Amount, token1Amount)

    const swapAmount = expandTo18Decimals(1)
    const expectedOutputAmount = bigNumberify('996006981039903216')
    await token1.transfer(pair.address, swapAmount)
    await pair.swap(expectedOutputAmount, 0, wallet.address, '0x', overrides)

    const expectedLiquidity = expandTo18Decimals(1000)
    await pair.transfer(pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
    await pair.burn(wallet.address, overrides)
    expect(await pair.balanceOf(other.address)).to.eq('4976323181643586162') // receives
    expect(await pair.totalSupply()).to.eq(MINIMUM_LIQUIDITY.add('4976323181643586162')) // approx 1/201 *

    // using 1000 here instead of the symbolic MINIMUM_LIQUIDITY because the amounts only happen to be equal...
    // ...because the initial liquidity amounts were equal
    expect(await token0.balanceOf(pair.address)).to.eq(bigNumberify(1000).add('4971360769329898722'))
    expect(await token1.balanceOf(pair.address)).to.eq(bigNumberify(1000).add('4981293533232937554'))
  })

  enum TradeState {
    SELL_ALL = 0,
    SELL_TOKEN_0 = 1,
    SELL_TOKEN_1 = 2,
    SELL_NONE = 3,
  }

  it('test tradestate', async () => {
    const token0Amount = expandTo18Decimals(1000)
    const token1Amount = expandTo18Decimals(1000)
    await addLiquidity(token0Amount, token1Amount)

    await pair.makeXybk(10, 10) // can only stop trade in xybk mode
    const sendAmount = expandTo18Decimals(2)
    const receiveAmount = expandTo18Decimals(1)

    await token0.transfer(pair.address, sendAmount)
    for (const i of [TradeState.SELL_TOKEN_0, TradeState.SELL_NONE]) {
      await pair.updateTradeState(i)
      await token0.transfer(pair.address, sendAmount)
      await expect(pair.swap(0, receiveAmount, wallet.address, '0x', overrides)).to.be.revertedWith(
        'IF: TRADE_NOT_ALLOWED'
      )
    }

    for (const i of [TradeState.SELL_ALL, TradeState.SELL_TOKEN_1]) {
      await pair.updateTradeState(i)
      await token0.transfer(pair.address, sendAmount)
      await expect(pair.swap(0, receiveAmount, wallet.address, '0x', overrides)).to.emit(pair, 'Sync') // Successful swap
    }

    await token1.transfer(pair.address, sendAmount)
    for (const i of [TradeState.SELL_TOKEN_1, TradeState.SELL_NONE]) {
      await pair.updateTradeState(i)
      await expect(pair.swap(receiveAmount, 0, wallet.address, '0x', overrides)).to.be.revertedWith(
        'IF: TRADE_NOT_ALLOWED'
      )
    }

    for (const i of [TradeState.SELL_ALL, TradeState.SELL_TOKEN_0]) {
      await pair.updateTradeState(i)
      await token1.transfer(pair.address, sendAmount)
      await expect(pair.swap(receiveAmount, 0, wallet.address, '0x', overrides)).to.emit(pair, 'Sync') // Successful swap
    }
  })
})
