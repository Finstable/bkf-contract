// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./abstracts/Admin.sol";
import "./abstracts/FeeCollector.sol";
import "./abstracts/BKNextCallHelper.sol";
import "./modules/KAP20/interfaces/IKAP20.sol";
import "./modules/committee/Committee.sol";
import "./modules/kyc/KYCHandler.sol";
import "./modules/authorization/Authorization.sol";
import "./modules/transferRouter/TransferRouter.sol";

contract BKF is
  Admin,
  FeeCollector,
  Authorization,
  Committee,
  KYCHandler,
  BKNextCallHelper,
  TransferRouter
{
  uint256 private constant _NEW = 0;
  uint256 private constant _COMPLETED = 1;

  mapping(uint256 => uint256) public orderStatus;
  address public swapRouter;

  event Purchased(
    uint256 orderId,
    address indexed payer,
    address indexed merchant,
    address inputToken,
    address indexed outputToken,
    uint256 amountIn,
    uint256 amountOut,
    uint256 fee
  );
  event SwapRouterChanged(address oldSwapRouter, address newSwapRouter);

  constructor(
    address _swapRouter,
    address _rootAdmin,
    address _feeClaimer,
    address _kyc,
    address _committee,
    address _transferRouter,
    address _callHelper,
    uint256 _acceptedKYCLevel
  ) Admin(_rootAdmin) FeeCollector(_feeClaimer) BKNextCallHelper(_callHelper) {
    swapRouter = _swapRouter;
    committee = _committee;
    _setKYC(_kyc);
    _setAcceptedKYCLevel(_acceptedKYCLevel);
    _setTransferRouter(_transferRouter);
  }

  /*** BK Next helpers ***/
  function requireKYC(address _sender) internal view {
    require(
      kyc.kycsLevel(_sender) >= acceptedKYCLevel,
      "only Bitkub Next user"
    );
  }

  function purchase(
    uint256 orderId,
    address merchant,
    address[] memory routes,
    uint256 amountInMax,
    uint256 amountOut,
    uint256 deadline,
    address sender
  ) public {
    require(orderStatus[orderId] == _NEW, "Order was completed");

    uint256 amountOrder;
    uint256 deductedFee;
    uint256 amountIn = amountInMax;

    address inputToken = routes[0];
    address outputToken = routes[routes.length - 1];

    // Bitkub Next
    if (msg.sender == callHelper) {
      requireKYC(sender);
      if (inputToken == outputToken) {
        transferRouter.transferFrom(
          "BKF",
          inputToken,
          sender,
          address(this),
          amountOut
        );
        (amountOrder, deductedFee) = deductFee(inputToken, amountOut);
      } else {
        (uint256 swapOutput, uint256 swapInput) = swapTokensForExactTokens(
          routes,
          amountOut,
          amountInMax,
          address(this),
          deadline,
          sender
        );
        (amountOrder, deductedFee) = deductFee(outputToken, swapOutput);
        amountIn = swapInput;
      }
    } else {
      // Metamask
      require(msg.sender == sender, "Invalid sender");
      if (inputToken == outputToken) {
        IKAP20(inputToken).transferFrom(sender, address(this), amountOut);
        (amountOrder, deductedFee) = deductFee(inputToken, amountOut);
      } else {
        (uint256 swapOutput, uint256 swapInput) = swapTokensForExactTokens(
          routes,
          amountOut,
          amountInMax,
          address(this),
          deadline,
          sender
        );

        (amountOrder, deductedFee) = deductFee(outputToken, swapOutput);
        amountIn = swapInput;
      }
    }

    IKAP20(outputToken).transfer(merchant, amountOrder);

    orderStatus[orderId] = _COMPLETED;

    emit Purchased(
      orderId,
      sender,
      merchant,
      inputToken,
      outputToken,
      amountIn,
      amountOrder,
      deductedFee
    );
  }

  function swapTokensForExactTokens(
    address[] memory _routes,
    uint256 _amountOut,
    uint256 _amountInMax,
    address _to,
    uint256 _deadline,
    address _sender
  ) private returns (uint256, uint256) {
    address _tokenIn = _routes[0];

    // Bitkub Next
    if (msg.sender == callHelper) {
      transferRouter.transferFrom(
        "BKF",
        _tokenIn,
        _sender,
        address(this),
        _amountInMax
      );
    } else {
      IKAP20(_tokenIn).transferFrom(_sender, address(this), _amountInMax);
    }

    IKAP20(_tokenIn).approve(swapRouter, _amountInMax);

    // Receive an exact amount of output tokens for as few input tokens as possible
    uint256[] memory amounts = IUniswapV2Router02(swapRouter)
      .swapTokensForExactTokens(
        _amountOut,
        _amountInMax,
        _routes,
        _to,
        _deadline
      );

    // send change token back to sender
    IKAP20(_tokenIn).transfer(_sender, _amountInMax - amounts[0]);

    return (amounts[amounts.length - 1], amounts[0]);
  }

  function setFee(uint256 newFee) external onlyRootAdmin {
    _setFee(newFee);
  }

  function setFeeClaimer(address newFeeClaimer) external onlyRootAdmin {
    _setFeeClaimer(newFeeClaimer);
  }

  function setSwapRouter(address newSwapRouter) external onlyRootAdmin {
    address oldSwapRouter = swapRouter;
    swapRouter = newSwapRouter;
    emit SwapRouterChanged(oldSwapRouter, newSwapRouter);
  }

  function setKYC(address _kyc) external onlyCommittee {
    _setKYC(_kyc);
  }

  function setAcceptedKYCLevel(uint256 _acceptedKYCLevel)
    external
    onlyCommittee
  {
    _setAcceptedKYCLevel(_acceptedKYCLevel);
  }

  function setTransferRouter(address _transferRouter) external onlyCommittee {
    _setTransferRouter(_transferRouter);
  }
}
