// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./Fund.sol";

//import "hardhat/console.sol";

/// @title Takaturn Collateral
/// @author Aisha EL Allam
/// @notice This is used to operate the Takaturn fund
/// @dev v1.5 (prebeta 2)
/// @custom:experimental This is still in testing phase.
contract CollateralFactory {
    address payable[] public deployedCollaterals;

    function createCollateral(
        uint totalParticipants,
        uint cycleTime,
        uint contributionAmount,
        uint contributionPeriod,
        uint collateralAmount,
        uint fixedCollateralEth,
        address stableCoinAddress,
        address aggregatorAddress
    ) public returns (address) {
        address newCollateral = address(
            new Collateral(
                totalParticipants,
                cycleTime,
                contributionAmount,
                contributionPeriod,
                collateralAmount,
                fixedCollateralEth,
                address(stableCoinAddress),
                address(aggregatorAddress),
                msg.sender
            )
        );
        deployedCollaterals.push(payable(newCollateral));

        return newCollateral;
    }

    function getDeployedCollaterals()
        public
        view
        returns (address payable[] memory)
    {
        return deployedCollaterals;
    }
}

contract Collateral is Ownable {
    Fund private fundInstance;

    AggregatorV3Interface internal priceFeed;

    uint public version = 1;

    uint public totalParticipants;
    uint public collateralDeposit;
    uint public firstDepositTime;
    uint public cycleTime;
    uint public contributionAmount;
    uint public contributionPeriod;
    uint public counterMembers = 0;
    uint public fixedCollateralEth;

    mapping(address => bool) public isCollateralMember; //Determines if a participant is a valid user
    mapping(address => uint) public collateralMembersBank; //Users main balance
    mapping(address => uint) public collateralPaymentBank; //Users reimbursement balance after someone defaults

    address[] public participants;
    address public fundContract;
    address public stableCoinAddress;

    enum States {
        AcceptingCollateral, //Initial state where collateral are deposited
        CycleOngoing, //Triggered when a fund instance is created, no collateral can be accepted
        ReleasingCollateral, //Triggered when the fund closes
        Closed //Triggers when all participants withdraw their collaterals
    }

    event OnContractDeployed(address indexed newContract);
    event OnFundContractDeployed(
        address indexed fund,
        address indexed collateral
    );
    event OnStateChanged(States indexed oldState, States indexed newState);
    event OnCollateralDeposited(address indexed user);
    event OnCollateralWithdrawn(address indexed user, uint indexed amount);
    event OnCollateralLiquidated(address indexed user, uint indexed amount);

    //Function cannot be called at this time.
    error FunctionInvalidAtThisState();

    //Current state.
    States public state = States.AcceptingCollateral;
    uint public creationTime = block.timestamp;
    modifier atState(States state_) {
        if (state != state_) revert FunctionInvalidAtThisState();
        _;
    }

    function setStateOwner(States state_) public onlyOwner {
        setState(state_);
    }

    function setState(States state_) internal {
        state = state_;
        emit OnStateChanged(state, state_);
    }

    /// @notice Constructor Function
    /// @dev Network is Polygon Testnet and Aggregator is ETH/USD
    /// @param _totalParticipants Max number of participants
    /// @param _cycleTime Time for single cycle (seconds)
    /// @param _contributionAmount Amount user must pay per cycle (USD)
    /// @param _contributionPeriod The portion of cycle user must make payment
    /// @param _collateralAmount Total value of collateral in USD (1.5x of total fund)
    /// @param _creator owner of contract
    constructor(
        uint _totalParticipants,
        uint _cycleTime,
        uint _contributionAmount,
        uint _contributionPeriod,
        uint _collateralAmount,
        uint _fixedCollateralEth,
        address _stableCoinAddress,
        address _aggregatorAddress,
        address _creator
    ) {
        transferOwnership(_creator);

        totalParticipants = _totalParticipants;
        cycleTime = _cycleTime;
        contributionAmount = _contributionAmount;
        contributionPeriod = _contributionPeriod;
        collateralDeposit = _collateralAmount * 10 ** 18; //convert to Wei
        fixedCollateralEth = _fixedCollateralEth;
        stableCoinAddress = _stableCoinAddress;
        priceFeed = AggregatorV3Interface(_aggregatorAddress);

        emit OnContractDeployed(address(this));
    }

    /// @notice Calls the Fund constructor to start he fund
    /// @dev The inputs must be revised / add try catch (see: https://solidity-by-example.org/try-catch/)
    /// @param _participants Max number of participants
    /// @param _cycleTime Duration of a complete cycle in seconds
    /// @param _contributionAmount Value participant must contribute for each cycle
    /// @param _contributionPeriod Duration of funding period in seconds?
    function _createFund(
        address _stableTokenAddress,
        address[] memory _participants,
        uint _cycleTime,
        uint _contributionAmount,
        uint _contributionPeriod
    ) internal {
        fundContract = address(
            new Fund(
                _stableTokenAddress,
                _participants,
                _cycleTime,
                _contributionAmount,
                _contributionPeriod
            )
        );

        if (fundContract != address(0x00)) {
            fundInstance = Fund(address(fundContract));
            setState(States.CycleOngoing);
            emit OnFundContractDeployed(address(fundContract), address(this));
        } else {
            revert();
        }
    }

    /// @notice Called by each member to enter the Fund
    /// @dev needs to call the fund creation function
    function depositCollateral()
        external
        payable
        atState(States.AcceptingCollateral)
    {
        address sender = msg.sender;
        require(counterMembers < totalParticipants, "Members still pending");
        require(isCollateralMember[sender] == false, "No reentry");
        require(msg.value >= fixedCollateralEth, "Eth payment too low");

        collateralMembersBank[sender] += msg.value;
        isCollateralMember[sender] = true;
        participants.push(address(sender));
        counterMembers++;

        emit OnCollateralDeposited(address(sender));

        if (participants.length == 1) {
            firstDepositTime = block.timestamp;
        }
    }

    /// @notice Called by the manager when the cons job goes off
    /// @dev consider making the duration a variable
    function initiateFundContract()
        public
        onlyOwner
        atState(States.AcceptingCollateral)
    {
        require(fundContract == address(0));
        require(counterMembers == totalParticipants);
        //If one user is under collaterized, then all are too.
        require(
            isUnderCollaterized(participants[0]) == false,
            "Cannot start fund: Eth prices dropped"
        );

        _createFund(
            stableCoinAddress,
            participants,
            cycleTime,
            contributionAmount,
            contributionPeriod
        );
    }

    /// @notice Called from Fund contract when someone defaults
    /// @dev Check EnumerableMap (openzeppelin) for arrays that are being accessed from Fund contract
    /// @param beneficiary Address that was randomly selected for the current cycle
    /// @param defaulters Address that was randomly selected for the current cycle
    function requestContribution(
        address beneficiary,
        address[] calldata defaulters
    ) external atState(States.CycleOngoing) returns (address[] memory) {
        require(fundContract == address(msg.sender), "wrong caller");
        require(defaulters.length != 0, "defaulters array is empty!");

        address ben = beneficiary;
        bool wasBeneficiary = false;
        address currentDefaulter;
        address currentParticipant;
        address[] memory nonBeneficiaries = new address[](participants.length);
        address[] memory expellants = new address[](defaulters.length);

        uint totalExpellants = 0;
        uint nonBeneficiaryCounter = 0;
        uint share = 0;
        uint currentDefaulterBank = 0;

        uint contributionAmountWei = uint(
            getToEthConversionRate(int(contributionAmount * 10 ** 18))
        );

        //Determine who will be expelled and who will just pay the contribution
        //from their collateral.
        for (uint i = 0; i < defaulters.length; i++) {
            currentDefaulter = defaulters[i];
            wasBeneficiary = fundInstance.beneficiariesTracker(
                currentDefaulter
            );
            currentDefaulterBank = collateralMembersBank[currentDefaulter];

            if (currentDefaulter == ben) continue; //avoid expelling graced defaulter

            if (
                (wasBeneficiary && isUnderCollaterized(currentDefaulter)) ||
                (currentDefaulterBank < contributionAmountWei)
            ) {
                isCollateralMember[currentDefaulter] = false; //expelled!
                expellants[i] = currentDefaulter;
                share += currentDefaulterBank;
                collateralMembersBank[currentDefaulter] = 0;
                totalExpellants++;

                emit OnCollateralLiquidated(
                    address(currentDefaulter),
                    currentDefaulterBank
                );
            } else {
                //subtract contribution from defaulter and add to beneficiary.
                collateralMembersBank[
                    currentDefaulter
                ] -= contributionAmountWei;
                collateralPaymentBank[ben] += contributionAmountWei;
            }
        }

        totalParticipants = totalParticipants - totalExpellants;

        //Divide and Liquidate
        for (uint i = 0; i < participants.length; i++) {
            currentParticipant = participants[i];
            if (
                !fundInstance.beneficiariesTracker(currentParticipant) &&
                isCollateralMember[currentParticipant]
            ) {
                nonBeneficiaries[nonBeneficiaryCounter] = currentParticipant;
                nonBeneficiaryCounter++;
            }
        }

        //Finally, divide the share equally among non-beneficiaries
        if (nonBeneficiaryCounter > 0) {
            //this case can only happen when what?
            share = share / nonBeneficiaryCounter;
            for (uint i = 0; i < nonBeneficiaryCounter; i++) {
                collateralPaymentBank[nonBeneficiaries[i]] += share;
            }
        }

        return (expellants);
    }

    /// @notice Called by each member after the end of the cycle to withraw collateral
    /// @dev This follows the pull-over-push pattern.
    function withdrawCollateral() external atState(States.ReleasingCollateral) {
        address sender = msg.sender;
        uint total = collateralMembersBank[sender] +
            collateralPaymentBank[sender];
        require(total > 0, "No collateral to claim");

        collateralMembersBank[sender] = 0;
        collateralPaymentBank[sender] = 0;
        payable(sender).transfer(total);

        emit OnCollateralWithdrawn(address(sender), total);

        counterMembers--;
        //if last person withdraws, then change state to EOL
        if (counterMembers == 0) {
            setState(States.Closed);
        }
    }

    function withdrawReimbursement(address participant) external {
        require(address(fundContract) == address(msg.sender), "wrong caller");
        uint amount = collateralPaymentBank[participant];
        require(amount > 0, "No reimbursement to claim");
        collateralPaymentBank[participant] = 0;
        payable(participant).transfer(amount);
    }

    function releaseCollateral() external {
        require(address(fundContract) == address(msg.sender), "wrong caller");
        setState(States.ReleasingCollateral);
    }

    /// @notice Checks if a user has a collateral below 1.0x of total contribution amount
    /// @dev This will revert if called during ReleasingCollateral or after
    /// @param member The user to check for
    /// @return Bool check if member is below 1.0x of collateralDeposit
    function isUnderCollaterized(address member) public view returns (bool) {
        uint collateralLimit;
        int memberCollateralUSD;
        if (fundContract == address(0)) {
            collateralLimit = totalParticipants * contributionAmount * 10 ** 18;
        } else {
            uint remainingCycles = 1 +
                counterMembers -
                fundInstance.currentCycle();
            collateralLimit = remainingCycles * contributionAmount * 10 ** 18; //convert to Wei
        }

        memberCollateralUSD = getToUSDConversionRate(
            int(collateralMembersBank[member])
        );

        return (memberCollateralUSD < int(collateralLimit));
    }

    /// @notice Gets latest ETH / USD price using the Polygon Testnet
    /// @dev Address is 0x0715A7794a1dc8e42615F059dD6e406A6594651A
    /// @return int latest price in Wei
    function getLatestPrice() public view returns (int) {
        (
            ,
            /*uint80 roundID*/ int price /*uint startedAt*/ /*uint timeStamp*/ /*uint80 answeredInRound*/,
            ,
            ,

        ) = priceFeed.latestRoundData(); //8 decimals
        return int(price * 10 ** 10); //18 decimals
    }

    /**
     * usdAmount: Amount in USD to convert to ETH (Wei)
     * Returns converted amount in eth
     */
    function getToEthConversionRate(int USDAmount) public view returns (int) {
        //NOTE: This will be made internal
        int ethPrice = getLatestPrice();
        int USDAmountInEth = (USDAmount * 10 ** 18) / ethPrice; //* 10 ** 18;
        return USDAmountInEth;
    }

    /// @notice Gets the conversion rate of an amount in ETH to USD
    /// @dev should we always deal with in Wei?
    /// @return int converted amount in USD correct to 18 decimals
    function getToUSDConversionRate(int ethAmount) public view returns (int) {
        //NOTE: This will be made internal
        int ethPrice = getLatestPrice();
        int ethAmountInUSD = (ethPrice * ethAmount) / 10 ** 18;
        return ethAmountInUSD;
    }

    /// @notice allow the owner to empty the Collateral after 180 days
    function emptyCollateralAfterEnd()
        external
        onlyOwner
        atState(States.ReleasingCollateral)
    {
        require(
            block.timestamp > (fundInstance.fundEnd()) + 180 days,
            "Can't empty yet"
        );

        payable(msg.sender).transfer(address(this).balance);
    }

    function getCollateralSummary()
        public
        view
        returns (States, uint, uint, uint, uint, uint, uint, uint)
    {
        return (
            state, //current state of Collateral
            cycleTime, //cycle duration
            totalParticipants, //total no. of participants
            collateralDeposit, //collateral
            contributionAmount, //Required contribution per cycle
            contributionPeriod, //time to contribute
            counterMembers, //current member count
            fixedCollateralEth //fixed ether to deposit
        );
    }

    function getParticipantSummary(
        address participant
    ) external view returns (uint, uint, bool) {
        return (
            collateralMembersBank[participant],
            collateralPaymentBank[participant],
            isCollateralMember[participant]
        );
    }
}
