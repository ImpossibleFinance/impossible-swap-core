import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import { AddressZero, Zero, MaxUint256 } from 'ethers/constants'
import { BigNumber, bigNumberify } from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'
import { ecsign, zeroAddress } from 'ethereumjs-util'
import { expandTo18Decimals, getApprovalDigest, mineBlock, MINIMUM_LIQUIDITY } from './shared/utilities'
import { v2Fixture } from './shared/fixtures'

import ImpossiblePair from '../build/ImpossiblePair.json'
import ImpossibleWrappedToken from '../build/ImpossibleWrappedToken.json'

const ONE_DAY = 50
let flag = 0

chai.use(solidity)

const overrides = {
  gasLimit: 9999999,
}

enum TestVersion {
  basic = 'basic',
  wrapper = 'wrapper',
}

describe('ImpossibleRouter01Tests', () => {
  for (const testVersion of Object.keys(TestVersion)) {
    const provider = new MockProvider({
      hardfork: 'istanbul',
      mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
      gasLimit: 9999999,
    })
    const [wallet] = provider.getWallets()
    const loadFixture = createFixtureLoader(provider, [wallet])

    let WETH: Contract
    let factory: Contract
    let wrapFactory: Contract
    let router: Contract
    let routerExtension: Contract

    let addLiquidity: Function
    let addLiquidityEth: Function

    // Token0, token1, tokenA, WETHPartner could be wrappers. Use mayBeUnderlyingX for approve operations

    let token0: Contract
    let token1: Contract
    let underlyingToken0: Contract
    let underlyingToken1: Contract

    let tokenA: Contract
    let WETHPartner: Contract
    let underlyingTokenA: Contract
    let underlyingWETHPartner: Contract

    let pair: Contract
    let WETHPair: Contract

    beforeEach(async function () {
      const fixture = await loadFixture(v2Fixture)
      WETH = fixture.WETH
      underlyingWETHPartner = fixture.WETHPartner
      underlyingTokenA = fixture.tokenA
      factory = fixture.pairFactory
      router = fixture.router
      wrapFactory = fixture.wrapFactory
      routerExtension = fixture.routerExtension

      // set whitelist router
      await factory.setRouterAndExtension(router.address, routerExtension.address)

      if ((testVersion as TestVersion) == 'wrapper') {
        await wrapFactory.createPairing(underlyingTokenA.address, 1, 3) // 6 underlying token = 1 wrapped token
        const tokenAWrapperAddr = await wrapFactory.tokensToWrappedTokens(underlyingTokenA.address)
        tokenA = new Contract(tokenAWrapperAddr, JSON.stringify(ImpossibleWrappedToken.abi), provider).connect(wallet)
        await factory.changeTokenAccess(tokenA.address, true)
        await wrapFactory.createPairing(underlyingWETHPartner.address, 1, 3) // 8 underlying token = 1 wrapped token
        const wethPartnerWrapperAddress = await wrapFactory.tokensToWrappedTokens(underlyingWETHPartner.address)
        WETHPartner = new Contract(
          wethPartnerWrapperAddress,
          JSON.stringify(ImpossibleWrappedToken.abi),
          provider
        ).connect(wallet)
        await factory.changeTokenAccess(WETHPartner.address, true)
      } else {
        tokenA = underlyingTokenA
        WETHPartner = underlyingWETHPartner
      }

      await factory.createPair(tokenA.address, fixture.tokenB.address)
      const pairAddress = await factory.getPair(tokenA.address, fixture.tokenB.address)
      pair = new Contract(pairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)

      const token0Address = await pair.token0()
      token0 = tokenA.address === token0Address ? tokenA : fixture.tokenB
      token1 = tokenA.address === token0Address ? fixture.tokenB : tokenA

      underlyingToken0 = tokenA.address === token0Address ? underlyingTokenA : fixture.tokenB
      underlyingToken1 = tokenA.address === token0Address ? fixture.tokenB : underlyingTokenA

      await factory.createPair(WETH.address, WETHPartner.address)
      const WETHPairAddress = await factory.getPair(WETH.address, WETHPartner.address)
      WETHPair = new Contract(WETHPairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)

      addLiquidity = async (token0Amount: BigNumber, token1Amount: BigNumber) => {
        await underlyingToken0.approve(router.address, MaxUint256)
        await underlyingToken1.approve(router.address, MaxUint256)

        await router.addLiquidity(
          token0.address,
          token1.address,
          token0Amount,
          token1Amount,
          0,
          0,
          wallet.address,
          MaxUint256,
          overrides
        )
      }

      addLiquidityEth = async (WETHPartnerAmount: BigNumber, ETHAmount: BigNumber) => {
        await underlyingWETHPartner.approve(router.address, MaxUint256)
        await router.addLiquidityETH(
          WETHPartner.address,
          WETHPartnerAmount,
          WETHPartnerAmount,
          ETHAmount,
          wallet.address,
          MaxUint256,
          { ...overrides, value: ETHAmount }
        )
      }
    })

    afterEach(async function () {
      expect(await provider.getBalance(router.address)).to.eq(Zero)
    })

    describe(testVersion, () => {
      it('factory, WETH', async () => {
        expect(await router.factory()).to.eq(factory.address)
        expect(await router.WETH()).to.eq(WETH.address)
      })

      it('addLiquidity', async () => {
        const token0Amount = expandTo18Decimals(1)
        const token1Amount = expandTo18Decimals(4)

        const expectedLiquidity = expandTo18Decimals(2)
        await underlyingToken0.approve(router.address, MaxUint256)
        await underlyingToken1.approve(router.address, MaxUint256)

        expect(
          await router.addLiquidity(
            token0.address,
            token1.address,
            token0Amount,
            token1Amount,
            0,
            0,
            wallet.address,
            MaxUint256,
            overrides
          )
        )

        expect(await pair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      })

      it('addLiquidityETH', async () => {
        const WETHPartnerAmount = expandTo18Decimals(1)
        const ETHAmount = expandTo18Decimals(4)

        const expectedLiquidity = expandTo18Decimals(2)
        await underlyingWETHPartner.approve(router.address, MaxUint256)
        expect(
          await router.addLiquidityETH(WETHPartner.address, WETHPartnerAmount, 0, 0, wallet.address, MaxUint256, {
            ...overrides,
            value: ETHAmount,
          })
        )
        expect(await WETHPair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      })

      it('removeLiquidity', async () => {
        const token0Amount = expandTo18Decimals(1)
        const token1Amount = expandTo18Decimals(4)
        await addLiquidity(token0Amount, token1Amount)

        const expectedLiquidity = expandTo18Decimals(2)

        await pair.approve(router.address, MaxUint256)

        expect(
          await router.removeLiquidity(
            token0.address,
            token1.address,
            expectedLiquidity.sub(MINIMUM_LIQUIDITY),
            0,
            0,
            wallet.address,
            MaxUint256,
            overrides
          )
        )
      })

      it('removeLiquidityETH', async () => {
        const WETHPartnerAmount = expandTo18Decimals(1)
        const ETHAmount = expandTo18Decimals(4)
        await addLiquidityEth(WETHPartnerAmount, ETHAmount)

        const expectedLiquidity = expandTo18Decimals(2)
        const WETHPairToken0 = await WETHPair.token0()
        await WETHPair.approve(router.address, MaxUint256)
        expect(
          await router.removeLiquidityETH(
            WETHPartner.address,
            expectedLiquidity.sub(MINIMUM_LIQUIDITY),
            0,
            0,
            wallet.address,
            MaxUint256,
            overrides
          )
        )

        expect(await WETHPair.balanceOf(wallet.address)).to.eq(0)
        const totalSupplyWETHPartner = await WETHPartner.totalSupply()
        const totalSupplyWETH = await WETH.totalSupply()
        expect(await WETHPartner.balanceOf(wallet.address)).to.eq(totalSupplyWETHPartner.sub(500))
        expect(await WETH.balanceOf(wallet.address)).to.eq(totalSupplyWETH.sub(2000))
      })

      it('removeLiquidityWithPermit', async () => {
        const token0Amount = expandTo18Decimals(1)
        const token1Amount = expandTo18Decimals(4)
        await addLiquidity(token0Amount, token1Amount)

        const expectedLiquidity = expandTo18Decimals(2)

        const nonce = await pair.nonces(wallet.address)
        const digest = await getApprovalDigest(
          pair,
          { owner: wallet.address, spender: router.address, value: expectedLiquidity.sub(MINIMUM_LIQUIDITY) },
          nonce,
          MaxUint256
        )

        const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(wallet.privateKey.slice(2), 'hex'))

        await router.removeLiquidityWithPermit(
          token0.address,
          token1.address,
          expectedLiquidity.sub(MINIMUM_LIQUIDITY),
          0,
          0,
          wallet.address,
          MaxUint256,
          false,
          v,
          r,
          s,
          overrides
        )
      })

      it('removeLiquidityETHWithPermit', async () => {
        const WETHPartnerAmount = expandTo18Decimals(1)
        const ETHAmount = expandTo18Decimals(4)
        await addLiquidityEth(WETHPartnerAmount, ETHAmount)

        const expectedLiquidity = expandTo18Decimals(2)

        const nonce = await WETHPair.nonces(wallet.address)
        const digest = await getApprovalDigest(
          WETHPair,
          { owner: wallet.address, spender: router.address, value: expectedLiquidity.sub(MINIMUM_LIQUIDITY) },
          nonce,
          MaxUint256
        )

        const { v, r, s } = ecsign(Buffer.from(digest.slice(2), 'hex'), Buffer.from(wallet.privateKey.slice(2), 'hex'))

        await router.removeLiquidityETHWithPermit(
          WETHPartner.address,
          expectedLiquidity.sub(MINIMUM_LIQUIDITY),
          0,
          0,
          wallet.address,
          MaxUint256,
          false,
          v,
          r,
          s,
          overrides
        )
      })

      describe('uni swapExactTokensForTokens', () => {
        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = bigNumberify('1662497915624478906')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
        })

        it('happy path', async () => {
          await expect(
            router.swapExactTokensForTokens(
              swapAmount,
              0,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForTokens(
            swapAmount,
            0,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 117734, // Uni was 101876
              [TestVersion.wrapper]: 168185,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapExactTokensForTokens, single boost', () => {
        const token0Amount = expandTo18Decimals(96)
        const token1Amount = expandTo18Decimals(101)
        const swapAmount = expandTo18Decimals(10)
        const expectedOutputAmount = bigNumberify('9920071714348123486')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(10, 10) // boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks till boost kicks in for boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await expect(
            router.swapExactTokensForTokens(
              swapAmount,
              0,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForTokens(
            swapAmount,
            0,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153490, // Uni was 101876
              [TestVersion.wrapper]: 203942,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapExactTokensForTokens, double boost, case 1', () => {
        const token0Amount = bigNumberify('98000000000000000000')
        const token1Amount = bigNumberify('100000000000000000000')
        const swapAmount = bigNumberify('10000000000000000000')
        const expectedOutputAmount = bigNumberify('9941982512178805534')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // boost0=28, boost1=11
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await expect(
            router.swapExactTokensForTokens(
              swapAmount,
              0,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForTokens(
            swapAmount,
            0,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153697, // Uni was 101876
              [TestVersion.wrapper]: 204149,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapExactTokensForTokens, double boost, case 2', () => {
        const token0Amount = bigNumberify('102324241243449991944')
        const token1Amount = bigNumberify('124882484835838434422')
        const swapAmount = bigNumberify('50000000000000000000')
        const expectedOutputAmount = bigNumberify('49488329728372278747')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // boost0=28, boost1=11
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await expect(
            router.swapExactTokensForTokens(
              swapAmount,
              0,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForTokens(
            swapAmount,
            0,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153709, // Uni was 101876
              [TestVersion.wrapper]: 204161,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapExactTokensForTokens, double boost, case 3', () => {
        const token0Amount = bigNumberify('1242493953959349219344')
        const token1Amount = bigNumberify('1310000000000000000000')
        const swapAmount = bigNumberify('1000000000000000000000')
        const expectedOutputAmount = bigNumberify('971795130187252602772')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await expect(
            router.swapExactTokensForTokens(
              swapAmount,
              0,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForTokens(
            swapAmount,
            0,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 154472, // Uni was 101876
              [TestVersion.wrapper]: 204924,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('uni swapTokensForExactTokens', () => {
        const token0Amount = expandTo18Decimals(5)
        const token1Amount = expandTo18Decimals(10)
        const expectedSwapAmount = bigNumberify('557227237267357629')
        const outputAmount = expandTo18Decimals(1)

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
        })

        it('happy path', async () => {
          await underlyingToken0.approve(router.address, MaxUint256)
          await expect(
            router.swapTokensForExactTokens(
              outputAmount,
              MaxUint256,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactTokens(
            outputAmount,
            MaxUint256,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 121858, // Uni was 101876
              [TestVersion.wrapper]: 172309,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapTokensForExactTokens, single boost', () => {
        const token0Amount = expandTo18Decimals(96)
        const token1Amount = expandTo18Decimals(101)
        const expectedSwapAmount = expandTo18Decimals(10)
        const outputAmount = bigNumberify('9920071714348123486')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await pair.makeXybk(10, 10) // boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await underlyingToken0.approve(router.address, MaxUint256)
          await expect(
            router.swapTokensForExactTokens(
              outputAmount,
              MaxUint256,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactTokens(
            outputAmount,
            MaxUint256,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153586, // Uni was 101876
              [TestVersion.wrapper]: 204037,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapTokensForExactTokens, double boost, case 1', () => {
        const token0Amount = bigNumberify('98000000000000000000')
        const token1Amount = bigNumberify('100000000000000000000')
        const expectedSwapAmount = bigNumberify('10000000000000000000')
        const outputAmount = bigNumberify('9941982512178805534')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await underlyingToken0.approve(router.address, MaxUint256)
          await expect(
            router.swapTokensForExactTokens(
              outputAmount,
              MaxUint256,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactTokens(
            outputAmount,
            MaxUint256,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153793, // Uni was 101876
              [TestVersion.wrapper]: 204244,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapTokensForExactTokens, double boost, case 2', () => {
        const token0Amount = bigNumberify('102324241243449991944')
        const token1Amount = bigNumberify('124882484835838434422')
        const expectedSwapAmount = bigNumberify('50000000000000000000') // Off by 1 gwei
        const outputAmount = bigNumberify('49488329728372278747')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // boost0=28, boost1=11
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await underlyingToken0.approve(router.address, MaxUint256)
          await expect(
            router.swapTokensForExactTokens(
              outputAmount,
              MaxUint256,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactTokens(
            outputAmount,
            MaxUint256,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 153805, // Uni was 101876
              [TestVersion.wrapper]: 204256,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('xybk swapTokensForExactTokens, double boost, case 3', () => {
        const token0Amount = bigNumberify('1242493953959349219344')
        const token1Amount = bigNumberify('1310000000000000000000')
        const expectedSwapAmount = bigNumberify('1000000000000000000000')
        const outputAmount = bigNumberify('971795130187252602772')

        beforeEach(async () => {
          await addLiquidity(token0Amount, token1Amount)
          await underlyingToken0.approve(router.address, MaxUint256)
          await pair.makeXybk(28, 11) // ratiostart=0, ratioend=100, boost0=28, boost1=11
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await underlyingToken0.approve(router.address, MaxUint256)
          await expect(
            router.swapTokensForExactTokens(
              outputAmount,
              MaxUint256,
              [token0.address, token1.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactTokens(
            outputAmount,
            MaxUint256,
            [token0.address, token1.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 154568, // Uni was 101876
              [TestVersion.wrapper]: 205019,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('swapExactETHForTokens', () => {
        const WETHPartnerAmount = expandTo18Decimals(10)
        const ETHAmount = expandTo18Decimals(5)
        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = bigNumberify('1662497915624478906')

        beforeEach(async () => {
          await addLiquidityEth(WETHPartnerAmount, ETHAmount)
        })

        it('happy path', async () => {
          const WETHPairToken0 = await WETHPair.token0()
          await expect(
            router.swapExactETHForTokens(0, [WETH.address, WETHPartner.address], wallet.address, MaxUint256, {
              ...overrides,
              value: swapAmount,
            })
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          const swapAmount = expandTo18Decimals(1)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactETHForTokens(
            0,
            [WETH.address, WETHPartner.address],
            wallet.address,
            MaxUint256,
            {
              ...overrides,
              value: swapAmount,
            }
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 124196, // Uni was 101876
              [TestVersion.wrapper]: 151758,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('swapTokensForExactETH', () => {
        const WETHPartnerAmount = expandTo18Decimals(5)
        const ETHAmount = expandTo18Decimals(10)
        const expectedSwapAmount = bigNumberify('557227237267357629')
        const outputAmount = expandTo18Decimals(1)

        beforeEach(async () => {
          await addLiquidityEth(WETHPartnerAmount, ETHAmount)
        })

        it('happy path', async () => {
          await underlyingWETHPartner.approve(router.address, MaxUint256)
          const WETHPairToken0 = await WETHPair.token0()
          await expect(
            router.swapTokensForExactETH(
              outputAmount,
              MaxUint256,
              [WETHPartner.address, WETH.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await underlyingWETHPartner.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapTokensForExactETH(
            outputAmount,
            MaxUint256,
            [WETHPartner.address, WETH.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 131663, // Uni was 101876
              [TestVersion.wrapper]: 182194,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('swapExactTokensForETH', () => {
        const WETHPartnerAmount = expandTo18Decimals(5)
        const ETHAmount = expandTo18Decimals(10)
        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = bigNumberify('1662497915624478906')

        beforeEach(async () => {
          await addLiquidityEth(WETHPartnerAmount, ETHAmount)
        })

        it('happy path', async () => {
          await underlyingWETHPartner.approve(router.address, MaxUint256)
          const WETHPairToken0 = await WETHPair.token0()
          await expect(
            router.swapExactTokensForETH(
              swapAmount,
              0,
              [WETHPartner.address, WETH.address],
              wallet.address,
              MaxUint256,
              overrides
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await underlyingWETHPartner.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapExactTokensForETH(
            swapAmount,
            0,
            [WETHPartner.address, WETH.address],
            wallet.address,
            MaxUint256,
            overrides
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 127436, // Uni was 101876
              [TestVersion.wrapper]: 177967,
            }[testVersion as TestVersion]
          )
        })
      })

      describe('swapETHForExactTokens', () => {
        const WETHPartnerAmount = expandTo18Decimals(10)
        const ETHAmount = expandTo18Decimals(5)
        const expectedSwapAmount = bigNumberify('557227237267357629')
        const outputAmount = expandTo18Decimals(1)

        beforeEach(async () => {
          await addLiquidityEth(WETHPartnerAmount, ETHAmount)
        })

        it('happy path', async () => {
          const WETHPairToken0 = await WETHPair.token0()
          await expect(
            router.swapETHForExactTokens(
              outputAmount,
              [WETH.address, WETHPartner.address],
              wallet.address,
              MaxUint256,
              {
                ...overrides,
                value: expectedSwapAmount,
              }
            )
          )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await underlyingToken0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapETHForExactTokens(
            outputAmount,
            [WETH.address, WETHPartner.address],
            wallet.address,
            MaxUint256,
            {
              ...overrides,
              value: expectedSwapAmount,
            }
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [TestVersion.basic]: 128125, // Uni was 101876
              [TestVersion.wrapper]: 155688,
            }[testVersion as TestVersion]
          )
        })
      })
    })
  }
})
