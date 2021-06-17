pragma solidity >=0.6.2;

import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";

contract Migrator {
    address public CHEF;
    address public OLD_FACTORY;
    IUniswapV2Factory public FACTORY;
    uint256 public NOT_BEFORE_BLOCK;
    uint256 public DESIRED_LIQUIDITY = uint256(-1);

    constructor(
        address _chef,
        address _oldFactory,
        IUniswapV2Factory _factory,
        uint256 _notBeforeBlock
    ) public {
        CHEF = _chef;
        OLD_FACTORY = _oldFactory;
        FACTORY = _factory;
        NOT_BEFORE_BLOCK = _notBeforeBlock;
    }

    function migrate(IUniswapV2Pair _orig) public returns (IUniswapV2Pair) {
        require(msg.sender == CHEF, "not from master chef");
        require(block.number >= NOT_BEFORE_BLOCK, "too early to migrate");
        require(_orig.factory() == OLD_FACTORY, "not from old factory");

        address _token0 = _orig.token0();
        address _token1 = _orig.token1();

        IUniswapV2Pair _pair =
            IUniswapV2Pair(FACTORY.getPair(_token0, _token1));

        if (_pair == IUniswapV2Pair(address(0))) {
            _pair = IUniswapV2Pair(FACTORY.createPair(_token0, _token1));
        }

        uint256 _lp = _orig.balanceOf(msg.sender);

        if (_lp == 0) return _pair;

        DESIRED_LIQUIDITY = _lp;

        _orig.transferFrom(msg.sender, address(_orig), _lp);
        _orig.burn(address(_pair));
        _pair.mint(msg.sender);

        DESIRED_LIQUIDITY = uint256(-1);

        return _pair;
    }
}
