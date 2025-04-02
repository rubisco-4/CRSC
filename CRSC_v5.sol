// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/*******************************************
*              CARS Token Contract         *
********************************************/
contract CARSToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("CARS", "CRS") {
        _mint(msg.sender, initialSupply);
    }

    // 增加approveAndCall方法避免allowance问题
    function approveAndCall(address spender, uint256 amount, bytes memory data) public returns (bool) {
        approve(spender, amount);
        (bool success,) = spender.call(data);
        require(success, "Call failed");
        return true;
    }
}


/*******************************************
*              Crowdsale Contract          *
********************************************/
contract CARSCrowdsale is Ownable {
    using SafeMath for uint256;

    IERC20 public token;
    address payable public wallet;
    uint256 public rate; // 每个 ether 对应的代币数量（单位：代币/ether）
    uint256 public EtherRaisedBalance; // 合约中保留的 ether 数量（单位：ether）

    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 etherValue, uint256 tokenAmount);
    event TokensRedeemed(address indexed redeemer, uint256 tokenAmount, uint256 etherAmountWei);
    event FundsWithdrawn(address indexed wallet, uint256 amountWei);

    constructor(uint256 _rate, address payable _wallet, IERC20 _token) Ownable(msg.sender) {
        require(_rate > 0, "Crowdsale: rate is 0");
        require(_wallet != address(0), "Crowdsale: wallet is the zero address");
        require(address(_token) != address(0), "Crowdsale: token is the zero address");

        rate = _rate;
        wallet = _wallet;
        token = _token;
    }

    // 接收 Ether 购买代币
    receive() external payable {
        buyTokens(msg.sender);
    }

    // 购买代币：msg.value 必须为整数个 ether，单位转换后更新 EtherRaisedBalance
    function buyTokens(address beneficiary) public payable {
        require(msg.value % 1 ether == 0, "Crowdsale: value must be in whole ether amounts");
        uint256 etherAmount = msg.value / 1 ether;
        _preValidatePurchase(beneficiary, etherAmount);

        uint256 tokens = _getTokenAmount(etherAmount);
        EtherRaisedBalance = EtherRaisedBalance.add(etherAmount);

        require(token.balanceOf(address(this)) >= tokens, "Crowdsale: insufficient contract token balance");

        token.transfer(beneficiary, tokens);
        emit TokensPurchased(msg.sender, beneficiary, etherAmount, tokens);
        // Ether 保留在合约中，不立即转移至wallet地址
    }

    // 赎回代币：根据传入的 tokenAmount 计算应兑换的 ether（整数个 ether），转换为 wei 后转账给用户，同时更新 EtherRaisedBalance
    function redeemTokens(uint256 tokenAmount) public {
        address payable redeemer = payable(msg.sender);
        uint256 etherAmount = _getEtherAmount(tokenAmount); // 单位：ether
        uint256 weiAmount = etherAmount * 1 ether;            // 转换为 wei

        require(address(this).balance >= weiAmount, "Crowdsale: insufficient contract balance");
        require(token.allowance(redeemer, address(this)) >= tokenAmount, "Crowdsale: token allowance too low");
        require(token.transferFrom(redeemer, address(this), tokenAmount), "Crowdsale: token transfer failed");

        redeemer.transfer(weiAmount);
        EtherRaisedBalance = EtherRaisedBalance.sub(etherAmount);
        emit TokensRedeemed(redeemer, tokenAmount, weiAmount);
    }

    // 只有合约部署者可以调用，将合约中指定数量（单位：ether）的 Ether 转移到 wallet 地址，并更新 EtherRaisedBalance
    function withdrawFunds(uint256 amount) external onlyOwner {
        require(EtherRaisedBalance >= amount, "Crowdsale: insufficient EtherRaisedBalance");
        uint256 weiAmount = amount * 1 ether;
        require(address(this).balance >= weiAmount, "Crowdsale: insufficient contract balance");
        EtherRaisedBalance = EtherRaisedBalance.sub(amount);
        wallet.transfer(weiAmount);
        emit FundsWithdrawn(wallet, weiAmount);
    }

    // 内部方法：验证购买条件，传入的 etherAmount 单位为 ether
    function _preValidatePurchase(address beneficiary, uint256 etherAmount) internal pure {
        require(beneficiary != address(0), "Crowdsale: beneficiary is the zero address");
        require(etherAmount != 0, "Crowdsale: etherAmount is 0");
    }

    // 根据传入的 ether 数量计算可获得的代币数量
    function _getTokenAmount(uint256 etherAmount) internal view returns (uint256) {
        return etherAmount.mul(rate);
    }

    // 根据传入的代币数量计算可兑换的 ether 数量（单位：ether）
    function _getEtherAmount(uint256 tokenAmount) internal view returns (uint256) {
        return tokenAmount / rate;
    }
}


