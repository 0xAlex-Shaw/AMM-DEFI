// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Freely mintable ERC20 for tests.
/// @dev The original extended `ERC20PresetMinterPauser`, which OpenZeppelin removed in v5 along with
///      the rest of the presets directory, so the old contract cannot compile against a supported OZ
///      release. Decimals are configurable because the borrow-amount solver used to assume 18 and
///      that assumption now needs testing against 6-decimal tokens like USDC.
contract TestERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
