// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract NFTDAOToken is ERC20 {
  constructor() ERC20('NFTDAO', 'NFTDAO') {
    _mint(msg.sender, 1000000000000000 * 10 ** 18);
  }
}
