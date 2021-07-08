import chai, { expect } from 'chai'
import { Contract } from 'ethers'
import { AddressZero, Zero, MaxUint256 } from 'ethers/constants'
import { BigNumber, bigNumberify } from 'ethers/utils'
import { solidity, MockProvider, createFixtureLoader } from 'ethereum-waffle'
import { ecsign } from 'ethereumjs-util'
import { expandTo18Decimals, getApprovalDigest, mineBlock, MINIMUM_LIQUIDITY } from './shared/utilities'
import { v2Fixture } from './shared/fixtures'

import ImpossiblePair from '../build/ImpossiblePair.json'

const ONE_DAY = 50

chai.use(solidity)

const overrides = {
  gasLimit: 9999999
}

enum RouterVersion {
  ImpossibleRouter01 = 'ImpossibleRouter01',
  ImpossibleRouter02 = 'ImpossibleRouter02'
}

describe('ImpossibleRouter01', () => {
  for (const routerVersion of Object.keys(RouterVersion)) {
    const provider = new MockProvider({
      hardfork: 'istanbul',
      mnemonic: 'horn horn horn horn horn horn horn horn horn horn horn horn',
      gasLimit: 9999999
    })
    const [wallet] = provider.getWallets()
    const loadFixture = createFixtureLoader(provider, [wallet])

    let token0: Contract
    let token1: Contract
    let WETH: Contract
    let WETHPartner: Contract
    let factory: Contract
    let router: Contract
    let pair: Contract
    let WETHPair: Contract
    let routerEventEmitter: Contract

    beforeEach(async function() {
      const fixture = await loadFixture(v2Fixture)
      WETH = fixture.WETH
      WETHPartner = fixture.WETHPartner
      factory = fixture.factoryV2
      router = {
        [RouterVersion.ImpossibleRouter01]: fixture.router01,
        [RouterVersion.ImpossibleRouter02]: fixture.router02
      }[routerVersion as RouterVersion]
      routerEventEmitter = fixture.routerEventEmitter

      // set whitelist router
      await factory.setRouter(router.address)

      await factory.createPair(fixture.tokenA.address, fixture.tokenB.address)
      const pairAddress = await factory.getPair(fixture.tokenA.address, fixture.tokenB.address)
      pair = new Contract(pairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)

      const token0Address = await pair.token0()
      token0 = fixture.tokenA.address === token0Address ? fixture.tokenA : fixture.tokenB
      token1 = fixture.tokenA.address === token0Address ? fixture.tokenB : fixture.tokenA

      await factory.createPair(WETH.address, WETHPartner.address)
      const WETHPairAddress = await factory.getPair(WETH.address, WETHPartner.address)
      WETHPair = new Contract(WETHPairAddress, JSON.stringify(ImpossiblePair.abi), provider).connect(wallet)
    })

    afterEach(async function() {
      expect(await provider.getBalance(router.address)).to.eq(Zero)
    })

    describe(routerVersion, () => {
      it('factory, WETH', async () => {
        expect(await router.factory()).to.eq(factory.address)
        expect(await router.WETH()).to.eq(WETH.address)
      })
      it('addLiquidity', async () => {
        const token0Amount = expandTo18Decimals(1)
        const token1Amount = expandTo18Decimals(4)

        const expectedLiquidity = expandTo18Decimals(2)
        await token0.approve(router.address, MaxUint256)
        await token1.approve(router.address, MaxUint256)

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
        const WETHPairToken0 = await WETHPair.token0()
        await WETHPartner.approve(router.address, MaxUint256)
        await expect(
          router.addLiquidityETH(
            WETHPartner.address,
            WETHPartnerAmount,
            WETHPartnerAmount,
            ETHAmount,
            wallet.address,
            MaxUint256,
            { ...overrides, value: ETHAmount }
          )
        )
          .to.emit(WETHPair, 'Transfer')
          .withArgs(AddressZero, AddressZero, MINIMUM_LIQUIDITY)
          .to.emit(WETHPair, 'Transfer')
          .withArgs(AddressZero, wallet.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
          .to.emit(WETHPair, 'Sync')
          .withArgs(
            WETHPairToken0 === WETHPartner.address ? WETHPartnerAmount : ETHAmount,
            WETHPairToken0 === WETHPartner.address ? ETHAmount : WETHPartnerAmount
          )
          .to.emit(WETHPair, 'Mint')
          .withArgs(
            router.address,
            WETHPairToken0 === WETHPartner.address ? WETHPartnerAmount : ETHAmount,
            WETHPairToken0 === WETHPartner.address ? ETHAmount : WETHPartnerAmount
          )

        expect(await WETHPair.balanceOf(wallet.address)).to.eq(expectedLiquidity.sub(MINIMUM_LIQUIDITY))
      })

      async function addLiquidity(token0Amount: BigNumber, token1Amount: BigNumber) {
        await token0.transfer(pair.address, token0Amount)
        await token1.transfer(pair.address, token1Amount)
        await pair.mint(wallet.address, overrides)
      }

      it('removeLiquidity', async () => {
        const token0Amount = expandTo18Decimals(1)
        const token1Amount = expandTo18Decimals(4)
        await addLiquidity(token0Amount, token1Amount)

        const expectedLiquidity = expandTo18Decimals(2)
        await pair.approve(router.address, MaxUint256)
        await expect(
          router.removeLiquidity(
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
          .to.emit(pair, 'Transfer')
          .withArgs(wallet.address, pair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
          .to.emit(pair, 'Transfer')
          .withArgs(pair.address, AddressZero, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
          .to.emit(token0, 'Transfer')
          .withArgs(pair.address, wallet.address, token0Amount.sub(500))
          .to.emit(token1, 'Transfer')
          .withArgs(pair.address, wallet.address, token1Amount.sub(2000))
          .to.emit(pair, 'Sync')
          .withArgs(500, 2000)
          .to.emit(pair, 'Burn')
          .withArgs(router.address, token0Amount.sub(500), token1Amount.sub(2000), wallet.address)

        expect(await pair.balanceOf(wallet.address)).to.eq(0)
        const totalSupplyToken0 = await token0.totalSupply()
        const totalSupplyToken1 = await token1.totalSupply()
        expect(await token0.balanceOf(wallet.address)).to.eq(totalSupplyToken0.sub(500))
        expect(await token1.balanceOf(wallet.address)).to.eq(totalSupplyToken1.sub(2000))
      })

      it('removeLiquidityETH', async () => {
        const WETHPartnerAmount = expandTo18Decimals(1)
        const ETHAmount = expandTo18Decimals(4)
        await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
        await WETH.deposit({ value: ETHAmount })
        await WETH.transfer(WETHPair.address, ETHAmount)
        await WETHPair.mint(wallet.address, overrides)

        const expectedLiquidity = expandTo18Decimals(2)
        const WETHPairToken0 = await WETHPair.token0()
        await WETHPair.approve(router.address, MaxUint256)
        await expect(
          router.removeLiquidityETH(
            WETHPartner.address,
            expectedLiquidity.sub(MINIMUM_LIQUIDITY),
            0,
            0,
            wallet.address,
            MaxUint256,
            overrides
          )
        )
          .to.emit(WETHPair, 'Transfer')
          .withArgs(wallet.address, WETHPair.address, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
          .to.emit(WETHPair, 'Transfer')
          .withArgs(WETHPair.address, AddressZero, expectedLiquidity.sub(MINIMUM_LIQUIDITY))
          .to.emit(WETH, 'Transfer')
          .withArgs(WETHPair.address, router.address, ETHAmount.sub(2000))
          .to.emit(WETHPartner, 'Transfer')
          .withArgs(WETHPair.address, router.address, WETHPartnerAmount.sub(500))
          .to.emit(WETHPartner, 'Transfer')
          .withArgs(router.address, wallet.address, WETHPartnerAmount.sub(500))
          .to.emit(WETHPair, 'Sync')
          .withArgs(
            WETHPairToken0 === WETHPartner.address ? 500 : 2000,
            WETHPairToken0 === WETHPartner.address ? 2000 : 500
          )
          .to.emit(WETHPair, 'Burn')
          .withArgs(
            router.address,
            WETHPairToken0 === WETHPartner.address ? WETHPartnerAmount.sub(500) : ETHAmount.sub(2000),
            WETHPairToken0 === WETHPartner.address ? ETHAmount.sub(2000) : WETHPartnerAmount.sub(500),
            router.address
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
        await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
        await WETH.deposit({ value: ETHAmount })
        await WETH.transfer(WETHPair.address, ETHAmount)
        await WETHPair.mint(wallet.address, overrides)

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
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, swapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 99920, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 99920
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 10, 10) // ratiostart=0, ratioend=100, boost0=10, boost1=10
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, swapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 137445, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 137445
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, swapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 137825, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 137825
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, swapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 137837, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 137837
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, swapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, expectedOutputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(swapAmount), token1Amount.sub(expectedOutputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, swapAmount, 0, 0, expectedOutputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 138927, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 138927
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, expectedSwapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, outputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 104080, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 104080
            }[routerVersion as RouterVersion]
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
          await pair.makeXybk(0, 100, 10, 10) // ratiostart=0, ratioend=100, boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, expectedSwapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, outputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 137660, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 137660
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, expectedSwapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, outputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 138040, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 138040
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, expectedSwapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, outputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 138052, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 138052
            }[routerVersion as RouterVersion]
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
          await token0.approve(router.address, MaxUint256)
          await pair.makeXybk(0, 100, 28, 11) // ratiostart=0, ratioend=100, boost0=10, boost1=10
          let t: number
          t = (await provider.getBlock('latest')).timestamp // Mine blocks so staggering boost kicks in to test boost=10
          for (var i = 0; i < ONE_DAY; i++) {
            await mineBlock(provider, ++t)
          }
        })

        it('happy path', async () => {
          await token0.approve(router.address, MaxUint256)
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
            .to.emit(token0, 'Transfer')
            .withArgs(wallet.address, pair.address, expectedSwapAmount)
            .to.emit(token1, 'Transfer')
            .withArgs(pair.address, wallet.address, outputAmount)
            .to.emit(pair, 'Sync')
            .withArgs(token0Amount.add(expectedSwapAmount), token1Amount.sub(outputAmount))
            .to.emit(pair, 'Swap')
            .withArgs(router.address, expectedSwapAmount, 0, 0, outputAmount, wallet.address)
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 139142, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 139142
            }[routerVersion as RouterVersion]
          )
        })
      })

      describe('swapExactETHForTokens', () => {
        const WETHPartnerAmount = expandTo18Decimals(10)
        const ETHAmount = expandTo18Decimals(5)
        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = bigNumberify('1662497915624478906')

        beforeEach(async () => {
          await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
          await WETH.deposit({ value: ETHAmount })
          await WETH.transfer(WETHPair.address, ETHAmount)
          await WETHPair.mint(wallet.address, overrides)

          await token0.approve(router.address, MaxUint256)
        })

        it('happy path', async () => {
          const WETHPairToken0 = await WETHPair.token0()
          await expect(
            router.swapExactETHForTokens(0, [WETH.address, WETHPartner.address], wallet.address, MaxUint256, {
              ...overrides,
              value: swapAmount
            })
          )
            .to.emit(WETH, 'Transfer')
            .withArgs(router.address, WETHPair.address, swapAmount)
            .to.emit(WETHPartner, 'Transfer')
            .withArgs(WETHPair.address, wallet.address, expectedOutputAmount)
            .to.emit(WETHPair, 'Sync')
            .withArgs(
              WETHPairToken0 === WETHPartner.address
                ? WETHPartnerAmount.sub(expectedOutputAmount)
                : ETHAmount.add(swapAmount),
              WETHPairToken0 === WETHPartner.address
                ? ETHAmount.add(swapAmount)
                : WETHPartnerAmount.sub(expectedOutputAmount)
            )
            .to.emit(WETHPair, 'Swap')
            .withArgs(
              router.address,
              WETHPairToken0 === WETHPartner.address ? 0 : swapAmount,
              WETHPairToken0 === WETHPartner.address ? swapAmount : 0,
              WETHPairToken0 === WETHPartner.address ? expectedOutputAmount : 0,
              WETHPairToken0 === WETHPartner.address ? 0 : expectedOutputAmount,
              wallet.address
            )
        })

        it('gas', async () => {
          const WETHPartnerAmount = expandTo18Decimals(10)
          const ETHAmount = expandTo18Decimals(5)
          await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
          await WETH.deposit({ value: ETHAmount })
          await WETH.transfer(WETHPair.address, ETHAmount)
          await WETHPair.mint(wallet.address, overrides)

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
              value: swapAmount
            }
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [RouterVersion.ImpossibleRouter01]: 106996, // Uni was 138770
              [RouterVersion.ImpossibleRouter02]: 106996
            }[routerVersion as RouterVersion]
          )
        })
      })

      describe('swapTokensForExactETH', () => {
        const WETHPartnerAmount = expandTo18Decimals(5)
        const ETHAmount = expandTo18Decimals(10)
        const expectedSwapAmount = bigNumberify('557227237267357629')
        const outputAmount = expandTo18Decimals(1)

        beforeEach(async () => {
          await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
          await WETH.deposit({ value: ETHAmount })
          await WETH.transfer(WETHPair.address, ETHAmount)
          await WETHPair.mint(wallet.address, overrides)
        })

        it('happy path', async () => {
          await WETHPartner.approve(router.address, MaxUint256)
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
            .to.emit(WETHPartner, 'Transfer')
            .withArgs(wallet.address, WETHPair.address, expectedSwapAmount)
            .to.emit(WETH, 'Transfer')
            .withArgs(WETHPair.address, router.address, outputAmount)
            .to.emit(WETHPair, 'Sync')
            .withArgs(
              WETHPairToken0 === WETHPartner.address
                ? WETHPartnerAmount.add(expectedSwapAmount)
                : ETHAmount.sub(outputAmount),
              WETHPairToken0 === WETHPartner.address
                ? ETHAmount.sub(outputAmount)
                : WETHPartnerAmount.add(expectedSwapAmount)
            )
            .to.emit(WETHPair, 'Swap')
            .withArgs(
              router.address,
              WETHPairToken0 === WETHPartner.address ? expectedSwapAmount : 0,
              WETHPairToken0 === WETHPartner.address ? 0 : expectedSwapAmount,
              WETHPairToken0 === WETHPartner.address ? 0 : outputAmount,
              WETHPairToken0 === WETHPartner.address ? outputAmount : 0,
              router.address
            )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await WETHPartner.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 122101, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 122101
            }[routerVersion as RouterVersion]
          )
        })
      })

      describe('swapExactTokensForETH', () => {
        const WETHPartnerAmount = expandTo18Decimals(5)
        const ETHAmount = expandTo18Decimals(10)
        const swapAmount = expandTo18Decimals(1)
        const expectedOutputAmount = bigNumberify('1662497915624478906')

        beforeEach(async () => {
          await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
          await WETH.deposit({ value: ETHAmount })
          await WETH.transfer(WETHPair.address, ETHAmount)
          await WETHPair.mint(wallet.address, overrides)
        })

        it('happy path', async () => {
          await WETHPartner.approve(router.address, MaxUint256)
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
            .to.emit(WETHPartner, 'Transfer')
            .withArgs(wallet.address, WETHPair.address, swapAmount)
            .to.emit(WETH, 'Transfer')
            .withArgs(WETHPair.address, router.address, expectedOutputAmount)
            .to.emit(WETHPair, 'Sync')
            .withArgs(
              WETHPairToken0 === WETHPartner.address
                ? WETHPartnerAmount.add(swapAmount)
                : ETHAmount.sub(expectedOutputAmount),
              WETHPairToken0 === WETHPartner.address
                ? ETHAmount.sub(expectedOutputAmount)
                : WETHPartnerAmount.add(swapAmount)
            )
            .to.emit(WETHPair, 'Swap')
            .withArgs(
              router.address,
              WETHPairToken0 === WETHPartner.address ? swapAmount : 0,
              WETHPairToken0 === WETHPartner.address ? 0 : swapAmount,
              WETHPairToken0 === WETHPartner.address ? 0 : expectedOutputAmount,
              WETHPairToken0 === WETHPartner.address ? expectedOutputAmount : 0,
              router.address
            )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await WETHPartner.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
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
              [RouterVersion.ImpossibleRouter01]: 117942, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 117942
            }[routerVersion as RouterVersion]
          )
        })
      })

      describe('swapETHForExactTokens', () => {
        const WETHPartnerAmount = expandTo18Decimals(10)
        const ETHAmount = expandTo18Decimals(5)
        const expectedSwapAmount = bigNumberify('557227237267357629')
        const outputAmount = expandTo18Decimals(1)

        beforeEach(async () => {
          await WETHPartner.transfer(WETHPair.address, WETHPartnerAmount)
          await WETH.deposit({ value: ETHAmount })
          await WETH.transfer(WETHPair.address, ETHAmount)
          await WETHPair.mint(wallet.address, overrides)
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
                value: expectedSwapAmount
              }
            )
          )
            .to.emit(WETH, 'Transfer')
            .withArgs(router.address, WETHPair.address, expectedSwapAmount)
            .to.emit(WETHPartner, 'Transfer')
            .withArgs(WETHPair.address, wallet.address, outputAmount)
            .to.emit(WETHPair, 'Sync')
            .withArgs(
              WETHPairToken0 === WETHPartner.address
                ? WETHPartnerAmount.sub(outputAmount)
                : ETHAmount.add(expectedSwapAmount),
              WETHPairToken0 === WETHPartner.address
                ? ETHAmount.add(expectedSwapAmount)
                : WETHPartnerAmount.sub(outputAmount)
            )
            .to.emit(WETHPair, 'Swap')
            .withArgs(
              router.address,
              WETHPairToken0 === WETHPartner.address ? 0 : expectedSwapAmount,
              WETHPairToken0 === WETHPartner.address ? expectedSwapAmount : 0,
              WETHPairToken0 === WETHPartner.address ? outputAmount : 0,
              WETHPairToken0 === WETHPartner.address ? 0 : outputAmount,
              wallet.address
            )
        })

        it('gas', async () => {
          // ensure that setting price{0,1}CumulativeLast for the first time doesn't affect our gas math
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          await pair.sync(overrides)

          await token0.approve(router.address, MaxUint256)
          await mineBlock(provider, (await provider.getBlock('latest')).timestamp + 1)
          const tx = await router.swapETHForExactTokens(
            outputAmount,
            [WETH.address, WETHPartner.address],
            wallet.address,
            MaxUint256,
            {
              ...overrides,
              value: expectedSwapAmount
            }
          )
          const receipt = await tx.wait()
          expect(receipt.gasUsed).to.eq(
            {
              [RouterVersion.ImpossibleRouter01]: 110962, // Uni was 101876
              [RouterVersion.ImpossibleRouter02]: 110962
            }[routerVersion as RouterVersion]
          )
        })
      })
    })
  }
})
