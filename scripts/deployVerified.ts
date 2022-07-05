import hre from 'hardhat'
import { txParams } from './utils/transactionHelpers'


async function deployVerified(contractName: string, args: any[]) :Promise<string> {
  const ethParams = await txParams()
  const ContractFactory = await hre.ethers.getContractFactory(contractName)
  const contract = await ContractFactory.deploy(
    ...args,
    {
      gasPrice: ethParams.txGasPrice,
      gasLimit: ethParams.txGasLimit,
    },
  )
  console.log(`${contractName} deployed at ${contract.address}`)
  await hre.run("verify:verify", {
    address: contract.address,
    constructorArguments: args
  })
  return contract.address
}

export async function main(): Promise<void> {
  const signer = (await hre.ethers.getSigners())[0]
  console.log('signer and gov address:', signer.address)

  const factoryAddress = await deployVerified('ImpossibleSwapFactory', [signer.address])
  await deployVerified('ImpossibleWrapperFactory', [signer.address])
  await deployVerified('ImpossibleRouterExtension', [factoryAddress])
  await deployVerified('ImpossibleRouter', [factoryAddress])
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error)
    process.exit(1)
  })
