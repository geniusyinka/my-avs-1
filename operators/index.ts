import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { delegationABI } from "./abis/delegationABI";
import { contractABI } from './abis/contractABI';
import { registryABI } from './abis/registryABI';
import { avsDirectoryABI } from './abis/avsDirectoryABI';

dotenv.config();

const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

const delegationManagerAddress = process.env.DELEGATION_MANAGER_ADDRESS!;
const contractAddress = process.env.CONTRACT_ADDRESS!;
const stakeRegistryAddress = process.env.STAKE_REGISTRY_ADDRESS!;
const avsDirectoryAddress = process.env.AVS_DIRECTORY_ADDRESS!;

const delegationManager = new ethers.Contract(delegationManagerAddress, delegationABI, wallet);
const contract = new ethers.Contract(contractAddress, contractABI, wallet);
const registryContract = new ethers.Contract(stakeRegistryAddress, registryABI, wallet);
const avsDirectory = new ethers.Contract(avsDirectoryAddress, avsDirectoryABI, wallet);


const registerOperator = async () => {
    const tx1 = await delegationManager.registerAsOperator({
        earningsReceiver: await wallet.address,
        delegationApprover: "0x0000000000000000000000000000000000000000",
        stakerOptOutWindowBlocks: 0
    }, "");
    await tx1.wait();
    console.log("Operator registered on EL successfully");
    console.log('error...')

    const salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const expiry = Math.floor(Date.now() / 1000) + 3600; // Example expiry, 1 hour from now
    console.log('error...2')


    // Define the output structure
    let operatorSignature = {
        expiry: expiry,
        salt: salt,
        signature: ""
    };
    console.log('error...3')


    // Calculate the digest hash using the avsDirectory's method
    const digestHash = await avsDirectory.calculateOperatorAVSRegistrationDigestHash(
        wallet.address, 
        contract.address, 
        salt, 
        expiry
    );
    console.log('error...4')


    // Sign the digest hash with the operator's private key
    const signingKey = new ethers.utils.SigningKey(process.env.PRIVATE_KEY!);
    console.log('error...5', signingKey)

    const signature = signingKey.signDigest(digestHash);
    console.log('error...6')

    
    // Encode the signature in the required format
    operatorSignature.signature = ethers.utils.joinSignature(signature);
    console.log('error...7', operatorSignature)
    const block = await provider.getBlock("latest");
    const currentBlockGasLimit = block.gasLimit;

    // Set a gas limit that is within the block gas limit
    const safeGasLimit = currentBlockGasLimit.sub(ethers.BigNumber.from("100000"));


    // const tx2 = await registryContract.registerOperatorWithSignature(
    //     wallet.address,
    //     operatorSignature
    // );
    // Simulate the transaction to catch any errors
    try {
        await registryContract.callStatic.registerOperatorWithSignature(
            wallet.address,
            operatorSignature
        );
    } catch (error) {
        console.error("Simulation error:", error);
        throw error; // Rethrow to handle it in the outer catch block
    }

    // Send the transaction with a manual gas limit
    const tx2 = await registryContract.registerOperatorWithSignature(
        wallet.address,
        operatorSignature,

        // Set a manual gas limit (adjust if necessary)
    );
    console.log('error...8')


    await tx2.wait();
    console.log("Operator registered on AVS successfully");
};

const monitorNewTasks = async () => {
    await contract.createNewTask("EigenWorld");
    // contract.on("NewTaskCreated", async (taskIndex: number, task: any) => {
    //     console.log(`New task detected: Hello, ${task.name}`);
    //     await signAndRespondToTask(taskIndex, task.taskCreatedBlock, task.name);
    // });

    console.log("Monitoring for new tasks...");
};

const main = async () => {
    await registerOperator();
};

main().catch((error) => {
    console.error("Error in main:", error);
});
