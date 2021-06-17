pragma solidity >=0.6.2;

import "./IBEP20.sol";

interface ITorCoin is IBEP20 {
    function mint(address recipient_, uint256 amount_) external;

    function getTransferTaxRate() external view returns (uint256);

    function transferOwnership(address newOwner) external;
}
