pragma solidity >=0.6.2;
pragma experimental ABIEncoderV2;

import "./Ownable.sol";
import "./libs/SafeMath.sol";
import "./libs/SafeToken.sol";
import "./interfaces/IBEP20.sol";
import "./interfaces/ITorCoin.sol";
import "./interfaces/IUniswapV2Router02.sol";

interface IAnonymousTree {
    function bind(bytes32 _commitment) external returns (bytes32, uint256);

    function unBind(
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address payable _recipient,
        address payable _relayer,
        uint256 _fee,
        uint256 _refund
    ) external;
}

interface IMigratorChef {
    function migrate(IBEP20 token) external returns (IBEP20);
}

contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeToken for IBEP20;

    struct Global {
        uint256 totalDeposit;
        uint256 total24hDeposit;
        uint256 lastDepositAt;
    }

    struct PoolInfo {
        IBEP20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accTorPerShare;
        uint16 depositFeeBP;
        uint256[] denominations;
        address[] anonymousTrees;
        uint256 freezeTokens;
        address[] paths;
    }

    struct UserInfo {
        DepositInfo[] depositInfos;
    }

    struct User {
        address referrer;
        uint256[3] levels;
        uint256 totalBonus;
    }

    struct DepositInfo {
        uint256 idx;
        uint256 denomination;
        uint256 rewardDebt;
        uint256 bonusForTors;
        uint256 at;
        bool invalid;
        bool excluded;
        IAnonymousTree anonymousTree;
    }

    ITorCoin public TOR;

    address public DEV_ADDRESS;
    address public FEE_ADDRESS;
    uint256 public TOR_PER_DAY;
    uint256 public constant BONUS_MULTIPLIER = 1;

    IMigratorChef public MIGRATOR;
    PoolInfo[] internal POOL_INFOR;

    mapping(uint256 => mapping(address => UserInfo)) internal USER_INFO;
    mapping(address => User) internal USERS;
    mapping(address => bool) internal EXECLUDED_FROM_LP;
    mapping(uint256 => Global) public GLOBALS;

    uint256 public TOTAL_ALLOC_POINT = 0;
    uint256 public STARTED_AT;
    uint256 public constant LIQUIDITY_PERCENT = 100;
    uint256 public constant PERCENTS_DIVIDER = 10000;
    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    uint256 public constant BURN_BONUS_DAYS = 7 days;
    IUniswapV2Router02 public SWAP_ROUTER;
    uint256 public TOR_BURN_TOTAL;
    uint256[] public REFERRAL_PERCENTS = [250, 150, 50];
    bool private INITIALIZED;

    event Deposit(
        address indexed sender,
        uint256 depositAmount,
        uint256 denomination,
        uint256 bonusForTors
    );
    event Reward(
        address indexed sender,
        uint256 contractBalance,
        uint256 tors,
        uint256 burnForTors,
        uint256 bonusForTors
    );
    event RefBonus(
        address indexed referrer,
        address indexed referral,
        uint256 indexed level,
        uint256 amount
    );
    event UpdatePool(uint256 indexed pid, uint256 multiplier, uint256 timeAt);

    modifier initializer() {
        require(INITIALIZED, "!initializer");
        _;
    }

    constructor(
        uint256 _torPerDay,
        address _dev,
        address _fee
    ) public {
        TOR_PER_DAY = _torPerDay;

        DEV_ADDRESS = _dev;
        FEE_ADDRESS = _fee;
    }

    function initialize(uint256 _startedAt) external onlyOwner {
        require(!INITIALIZED, "Contract is already initialized");

        STARTED_AT = _startedAt == 0 ? block.number : _startedAt;

        for (uint256 _pid = 0; _pid < POOL_INFOR.length; _pid++) {
            if (POOL_INFOR[_pid].lastRewardBlock == 0) {
                POOL_INFOR[_pid].lastRewardBlock = _startedAt;
            }
        }

        INITIALIZED = true;
    }

    function poolLength() external view returns (uint256) {
        return POOL_INFOR.length;
    }

    function getPoolInfo(uint256 _pid)
        public
        view
        returns (
            address,
            uint256,
            uint256,
            uint256,
            uint16,
            uint256[] memory,
            address[] memory,
            uint256 freezeTokens,
            address[] memory
        )
    {
        PoolInfo memory _pool = POOL_INFOR[_pid];

        return (
            address(_pool.lpToken),
            _pool.allocPoint,
            _pool.lastRewardBlock,
            _pool.accTorPerShare,
            _pool.depositFeeBP,
            _pool.denominations,
            _pool.anonymousTrees,
            _pool.freezeTokens,
            _pool.paths
        );
    }

    function addPool(
        uint256 _allocPoint,
        address _lpToken,
        uint16 _depositFeeBP,
        uint256[] memory _denominations,
        bool _withUpdate,
        address[] memory _anonymousTrees,
        address[] memory _paths,
        uint256 _lastRewardBlock
    ) public onlyOwner {
        require(
            _depositFeeBP <= PERCENTS_DIVIDER,
            "add: invalid deposit fee basis points"
        );

        if (_withUpdate) {
            massUpdatePools();
        }

        // uint256 _lastRewardBlock =
        //     block.number > STARTED_AT ? block.number : STARTED_AT;

        TOTAL_ALLOC_POINT = TOTAL_ALLOC_POINT.add(_allocPoint);

        POOL_INFOR.push(
            PoolInfo({
                lpToken: ITorCoin(_lpToken),
                allocPoint: _allocPoint,
                lastRewardBlock: _lastRewardBlock > 0 ? _lastRewardBlock : 0,
                accTorPerShare: 0,
                depositFeeBP: _depositFeeBP,
                denominations: _denominations,
                anonymousTrees: _anonymousTrees,
                paths: _paths,
                freezeTokens: 0
            })
        );
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _depositFeeBP,
        bool _withUpdate,
        uint256[] memory _denominations,
        address[] memory _anonymousTrees,
        address[] memory _paths
    ) public onlyOwner {
        require(
            _depositFeeBP <= PERCENTS_DIVIDER,
            "set: invalid deposit fee basis points"
        );

        if (_withUpdate) {
            massUpdatePools();
        }

        TOTAL_ALLOC_POINT = TOTAL_ALLOC_POINT
            .sub(POOL_INFOR[_pid].allocPoint)
            .add(_allocPoint);

        POOL_INFOR[_pid].allocPoint = _allocPoint;
        POOL_INFOR[_pid].depositFeeBP = _depositFeeBP;

        if (_denominations.length > 0) {
            POOL_INFOR[_pid].denominations = _denominations;
        }

        if (_anonymousTrees.length > 0) {
            POOL_INFOR[_pid].anonymousTrees = _anonymousTrees;
        }

        if (_paths.length > 0) {
            POOL_INFOR[_pid].paths = _paths;
        }
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(MIGRATOR) != address(0), "!MIGRATOR");
        PoolInfo storage _pool = POOL_INFOR[_pid];

        IBEP20 lpToken = _pool.lpToken;

        uint256 _lpSupply = lpToken.balanceOf(address(this));

        lpToken.safeApprove(address(MIGRATOR), _lpSupply);

        IBEP20 _newLpToken = MIGRATOR.migrate(lpToken);

        require(
            _lpSupply == _newLpToken.balanceOf(address(this)),
            "migrate: bad"
        );

        _pool.lpToken = _newLpToken;
    }

    function massUpdatePools() public {
        for (uint256 _pid = 0; _pid < POOL_INFOR.length; _pid++) {
            updatePool(_pid);
        }
    }

    function updatePool(uint256 _pid) public {
        PoolInfo storage _pool = POOL_INFOR[_pid];

        if (block.number <= _pool.lastRewardBlock) {
            return;
        }

        Global storage _g = GLOBALS[_pid];

        uint256 _lpSupply = _g.totalDeposit.sub(_pool.freezeTokens);

        if (_lpSupply == 0 || _pool.allocPoint == 0) {
            _pool.lastRewardBlock = block.number;
            return;
        }

        uint256 _multiplier =
            getMultiplier(_pool.lastRewardBlock, block.number);
        uint256 _torReward =
            _multiplier.mul(TOR_PER_DAY).mul(_pool.allocPoint).div(
                TOTAL_ALLOC_POINT
            );

        if (_torReward == 0) {
            return;
        }

        TOR.mint(DEV_ADDRESS, _torReward.div(10));
        TOR.mint(address(this), _torReward);

        _pool.accTorPerShare = _pool.accTorPerShare.add(
            _torReward.mul(1e12).div(_lpSupply)
        );

        _pool.lastRewardBlock = block.number;

        emit UpdatePool(_pid, _multiplier, block.timestamp);
    }

    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    function findDenomination(PoolInfo storage _pool, uint256 _amount)
        internal
        view
        returns (bool, uint256)
    {
        bool _found;
        uint256 _idx;

        for (uint256 i = 0; i < _pool.denominations.length; i++) {
            if (_pool.denominations[i] == _amount) {
                _found = true;
                _idx = i;
                break;
            }
        }

        return (_found, _idx);
    }

    function swapForTors(PoolInfo memory _pool, uint256 _amount)
        internal
        returns (uint256, uint256)
    {
        _pool.lpToken.safeTransferFrom(
            address(_msgSender()),
            address(this),
            _amount
        );

        if (isExcludedFromLP(address(_pool.lpToken)) || isDevMode()) {
            return (_amount, 0);
        }

        uint256 _swapAmount =
            _amount.mul(LIQUIDITY_PERCENT).div(PERCENTS_DIVIDER);

        _pool.lpToken.approve(address(SWAP_ROUTER), _swapAmount);

        // amounts[1] == _bonusForTors
        uint256[] memory _amounts =
            SWAP_ROUTER.swapExactTokensForTokens(
                _swapAmount,
                0,
                _pool.paths,
                address(this),
                block.timestamp
            );

        return (_amount.sub(_swapAmount), _amounts[_pool.paths.length - 1]);
    }

    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) external initializer {
        PoolInfo storage _pool = POOL_INFOR[_pid];
        UserInfo storage _userInfo = USER_INFO[_pid][_msgSender()];
        DepositInfo memory _depositInfo;

        if (isExcludedFromLP(address(_pool.lpToken))) {
            _depositInfo.excluded = true;
        } else {
            (bool _found, uint256 _idx) = findDenomination(_pool, _amount);

            require(_found, "!findDenomination");

            _depositInfo.idx = _idx;
            _depositInfo.anonymousTree = IAnonymousTree(
                _pool.anonymousTrees[_idx]
            );
        }

        (uint256 _denomination, uint256 _bonusForTors) =
            swapForTors(_pool, _amount);

        if (address(_pool.lpToken) == address(TOR)) {
            uint256 _transferTax =
                _denomination.mul(TOR.getTransferTaxRate()).div(
                    PERCENTS_DIVIDER
                );
            _denomination = _denomination.sub(_transferTax);
        }

        User storage user = USERS[_msgSender()];

        if (user.referrer == address(0)) {
            if (_referrer != _msgSender()) {
                user.referrer = _referrer;
            }

            address upline = user.referrer;
            for (uint256 i = 0; i < 3; i++) {
                if (upline != address(0)) {
                    USERS[upline].levels[i] = USERS[upline].levels[i].add(1);
                    upline = USERS[upline].referrer;
                } else break;
            }
        }

        if (_pool.depositFeeBP > 0) {
            uint256 _depositFee =
                _denomination.mul(_pool.depositFeeBP).div(PERCENTS_DIVIDER);
            _pool.lpToken.safeTransfer(FEE_ADDRESS, _depositFee);
            _depositInfo.denomination = _denomination.sub(_depositFee);
        } else {
            _depositInfo.denomination = _denomination;
        }

        Global storage _g = GLOBALS[_pid];

        if (
            block.timestamp.sub(_g.lastDepositAt) <= 24 hours ||
            _g.lastDepositAt == 0
        ) {
            _g.total24hDeposit = _g.total24hDeposit.add(
                _depositInfo.denomination
            );
        } else {
            _g.total24hDeposit = 0;
        }

        _g.totalDeposit = _g.totalDeposit.add(_depositInfo.denomination);
        _g.lastDepositAt = block.timestamp;

        updatePool(_pid);

        _depositInfo.rewardDebt = _depositInfo
            .denomination
            .mul(_pool.accTorPerShare)
            .div(1e12);
        _depositInfo.at = block.timestamp;
        _depositInfo.bonusForTors = _bonusForTors;

        _userInfo.depositInfos.push(_depositInfo);

        emit Deposit(
            _msgSender(),
            _amount,
            _depositInfo.denomination,
            _bonusForTors
        );
    }

    function bindNote(
        bytes32 _commitment,
        uint256 _pid,
        uint256 _depositId
    ) external initializer {
        PoolInfo storage _pool = POOL_INFOR[_pid];
        User storage user = USERS[_msgSender()];
        DepositInfo storage _depositInfo =
            USER_INFO[_pid][_msgSender()].depositInfos[_depositId];

        require(_depositInfo.at > 0, "!at");
        require(_depositInfo.invalid == false, "!invalid");

        updatePool(_pid);

        (
            uint256 _tors,
            uint256 _burnForTors,
            uint256 _bonusForTors,
            uint256 _rewardDebt
        ) = getReward(_pid, _depositId, _msgSender());

        if (user.referrer != address(0)) {
            address _upline = user.referrer;
            for (uint256 i = 0; i < 3; i++) {
                if (_upline != address(0)) {
                    uint256 _torBonus =
                        _tors.mul(REFERRAL_PERCENTS[i]).div(PERCENTS_DIVIDER);
                    safeTorTransfer(_upline, _torBonus);
                    USERS[_upline].totalBonus = USERS[_upline].totalBonus.add(
                        _torBonus
                    );
                    _upline = USERS[_upline].referrer;
                    _tors = _tors.sub(_torBonus);

                    emit RefBonus(_upline, _msgSender(), i, _torBonus);
                } else break;
            }
        }

        if (_bonusForTors > 0) {
            safeTorTransfer(_msgSender(), _bonusForTors);
        } else {
            TOR_BURN_TOTAL = TOR_BURN_TOTAL.add(_burnForTors);

            safeTorTransfer(BURN_ADDRESS, _burnForTors);
        }

        safeTorTransfer(_msgSender(), _tors);

        if (isExcludedFromLP(address(_pool.lpToken)) && _depositInfo.excluded) {
            _pool.lpToken.safeTransfer(_msgSender(), _depositInfo.denomination);

            Global storage _g = GLOBALS[_pid];
            _g.totalDeposit = _g.totalDeposit.sub(_depositInfo.denomination);
        } else {
            _depositInfo.anonymousTree.bind(_commitment);

            _pool.freezeTokens = _pool.freezeTokens.add(
                _depositInfo.denomination
            );
        }

        _depositInfo.invalid = true;
        _depositInfo.rewardDebt = _rewardDebt;

        emit Reward(
            _msgSender(),
            TOR.balanceOf(address(this)),
            _tors,
            _burnForTors,
            _bonusForTors
        );
    }

    function withdraw(
        uint256 _pid,
        uint256 _idx,
        bytes calldata _proof,
        bytes32 _root,
        bytes32 _nullifierHash,
        address payable _recipient,
        address payable _relayer,
        uint256 _fee,
        uint256 _refund
    ) external initializer {
        PoolInfo storage _pool = POOL_INFOR[_pid];

        require(_idx < _pool.anonymousTrees.length, "!_idx");

        IAnonymousTree(_pool.anonymousTrees[_idx]).unBind(
            _proof,
            _root,
            _nullifierHash,
            _recipient,
            _relayer,
            _fee,
            _refund
        );

        uint256 _denomination = _pool.denominations[_idx];

        if (!isExcludedFromLP(address(_pool.lpToken))) {
            _denomination = _denomination.sub(
                _denomination.mul(LIQUIDITY_PERCENT).div(PERCENTS_DIVIDER)
            );
        }

        Global storage _g = GLOBALS[_pid];
        _g.totalDeposit = _g.totalDeposit.sub(_denomination);

        _pool.lpToken.safeTransfer(_recipient, _denomination - _fee);

        _pool.freezeTokens = _pool.freezeTokens.sub(_denomination);

        if (_fee > 0) {
            _pool.lpToken.safeTransfer(_relayer, _fee);
        }

        if (_refund > 0) {
            (bool success, ) = _recipient.call.value(_refund)("");
            if (!success) {
                _relayer.transfer(_refund);
            }
        }
    }

    function getDeposits(uint256 _pid, address _sender)
        public
        view
        returns (UserInfo memory)
    {
        UserInfo memory _userInfo = USER_INFO[_pid][_sender];

        return _userInfo;
    }

    function getReward(
        uint256 _pid,
        uint256 _depositId,
        address _sender
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        PoolInfo memory _pool = POOL_INFOR[_pid];
        DepositInfo memory _depositInfo =
            USER_INFO[_pid][_sender].depositInfos[_depositId];

        require(_depositInfo.at > 0, "!at");

        if (_depositInfo.invalid == true) {
            return (0, 0, 0, 0);
        }

        Global memory _g = GLOBALS[_pid];

        uint256 _lpSupply = _g.totalDeposit.sub(_pool.freezeTokens);
        uint256 _accTorPerShare = _pool.accTorPerShare;

        if (block.number > _pool.lastRewardBlock && _lpSupply > 0) {
            uint256 _multiplier =
                getMultiplier(_pool.lastRewardBlock, block.number);
            uint256 _torReward =
                _multiplier.mul(TOR_PER_DAY).mul(_pool.allocPoint).div(
                    TOTAL_ALLOC_POINT
                );

            _accTorPerShare = _accTorPerShare.add(
                _torReward.mul(1e12).div(_lpSupply)
            );
        }

        uint256 _rewardDebt =
            _depositInfo.denomination.mul(_accTorPerShare).div(1e12);

        uint256 _tors = _rewardDebt.sub(_depositInfo.rewardDebt);

        if (
            !_depositInfo.excluded &&
            _depositInfo.at.add(BURN_BONUS_DAYS) <= block.timestamp
        ) {
            return (
                _tors,
                _depositInfo.bonusForTors,
                _depositInfo.bonusForTors,
                _rewardDebt
            );
        }

        return (_tors, _depositInfo.bonusForTors, 0, _rewardDebt);
    }

    function safeTorTransfer(address _to, uint256 _amount) internal {
        uint256 masterChefBalance = TOR.balanceOf(address(this));

        if (_amount > masterChefBalance) {
            TOR.transfer(_to, masterChefBalance);
        } else {
            TOR.transfer(_to, _amount);
        }
    }

    function updateSwapRouter(address _router) public onlyOwner {
        SWAP_ROUTER = IUniswapV2Router02(_router);
    }

    function updateTor(address _tor) public onlyOwner {
        TOR = ITorCoin(_tor);
    }

    function updateTorTransferOwnership(address _v) public onlyOwner {
        TOR.transferOwnership(_v);
    }

    function setExcludedFromLP(address _v, bool _excluded) public onlyOwner {
        EXECLUDED_FROM_LP[_v] = _excluded;
    }

    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        MIGRATOR = _migrator;
    }

    function isExcludedFromLP(address _v) public view returns (bool) {
        return EXECLUDED_FROM_LP[_v];
    }

    function getUserReferrer(address _v) public view returns (address) {
        return USERS[_v].referrer;
    }

    function getUserDownlineCount(address _v)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (USERS[_v].levels[0], USERS[_v].levels[1], USERS[_v].levels[2]);
    }

    function getUserReferralTotalBonus(address _v)
        public
        view
        returns (uint256)
    {
        return USERS[_v].totalBonus;
    }

    function getChainId() internal pure returns (uint256) {
        uint256 chainId;

        assembly {
            chainId := chainid()
        }

        return chainId;
    }

    function isDevMode() public pure returns (bool) {
        return getChainId() == 97 ? true : false;
    }
}
