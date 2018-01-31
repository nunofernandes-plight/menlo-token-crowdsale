pragma solidity ^0.4.18;

import 'zeppelin-solidity/contracts/ownership/Ownable.sol';
import 'zeppelin-solidity/contracts/math/SafeMath.sol';
import 'zeppelin-solidity/contracts/token/ERC20Basic.sol';
import './MET.sol';

/**
 * @title MenloTokenSale
 * @dev Modified from OpenZeppelin's Crowdsale.sol
 * CappedCrowdsale.sol, and FinalizableCrowdsale.sol
 * Uses PausableToken rather than MintableToken.
 *
 * Requires that tokens for sale (entire supply minus team's portion) be deposited.
 */
contract MenloTokenSale is Ownable {
  using SafeMath for uint256;

  // Token allocations
  mapping (address => uint256) public allocations;

  // Whitelisted investors
  mapping (address => bool) public whitelist;

  // manual early close flag
  bool public isFinalized = false;

  // cap for crowdsale in wei
  uint256 public cap;

  // The token being sold
  MET public token;

  // start and end timestamps where contributions are allowed (both inclusive)
  uint256 public startTime;
  uint256 public endTime;

  // address where funds are collected
  address public wallet;

  // amount of raised money in wei
  uint256 public weiRaised;

  // Timestamps for the bonus days, set in the constructor
  uint256 private HOUR1;
  uint256 private WEEK1;
  uint256 private WEEK2;
  uint256 private WEEK3;
  uint256 private WEEK4;

  /**
   * event for token purchase logging
   * @param purchaser who paid for the tokens
   * @param beneficiary who got the tokens
   * @param value weis paid for purchase
   * @param amount amount of tokens purchased
   */
  event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

  /**
   * event for token redemption logging
   * @param beneficiary who got the tokens
   * @param amount amount of tokens redeemed
   */
  event TokenRedeem(address indexed beneficiary, uint256 amount);

  // termination early or otherwise
  event Finalized();

  /**
   * event refund of excess ETH if purchase is above the cap
   * @param amount amount of ETH (in wei) refunded
   */
  event Refund(address indexed purchaser, address indexed beneficiary, uint256 amount);

  function MenloTokenSale(
      address _token,
      uint256 _startTime,
      uint256 _endTime,
      uint256 _cap,
      address _wallet
  ) public {
    require(_startTime >= getBlockTimestamp());
    require(_endTime >= _startTime);
    require(_cap > 0);
    require(_cap <= MET(_token).PUBLICSALE_SUPPLY());
    require(_wallet != 0x0);
    require(_token != 0x0);

    token = MET(_token);
    startTime = _startTime;
    endTime = _endTime;
    cap = _cap;
    wallet = _wallet;
    HOUR1 = startTime + 1 hours;
    WEEK1 = HOUR1 + 1 weeks;
    WEEK2 = WEEK1 + 1 weeks;
    WEEK3 = WEEK2 + 1 weeks;
    WEEK4 = WEEK3 + 1 weeks;
  }

  // fallback function can be used to buy tokens
  function () public payable {
    buyTokens(msg.sender);
  }

  // Hour 1: 1 ETH = 6,500 MET (30% Bonus)
  // Week 1: 1 ETH = 6,000 MET (20% Bonus)
  // Week 2: 1 ETH = 5,750 MET (15% Bonus)
  // Week 3: 1 ETH = 5,500 MET (10% Bonus)
  // Week 4: 1 ETH = 5,250 MET (5% Bonus)
  function calculateBonusRate() public view returns (uint256) {
    uint256 bonusRate = 5000;

    uint256 currentTime = getBlockTimestamp();
    if (currentTime > startTime && currentTime <= HOUR1) {
      bonusRate =  6500;
    } else if (currentTime <= WEEK1) {
      bonusRate =  6000;
    } else if (currentTime <= WEEK2) {
      bonusRate =  5750;
    } else if (currentTime <= WEEK3) {
      bonusRate =  5500;
    } else if (currentTime <= WEEK4) {
      bonusRate =  5250;
    }
    return bonusRate;
  }

  /// @notice interface for founders to whitelist investors
  /// @param _addresses array of investors
  /// @param _status enable or disable
  function whitelistAddresses(address[] _addresses, bool _status) public onlyOwner {
    for (uint256 i = 0; i < _addresses.length; i++) {
        address investorAddress = _addresses[i];
        if (whitelist[investorAddress] == _status) {
          continue;
        }
        whitelist[investorAddress] = _status;
    }
   }

   function ethToTokens(uint256 ethAmount) internal view returns (uint256) {
    return ethAmount.mul(calculateBonusRate());
   }

  // low level token purchase function
  // caution: tokens must be redeemed by beneficiary address
  function buyTokens(address beneficiary) public payable {
    require(whitelist[beneficiary]);
    require(beneficiary != 0x0);
    require(validPurchase());

    uint256 weiAmount = msg.value;

    uint256 remainingToFund = cap.sub(weiRaised);
    if (weiAmount > remainingToFund) {
      weiAmount = remainingToFund;
    }
    uint256 weiToReturn = msg.value.sub(weiAmount);
    uint256 tokens = ethToTokens(weiAmount);

    token.unpause();
    weiRaised = weiRaised.add(weiAmount);

    forwardFunds(weiAmount);
    if (weiToReturn > 0) {
      msg.sender.transfer(weiToReturn);
      Refund(msg.sender, beneficiary, weiToReturn);
    }
    // send tokens to purchaser
    TokenPurchase(msg.sender, beneficiary, weiAmount, tokens);
    token.transfer(beneficiary, tokens);
    token.pause();
    TokenRedeem(beneficiary, tokens);
    if (weiRaised == cap) {
      checkFinalize();
    }
  }

  // send ether to the fund collection wallet
  // override to create custom fund forwarding mechanisms
  function forwardFunds(uint256 amount) internal {
    wallet.transfer(amount);
  }

  function checkFinalize() public {
    if (hasEnded()) {
      finalize();
    }
  }

  // @return true if the transaction can buy tokens
  function validPurchase() internal returns (bool) {
    checkFinalize();
    require(!isFinalized);
    bool withinPeriod = getBlockTimestamp() >= startTime && getBlockTimestamp() <= endTime;
    bool nonZeroPurchase = msg.value != 0;
    bool contractHasTokens = token.balanceOf(this) > 0;
    return withinPeriod && nonZeroPurchase && contractHasTokens;
  }

  // @return true if crowdsale event has ended or cap reached
  function hasEnded() public constant returns (bool) {
    if (isFinalized) {
      return true;
    }
    bool capReached = weiRaised >= cap;
    bool passedEndTime = getBlockTimestamp() > endTime;
    return passedEndTime || capReached;
  }

  function getBlockTimestamp() internal view returns (uint256) {
    return block.timestamp;
  }

  function emergencyFinalize() public onlyOwner {
    finalize();
  }
  // @dev does not require that crowdsale `hasEnded()` to leave safegaurd
  // in place if ETH rises in price too much during crowdsale.
  // Allows team to close early if cap is exceeded in USD in this event.
  function finalize() internal {
    require(!isFinalized);
    Finalized();
    isFinalized = true;
    token.transferOwnership(owner);
  }

  // Allows the owner to take back the tokens that are assigned to the sale contract.
  event TokensRefund(uint256 _amount);
  function refund() external onlyOwner returns (bool) {
      require(hasEnded());
      uint256 tokens = token.balanceOf(address(this));

      if (tokens == 0) {
         return false;
      }

      require(token.transfer(owner, tokens));

      TokensRefund(tokens);

      return true;
   }

  function claimTokens(address _token) public onlyOwner {
    require(hasEnded());
    if (_token == 0x0) {
        owner.transfer(this.balance);
        return;
    }

    ERC20Basic refundToken = ERC20Basic(_token);
    uint256 balance = refundToken.balanceOf(this);
    refundToken.transfer(owner, balance);
    TokensRefund(balance);
  }
}