/*******************************************
*              Car Rental Main Contract    *
********************************************/
contract CarRental is Ownable {
    IERC20 public token;
    
    struct Car {
        uint256 id;
        bool isAvailable;
        uint256 hourlyRate; // 每小时租金（CRS代币）
        bool hasDamage;
    }

    struct Rental {
        address renter;
        uint256 carId;
        uint256 startTime;
        uint256 expectedDuration; // 小时数
        uint256 actualEndTime;
        uint256 totalPaid;
        uint256 deposit;
        bool isReturned;
    }

    mapping(uint256 => Car) public cars;
    mapping(address => Rental) public activeRentals;
    mapping(uint256 => address) public carRenters;

    event CarRented(address indexed renter, uint256 carId, uint256 duration, uint256 totalPaid, uint256 deposit);
    event CarReturned(address indexed renter, uint256 carId, uint256 refundAmount, uint256 penalty);
    event DamageReported(uint256 carId, uint256 damageCost);

    constructor(address _tokenAddress) Ownable(msg.sender) {
        token = IERC20(_tokenAddress);
    }

    modifier onlyAvailableCar(uint256 carId) {
        require(cars[carId].isAvailable, "Car not available");
        _;
    }

    modifier onlyRenter() {
        require(activeRentals[msg.sender].renter == msg.sender, "Not the renter");
        _;
    }

    // 添加车辆（仅公司）
    function addCar(uint256 carId, uint256 hourlyRate) external onlyOwner {
        cars[carId] = Car(carId, true, hourlyRate, false);
    }

    // 租车核心功能
    function rentCar(uint256 carId, uint256 expectedHours) external onlyAvailableCar(carId) {
        
        Car storage car = cars[carId];
        uint256 totalCost = car.hourlyRate * expectedHours;
        uint256 deposit = (totalCost * 30) / 100;

        require(token.transferFrom(msg.sender, address(this), totalCost + deposit), "Payment failed");

        car.isAvailable = false;
        activeRentals[msg.sender] = Rental({
            renter: msg.sender,
            carId: carId,
            startTime: block.timestamp,
            expectedDuration: expectedHours,
            actualEndTime: 0,
            totalPaid: totalCost,
            deposit: deposit,
            isReturned: false
        });
        carRenters[carId] = msg.sender;

        emit CarRented(msg.sender, carId, expectedHours, totalCost, deposit);
    }

    // 还车功能（仅公司）
    function returnCar(address renter, bool hasDamage, uint256 damageCost) external onlyOwner {
        Rental storage rental = activeRentals[renter];
        require(!rental.isReturned, "Already returned");
        
        Car storage car = cars[rental.carId];
        uint256 actualDuration = (block.timestamp - rental.startTime) / 3600;
        uint256 finalCost = 0;
        uint256 penalty = 0;

        // 计算超时费用
        if(actualDuration > rental.expectedDuration) {
            uint256 overtime = actualDuration - rental.expectedDuration;
            penalty = overtime * car.hourlyRate * 2;
        } else {
            // 退还多余费用
            uint256 savedTime = rental.expectedDuration - actualDuration;
            uint256 refund = savedTime * car.hourlyRate;
            token.transfer(renter, refund);
        }

        // 处理损坏
        if(hasDamage) {
            penalty += damageCost;
            car.hasDamage = true;
        }

        // 处理押金
        if(penalty > 0) {
            uint256 deduction = penalty > rental.deposit ? rental.deposit : penalty;
            rental.deposit -= deduction;
            if(deduction < penalty) {
                finalCost = penalty - deduction;
            }
        }

        // 退还剩余押金
        if(rental.deposit > 0) {
            token.transfer(renter, rental.deposit);
        }

        // 收取额外费用
        if(finalCost > 0) {
            token.transferFrom(renter, owner(), finalCost);
        }

        // 重置状态
        car.isAvailable = true;
        rental.isReturned = true;
        delete carRenters[rental.carId];

        emit CarReturned(renter, rental.carId, rental.deposit, penalty);
    }

    // 查询功能
    function getRentalDetails(address renter) public view returns (
        uint256 carId,
        uint256 startTime,
        uint256 expectedDuration,
        uint256 timeRemaining,
        uint256 totalPaid,
        uint256 deposit
    ) {
        Rental storage r = activeRentals[renter];
        uint256 elapsed = block.timestamp - r.startTime;
        uint256 remaining = (r.expectedDuration * 3600 > elapsed) ? 
            (r.expectedDuration * 3600 - elapsed) : 0;
        
        return (
            r.carId,
            r.startTime,
            r.expectedDuration,
            remaining,
            r.totalPaid,
            r.deposit
        );
    }
}

/*******************************************
*              User Interface Contract    *
********************************************/
contract RentalUserInterface is Ownable {
    CarRental public rentalContract;

    constructor(address _rentalAddress) Ownable(msg.sender) {
        rentalContract = CarRental(_rentalAddress);
    }

    // 查询用户租赁信息
    function getMyRentalDetails() external view returns (
        uint256 carId,
        uint256 startTime,
        uint256 expectedDuration,
        uint256 timeRemaining,
        uint256 totalPaid,
        uint256 deposit
    ) {
        return rentalContract.getRentalDetails(msg.sender);
    }

    // 查询车辆基本信息
    function getCarInfo(uint256 carId) external view returns (
        bool isAvailable,
        uint256 hourlyRate,
        bool hasDamage
    ) {
        (, isAvailable, hourlyRate, hasDamage) = rentalContract.cars(carId);
        return (isAvailable, hourlyRate, hasDamage);
    }
}