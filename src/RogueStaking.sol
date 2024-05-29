// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract RogueStaking is ReentrancyGuard, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant MIN_DOLLAR_VALUE = 100; // $0.01 (adjust decimals as necessary)
    uint8 public constant MAX_APY = 100; // Example max APY, adjust as necessary

    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable rewardToken;
    address public daoWallet;
    address public penaltyWallet;
    uint8 public daoSplit = 80; // 80% to DAO

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lockupPeriod;
        uint256 apy;
        uint256 endTime;
    }

    struct LeaderboardEntry {
        address user;
        uint256 combinedBalance;
    }

    struct StakingOption {
        uint256 apy;
        uint256 lockupPeriod;
        uint256 penalty;
    }

    mapping(address => StakeInfo[]) public stakes;
    mapping(address => uint256) public rewards;
    mapping(address => LeaderboardEntry) public leaderboard;
    EnumerableSet.AddressSet private users;
    LeaderboardEntry[] public topStakers;

    StakingOption[] public stakingOptions;

    event Withdraw(address indexed user, uint256 amount);
    event Stake(address indexed user, uint256 amount, uint256 lockupPeriod, uint256 apy);
    event PenaltyPaid(address indexed user, uint256 penaltyAmount, address penaltyWallet);
    event DaoWalletUpdated(address indexed oldDaoWallet, address indexed newDaoWallet);
    event PenaltyWalletUpdated(address indexed oldPenaltyWallet, address indexed newPenaltyWallet);
    event DaoSplitUpdated(uint8 oldDaoSplit, uint8 newDaoSplit);
    event StakingOptionAdded(uint256 apy, uint256 lockupPeriod, uint256 penalty);
    event StakingOptionUpdated(uint256 index, uint256 apy, uint256 lockupPeriod, uint256 penalty);

    event NFTListed(
        uint256 indexed nftId,
        address indexed seller,
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 royalty
    );
    event NFTBought(
        uint256 indexed nftId,
        address indexed buyer,
        address nftContract,
        uint256 tokenId,
        uint256 price,
        uint256 royalty
    );

    constructor(
        address initialOwner,
        address _rewardToken,
        address _priceFeed,
        address _daoWallet,
        address _penaltyWallet
    ) Ownable(initialOwner) {
        stakingToken = IERC20(_rewardToken);
        priceFeed = AggregatorV3Interface(_priceFeed);
        daoWallet = _daoWallet;
        penaltyWallet = _penaltyWallet;

        // Initialize staking options based on the provided table
        stakingOptions.push(StakingOption(10, 5 days, 1));
        stakingOptions.push(StakingOption(20, 10 days, 2));
        stakingOptions.push(StakingOption(30, 20 days, 3));
        stakingOptions.push(StakingOption(50, 30 days, 5));
    }

    function getLatestPrice() public view returns (int256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price feed data");
        return price;
    }

    function withdraw(uint256 stakeIndex, uint256 amount) public nonReentrant {
        require(stakeIndex > 0 && stakeIndex <= stakes[msg.sender].length, "Invalid stake index");
        StakeInfo storage stakeInfo = stakes[msg.sender][stakeIndex - 1];

        uint256 withdrawableAmount = _withdrawableAmount(stakeIndex);
        require(withdrawableAmount >= stakeInfo.amount, "Insufficient withdrawable amount");
        uint256 userBalance = stakeInfo.amount;

        uint256 remainingBalance = userBalance - amount;

        int256 price = getLatestPrice();
        uint256 valueInDollars = (remainingBalance * uint256(price)) / (10 ** priceFeed.decimals());

        if (valueInDollars < MIN_DOLLAR_VALUE && block.timestamp < stakeInfo.endTime) {
            require(remainingBalance == 0, "Cannot withdraw below minimum dollar value during lockup period");
            amount = userBalance; // Withdraw the entire balance
        }

        uint256 penaltyAmount = 0;
        if (block.timestamp < stakeInfo.endTime) {
            penaltyAmount = (amount * getPenaltyRate(stakeInfo.lockupPeriod)) / 100;
            uint256 daoAmount = (penaltyAmount * daoSplit) / 100;
            uint256 penaltyWalletAmount = penaltyAmount - daoAmount;
            (bool sentDao,) = daoWallet.call{value: daoAmount}("");
            require(sentDao, "Failed to send Ether to DAO wallet");
            (bool sentPenalty,) = penaltyWallet.call{value: penaltyWalletAmount}("");
            require(sentPenalty, "Failed to send Ether to penalty wallet");
            emit PenaltyPaid(msg.sender, penaltyAmount, penaltyWallet);
        }
        stakeInfo.amount -= amount;

        // Transfer calculated reward in reward tokens to user
        uint256 reward = calculateReward(stakeInfo.apy, stakeInfo.amount, stakeInfo.lockupPeriod / 1 days);
        if (reward > 0) {
            rewardToken.transfer(msg.sender, reward);
        }
        (bool success,) = msg.sender.call{value: amount - penaltyAmount}("");
        require(success, "Failed to send Ether to user");
        // stakingToken.safeTransfer(msg.sender, amount - penaltyAmount);
        updateLeaderboard(msg.sender);

        emit Withdraw(msg.sender, amount - penaltyAmount);
    }

    function updateLeaderboard(address user) internal {
        uint256 walletBalance = address(user).balance;
        uint256 stakedAmount = getTotalStakedAmount(user);
        uint256 combinedBalance = walletBalance + stakedAmount;

        leaderboard[user] = LeaderboardEntry({user: user, combinedBalance: combinedBalance});

        if (!users.contains(user)) {
            users.add(user);
        }

        updateRankings();
    }

    function updateRankings() private {
        LeaderboardEntry[] memory entries = new LeaderboardEntry[](users.length());

        for (uint256 i = 0; i < users.length(); i++) {
            entries[i] = leaderboard[users.at(i)];
        }

        // Using a more efficient sorting algorithm
        quickSort(entries, 0, entries.length - 1);

        delete topStakers;

        for (uint256 i = 0; i < entries.length && i < 20; i++) {
            topStakers.push(entries[i]);
        }
    }

    function quickSort(LeaderboardEntry[] memory arr, uint256 left, uint256 right) private pure {
        uint256 i = left;
        uint256 j = right;
        if (i == j) return;
        LeaderboardEntry memory pivot = arr[left + (right - left) / 2];
        while (i <= j) {
            while (arr[i].combinedBalance > pivot.combinedBalance) i++;
            while (pivot.combinedBalance > arr[j].combinedBalance) j--;
            if (i <= j) {
                (arr[i], arr[j]) = (arr[j], arr[i]);
                i++;
                j--;
            }
        }
        if (left < j) quickSort(arr, left, j);
        if (i < right) quickSort(arr, i, right);
    }

    function stake(uint256 amount, uint256 stakingOptionIndex) public payable nonReentrant {
        amount = msg.value;
        require(amount > 0, "Cannot stake 0");
        require(stakingOptionIndex < stakingOptions.length, "Invalid staking option");

        StakingOption memory option = stakingOptions[stakingOptionIndex];
        uint256 lockupPeriod = option.lockupPeriod;
        uint256 apy = option.apy;

        uint256 userBalance = getTotalStakedAmount(msg.sender);
        uint256 newBalance = userBalance + amount;

        int256 price = getLatestPrice();
        uint256 valueInDollars = (newBalance * uint256(price)) / (10 ** priceFeed.decimals());

        require(valueInDollars >= MIN_DOLLAR_VALUE, "New balance is below the minimum threshold");
        // require(stakingToken.allowance(msg.sender, address(this)) >= amount, "Allowance not enough");
        // stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        stakes[msg.sender].push(
            StakeInfo({
                amount: amount,
                startTime: block.timestamp,
                lockupPeriod: lockupPeriod,
                endTime: block.timestamp + lockupPeriod,
                apy: apy
            })
        );
        updateLeaderboard(msg.sender);

        emit Stake(msg.sender, amount, lockupPeriod, apy);
    }

    function _withdrawableAmount(uint256 stakeIndex) internal view returns (uint256) {
        StakeInfo storage stakingInfo = stakes[msg.sender][stakeIndex];
        uint256 stakingPeriod = stakingInfo.lockupPeriod / 1 days;
        uint256 timePassed = block.timestamp - stakingInfo.startTime;

        uint256 amountWhenStakingPeriodEnds = calculateReward(stakingInfo.apy, stakingInfo.amount, stakingPeriod);

        if (isMinimalRatePeriod(timePassed, stakingPeriod)) {
            uint256 minimalRatePeriod = getMinimalRatePeriod(timePassed, stakingPeriod);
            return calculateReward(_minimumRate, amountWhenStakingPeriodEnds, minimalRatePeriod);
        }

        return amountWhenStakingPeriodEnds;
    }

    function calculateReward(uint256 ratio, uint256 principal, uint256 n) public pure returns (uint256) {
        uint256 dailyRate = (ratio * 1e18) / (100 * 365); // Calculate daily rate as a fixed-point number
        uint256 amount = principal * 1e18; // Use fixed-point arithmetic for precision

        for (uint256 i = 0; i < n; i++) {
            amount = amount + (amount * dailyRate / 1e18);
        }

        return amount / 1e18; // Convert back to original units
    }

    function isMinimalRatePeriod(uint256 timePassed, uint256 stakingPeriod) internal pure returns (bool) {
        return timePassed / 1 days >= stakingPeriod + 1;
    }

    function getMinimalRatePeriod(uint256 timePassed, uint256 stakingPeriod) internal pure returns (uint256) {
        return (timePassed / 1 days) - stakingPeriod;
    }

    function getTotalStakedAmount(address user) public view returns (uint256) {
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < stakes[user].length; i++) {
            totalAmount += stakes[user][i].amount;
        }
        return totalAmount;
    }

    function getPenaltyRate(uint256 lockupPeriod) internal view returns (uint256) {
        for (uint256 i = 0; i < stakingOptions.length; i++) {
            if (stakingOptions[i].lockupPeriod == lockupPeriod) {
                return stakingOptions[i].penalty;
            }
        }
        return 1; // Default penalty for unspecified lockup period
    }

    function addStakingOption(uint256 apy, uint256 lockupPeriod, uint256 penalty) external onlyOwner {
        require(apy > 0 && apy <= MAX_APY, "Invalid APY");
        require(penalty <= 100, "Invalid penalty");
        stakingOptions.push(StakingOption(apy, lockupPeriod, penalty));
        emit StakingOptionAdded(apy, lockupPeriod, penalty);
    }

    function updateStakingOption(uint256 index, uint256 apy, uint256 lockupPeriod, uint256 penalty)
        external
        onlyOwner
    {
        require(index < stakingOptions.length, "Invalid index");
        require(apy > 0 && apy <= MAX_APY, "Invalid APY");
        require(penalty <= 100, "Invalid penalty");
        stakingOptions[index] = StakingOption(apy, lockupPeriod, penalty);
        emit StakingOptionUpdated(index, apy, lockupPeriod, penalty);
    }

    function setDaoWallet(address _daoWallet) external onlyOwner {
        emit DaoWalletUpdated(daoWallet, _daoWallet);
        daoWallet = _daoWallet;
    }

    function setPenaltyWallet(address _penaltyWallet) external onlyOwner {
        emit PenaltyWalletUpdated(penaltyWallet, _penaltyWallet);
        penaltyWallet = _penaltyWallet;
    }

    function setDaoSplit(uint8 _daoSplit) external onlyOwner {
        require(_daoSplit <= 100, "Invalid DAO split");
        emit DaoSplitUpdated(daoSplit, _daoSplit);
        daoSplit = _daoSplit;
    }

    function getStakingDetails(address user)
        external
        view
        returns (
            uint256[] memory amounts,
            uint256[] memory startTimes,
            uint256[] memory endTimes,
            uint256[] memory apys
        )
    {
        uint256 stakesCount = stakes[user].length;
        amounts = new uint256[](stakesCount);
        startTimes = new uint256[](stakesCount);
        endTimes = new uint256[](stakesCount);
        apys = new uint256[](stakesCount);

        for (uint256 i = 0; i < stakesCount; i++) {
            StakeInfo storage stakeInfo = stakes[user][i];
            amounts[i] = stakeInfo.amount;
            startTimes[i] = stakeInfo.startTime;
            endTimes[i] = stakeInfo.endTime;
            apys[i] = stakeInfo.apy;
        }
    }

    function getLeaderboardEntry(address user)
        external
        view
        returns (uint256 stakedAmount, uint256 walletBalance, uint256 combinedBalance)
    {
        LeaderboardEntry storage entry = leaderboard[user];
        return (getTotalStakedAmount(user), address(user).balance, entry.combinedBalance);
    }

    function getTopStakers(uint256 count) external view returns (address[] memory, uint256[] memory) {
        address[] memory addresses = new address[](count);
        uint256[] memory combinedBalances = new uint256[](count);

        for (uint256 i = 0; i < count && i < topStakers.length; i++) {
            addresses[i] = topStakers[i].user;
            combinedBalances[i] = topStakers[i].combinedBalance;
        }

        return (addresses, combinedBalances);
    }
}
