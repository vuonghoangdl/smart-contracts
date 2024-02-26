// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC1155/ERC1155.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

contract NFTStore is ERC1155 {
    address marketplaceAddress = 0x1b23b1580F265CFd672e0A33f6D2804c1A99F45F;

    constructor(
        
    ) ERC1155("ipfs://QmQmSjszj5hzqL7vwVzNah3Qxt4LXWEC1hvknWkNaJFPxQ/metadata/{id}.json") {
        _mint(msg.sender, 1, 10**18, "");
        _mint(msg.sender, 2, 10**27, "");
        _mint(msg.sender, 3, 1, "");
        _mint(msg.sender, 4, 10**18, "");
        _mint(msg.sender, 5, 10**27, "");
        _mint(msg.sender, 6, 10**9, "");
        _mint(msg.sender, 7, 1, "");
        _mint(msg.sender, 8, 10**27, "");

        setApprovalForAll(marketplaceAddress, true);
    }
}
