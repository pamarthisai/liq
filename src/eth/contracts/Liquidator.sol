//SPDX-License-Identifier: Unlicense
pragma solidity >=0.6.0 <0.7.0;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";
import { FlashLoanReceiverBase } from "./FlashLoanReceiverBase.sol";
import { IUniswapV2Router02 } from "../interfaces/IUniswapV2Router02.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
  ILendingPoolAddressesProvider
} from "../interfaces/ILendingPoolAddressesProvider.sol";

contract Liquidator is Ownable, FlashLoanReceiverBase {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  IUniswapV2Router02 public uniswapRouter;
  address public UNISWAP_ROUTER_ADDRESS =
    0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

  address private PROFIT_RECIPIENT = 0x3A1733DE64fdE944c40421876865cD5a7cbE1418;

  constructor(ILendingPoolAddressesProvider _addressProvider)
    public
    FlashLoanReceiverBase(_addressProvider)
  {
    uniswapRouter = IUniswapV2Router02(UNISWAP_ROUTER_ADDRESS);
  }

  function changeProfitRecipient(address recipient) public onlyOwner {
    PROFIT_RECIPIENT = recipient;
  }

  function getProfitRecipient() public view returns (address) {
    return PROFIT_RECIPIENT;
  }

  struct TradeInfo {
    uint256 debtAssetInitialBalance;
    uint256 collateralBalanceAfterLiquidation;
    uint256 debtAssetAfterLiquidation;
    uint256 debtAmountNeedinSwap;
  }

  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external override returns (bool) {
    //
    // This contract now has the funds requested.
    // Your logic goes here.
    //

    TradeInfo memory tradeInfo;

    //decoding final params
    (address collateralAddress, address liquidableUser) =
      abi.decode(params, (address, address));

    tradeInfo.debtAssetInitialBalance = IERC20(assets[0]).balanceOf(
      address(this)
    );

    //approving funds to be withdraw by Aave to pay the user debt
    require(
      IERC20(assets[0]).approve(address(LENDING_POOL), amounts[0]),
      "Approval error"
    );

    //making the liquidation call
    LENDING_POOL.liquidationCall(
      collateralAddress,
      assets[0],
      liquidableUser,
      uint256(-1),
      false
    );

    // checking collateral and debt token balance after liquidation
    tradeInfo.debtAssetAfterLiquidation = IERC20(assets[0]).balanceOf(
      address(this)
    );

    tradeInfo.collateralBalanceAfterLiquidation = IERC20(collateralAddress)
      .balanceOf(address(this));

    //swaping collateral for debt to pay the flashLoan
    address[] memory path = new address[](2);
    path[0] = collateralAddress;
    path[1] = assets[0];

    require(
      tradeInfo.collateralBalanceAfterLiquidation > uint256(0),
      "There is no collateral balance"
    );

    // aproving funds to be pulled by Uni + swaping collateral by debt asset
    require(
      IERC20(collateralAddress).approve(
        address(UNISWAP_ROUTER_ADDRESS),
        tradeInfo.collateralBalanceAfterLiquidation
      ),
      "Approval error"
    );

    tradeInfo.debtAmountNeedinSwap = uint256(0)
      .add(tradeInfo.debtAssetInitialBalance)
      .sub(tradeInfo.debtAssetAfterLiquidation)
      .add(premiums[0]);

    uniswapRouter.swapTokensForExactTokens(
      tradeInfo.debtAmountNeedinSwap,
      tradeInfo.collateralBalanceAfterLiquidation,
      path,
      address(this),
      block.timestamp + 5
    );

    // At the end of your logic above, this contract owes
    // the flashloaned amounts + premiums.
    // Therefore ensure your contract has enough to repay
    // these amounts.

    // Approve the LendingPool contract allowance to *pull* the owed amount
    for (uint256 i = 0; i < assets.length; i++) {
      uint256 amountOwing = amounts[i].add(premiums[i]);
      IERC20(assets[i]).approve(address(LENDING_POOL), amountOwing);
    }

    return true;
  }

  function callFlashLoan(
    address debtAsset,
    address collateralAddress,
    address liquidableUser,
    uint256 loanAmount
  ) public onlyOwner {
    address receiverAddress = address(this);

    address[] memory assets = new address[](1);
    assets[0] = address(debtAsset);

    uint256[] memory amounts = new uint256[](1);
    amounts[0] = loanAmount;

    uint256[] memory modes = new uint256[](1);
    modes[0] = 0;

    address onBehalfOf = address(this);
    bytes memory params =
      abi.encode(address(collateralAddress), address(liquidableUser));
    uint16 referralCode = 0;

    LENDING_POOL.flashLoan(
      receiverAddress,
      assets,
      amounts,
      modes,
      onBehalfOf,
      params,
      referralCode
    );

    uint256 finalCollateralAssetValue =
      IERC20(address(collateralAddress)).balanceOf(address(this));

    require(finalCollateralAssetValue > 0, "No balance to transfer");

    address profitRecipient = getProfitRecipient();

    require(
      IERC20(address(collateralAddress)).transfer(
        profitRecipient,
        finalCollateralAssetValue
      ),
      "Tranfer didn't go through"
    );
  }
}
