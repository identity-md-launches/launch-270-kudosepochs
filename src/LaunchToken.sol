// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The fixed-supply Kudos currency; the factory receives the entire supply at deployment.
contract LaunchToken is ERC20 {
    constructor() ERC20("Kudos", "KUDO") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
