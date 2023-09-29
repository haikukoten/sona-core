// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.16;

import "forge-std/Script.sol";
import { SonaRewards } from "../../contracts/SonaRewards.sol";
import { SonaDirectMint } from "../../contracts/SonaDirectMint.sol";
import { SonaRewardToken } from "../../contracts/SonaRewardToken.sol";
import { SonaReserveAuction } from "../../contracts/SonaReserveAuction.sol";
import { ERC1967Proxy } from "openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "openzeppelin/token/ERC20/ERC20.sol";
import { IERC20Upgradeable as IERC20 } from "openzeppelin-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IWETH } from "../../contracts/interfaces/IWETH.sol";
import { Weth9Mock } from "../../contracts/test/mock/Weth9Mock.sol";
import { ISonaSwap } from "../../lib/common/ISonaSwap.sol";
import { SplitMain } from "../../contracts/payout/SplitMain.sol";
import { SonaDirectMint } from "../../contracts/SonaDirectMint.sol";

contract Deployer is Script {
	function run() external {
		string memory mnemonic = vm.envString("MNEMONIC");
		(address deployer, uint256 pk) = deriveRememberKey(mnemonic, 0);

		address rewardToken = deployRewardToken(mnemonic);

		// Deploy Mocks for PoC Tests
		IERC20 usdc;
		IWETH weth;
		if (block.chainid != 1) {
			vm.startBroadcast(pk);
			usdc = IERC20(address(new ERC20Mock()));
			weth = new Weth9Mock();
			vm.stopBroadcast();
		} else {
			weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
			usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
		}

		SplitMain splits = deploySplitMain(mnemonic, weth, usdc);

		address directMint = deployDirectMint(mnemonic, rewardToken);

		address reserveAuction = deployReserveAuction(
			mnemonic,
			rewardToken,
			splits,
			address(weth)
		);

		address rewards = deployRewards(
			mnemonic,
			rewardToken,
			address(usdc),
			"",
			splits
		);

		address _SONA_OWNER = vm.addr(vm.deriveKey(mnemonic, 1));
		bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
		bytes32 ADMIN_ROLE = keccak256("ADMIN_ROLE");

		console.log("mock weth:", address(weth));
		console.log("mock USDC: ", address(usdc));
		console.log("reward token: ", rewardToken);
		console.log("direct mint: ", directMint);
		console.log("reserve auction: ", reserveAuction);
		console.log("rewards: ", rewards);
		exportAddresses(reserveAuction, rewardToken, directMint, rewards);
		vm.startBroadcast(pk);
		SonaRewardToken(rewardToken).grantRole(MINTER_ROLE, directMint);
		SonaRewardToken(rewardToken).grantRole(MINTER_ROLE, reserveAuction);
		SonaRewardToken(rewardToken).grantRole(ADMIN_ROLE, _SONA_OWNER);
		SonaRewardToken(rewardToken).renounceRole(ADMIN_ROLE, deployer);
		vm.stopBroadcast();
	}

	function deploySplitMain(
		string memory mnemonic,
		IWETH weth,
		IERC20 usdc
	) internal returns (SplitMain splits) {
		ISonaSwap swap = ISonaSwap(vm.envAddress("SONA_SWAP"));
		uint256 pk = vm.deriveKey(mnemonic, 0);
		vm.broadcast(pk);
		return new SplitMain(weth, usdc, swap);
	}

	function deployRewards(
		string memory mnemonic,
		address rewardToken,
		address payoutToken,
		string memory claimUrl,
		SplitMain splitMain
	) internal returns (address rewards) {
		uint256 pk = vm.deriveKey(mnemonic, 0);
		vm.broadcast(pk);
		SonaRewards rewardsBase = new SonaRewards();

		address _SONA_OWNER = vm.addr(vm.deriveKey(mnemonic, 1));
		address _REDISTRIBUTION_RECIPIENT = vm.addr(vm.deriveKey(mnemonic, 3));

		vm.broadcast(pk);
		ERC1967Proxy rewardsProxy = new ERC1967Proxy(
			address(rewardsBase),
			abi.encodeWithSelector(
				SonaRewards.initialize.selector,
				_SONA_OWNER,
				address(rewardToken),
				payoutToken,
				address(0),
				_REDISTRIBUTION_RECIPIENT, //todo: holder of protocol fees(?)
				claimUrl,
				splitMain
			)
		);

		return address(rewardsProxy);
	}

	function deployRewardToken(
		string memory mnemonic
	) internal returns (address rewardTokenAddress) {
		bytes memory initCode = type(SonaRewardToken).creationCode;
		address tokenBase = getCreate2Address(initCode, "");
		console.log("token base: ", tokenBase);

		deploy2(initCode, "", vm.deriveKey(mnemonic, 0));
		if (tokenBase.code.length == 0) revert("token base Deployment failed");

		address _TEMP_SONA_OWNER = vm.addr(vm.deriveKey(mnemonic, 0));
		address _TREASURY_RECIPIENT = vm.addr(vm.deriveKey(mnemonic, 3));
		bytes memory rewardTokenInitializerArgs = abi.encodeWithSelector(
			SonaRewardToken.initialize.selector,
			"Sona Rewards Token",
			"SONA",
			_TEMP_SONA_OWNER,
			_TREASURY_RECIPIENT
		);

		initCode = type(ERC1967Proxy).creationCode;
		rewardTokenAddress = getCreate2Address(
			initCode,
			abi.encode(tokenBase, rewardTokenInitializerArgs)
		);

		deploy2(
			initCode,
			abi.encode(tokenBase, rewardTokenInitializerArgs),
			vm.deriveKey(mnemonic, 0)
		);
		if (rewardTokenAddress.code.length == 0)
			revert("reward token Deployment failed");
	}

	function deployDirectMint(
		string memory mnemonic,
		address rewardToken
	) internal returns (address directMintAddress) {
		address _AUTHORIZER = vm.addr(vm.deriveKey(mnemonic, 2));

		uint256 pk = vm.deriveKey(mnemonic, 0);
		vm.broadcast(pk);
		SonaDirectMint directMint = new SonaDirectMint(
			SonaRewardToken(rewardToken),
			_AUTHORIZER
		);

		return address(directMint);
	}

	function deployReserveAuction(
		string memory mnemonic,
		address rewardToken,
		SplitMain splits,
		address weth
	) internal returns (address reserveAuctionAddress) {
		address _AUTHORIZER = vm.addr(vm.deriveKey(mnemonic, 2));
		address _TREASURY_RECIPIENT = vm.addr(vm.deriveKey(mnemonic, 3));
		address _REDISTRIBUTION_RECIPIENT = vm.addr(vm.deriveKey(mnemonic, 3));

		uint256 pk = vm.deriveKey(mnemonic, 0);
		vm.broadcast(pk);
		SonaReserveAuction auctionBase = new SonaReserveAuction();

		address _SONA_OWNER = vm.addr(vm.deriveKey(mnemonic, 1));

		bytes memory reserveAuctionInitializerArgs = abi.encodeWithSelector(
			SonaReserveAuction.initialize.selector,
			_TREASURY_RECIPIENT,
			_REDISTRIBUTION_RECIPIENT,
			_AUTHORIZER,
			SonaRewardToken(rewardToken),
			splits,
			_SONA_OWNER,
			weth
		);

		vm.startBroadcast(pk);
		reserveAuctionAddress = address(
			new ERC1967Proxy(address(auctionBase), reserveAuctionInitializerArgs)
		);
		vm.stopBroadcast();
	}

	function getCreate2Address(
		bytes memory creationCode,
		bytes memory args
	) internal view returns (address) {
		bytes32 salt = keccak256(bytes(vm.envString("SONA_DEPLOYMENT_SALT")));
		bytes32 codeHash = hashInitCode(creationCode, args);
		return computeCreate2Address(salt, codeHash);
	}

	function deploy2(
		bytes memory deployCode,
		bytes memory args,
		uint256 pk
	) internal {
		bytes32 salt = keccak256(bytes(vm.envString("SONA_DEPLOYMENT_SALT")));
		bytes memory payload = abi.encodePacked(salt, deployCode, args);
		vm.broadcast(pk);
		(bool success, ) = CREATE2_FACTORY.call(payload);
		if (!success) revert("create2 failed");
	}

	function exportAddresses(
		address reserveAuction,
		address rewardToken,
		address directMint,
		address rewards
	) internal {
		string memory deployments = "deployments";
		vm.serializeAddress(deployments, "SonaReserveAuction", reserveAuction);
		vm.serializeAddress(deployments, "SonaRewardToken", rewardToken);
		vm.serializeAddress(deployments, "SonaDirectMint", directMint);
		string memory addresses = vm.serializeAddress(
			deployments,
			"SonaRewards",
			rewards
		);
		string memory result = vm.serializeString(
			"network",
			vm.toString(block.chainid),
			addresses
		);
		vm.writeJson(
			result,
			string(
				abi.encodePacked(
					vm.projectRoot(),
					"/deploys/",
					vm.toString(block.chainid),
					".json"
				)
			)
		);
	}
}

contract ERC20Mock is ERC20 {
	constructor() ERC20("USD Coin", "USDC") {}

	function mint(address account, uint256 amount) external {
		_mint(account, amount);
	}

	function burn(address account, uint256 amount) external {
		_burn(account, amount);
	}
}
