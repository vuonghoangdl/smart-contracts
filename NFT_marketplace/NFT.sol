//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol';
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract NFT is ERC721URIStorage, Ownable {
  //auto-increment field for each token
  using Counters for Counters.Counter;

  Counters.Counter private _tokenIds;

  bool public paused = false;
  address marketplaceAddress;
  IERC20 public WETH;

  constructor(address _marketplaceAddress, address _WETH) ERC721("Straym Collections", "SCS") {
    marketplaceAddress = _marketplaceAddress;
    WETH = IERC20(_WETH);
  }

  modifier mintPriceCompliance(uint256 _fee) {
    require(msg.value >= _fee, "Insufficient funds!");
    _;
  }

  /// @notice create a new token
  function createToken(string memory tokenURI, address _feeReceiver, uint256 _fee)
    public
    payable
    mintPriceCompliance(_fee)
    returns (uint256)
  {
    require(!paused, 'The contract is paused!');
    //set a new token id for the token to be minted
    _tokenIds.increment();
    uint256 newItemId = _tokenIds.current();

    _mint(_msgSender(), newItemId); //mint the token
    _setTokenURI(newItemId, tokenURI); //generate the URI
    //grant transaction permission to marketplace
    _setApprovalForAll(msg.sender, marketplaceAddress, true);

    if (_feeReceiver != address(0) && _fee > 0 && address(this).balance >= _fee) {
      // =============================================================================
      (bool hs, ) = payable(_feeReceiver).call{value: _fee}('');
      require(hs);
      // =============================================================================
    }    

    //return token ID
    return newItemId;
  }

  /// @notice create a new token and transfer to buyer
  function purchaseMarketItem(
    string memory tokenURI, address seller, uint256 price, 
    address commissionAddress, uint256 commissionPercent, 
    bytes calldata signature
  )
    public payable
    mintPriceCompliance(price)
    returns (uint256)
  {
    require(!paused, 'The contract is paused!');

    bytes32 message = prefixed(keccak256(abi.encodePacked(
        seller,
        tokenURI,
        price        
    )));
    require(recoverSigner(message, signature) == owner() , 'wrong signature');

    //set a new token id for the token to be minted
    _tokenIds.increment();
    uint256 newItemId = _tokenIds.current();

    _mint(seller, newItemId); //mint the token
    _setTokenURI(newItemId, tokenURI); //generate the URI

    // commision amount
    uint256 commissionAmount = price * commissionPercent / 100;
    //pay the seller the amount
    payable(seller).transfer(msg.value - commissionAmount);
    //pay the commissiont
    payable(commissionAddress).transfer(commissionAmount); 

    _transfer(seller, msg.sender, newItemId);
    //grant transaction permission to marketplace
    _setApprovalForAll(msg.sender, marketplaceAddress, true); 

    //return token ID
    return newItemId;
  }

  /// @notice function to accept an offer
  function acceptOfferItem(
      address signer,
      string memory tokenURI,
      uint256 price,        
      address commissionAddress,
      uint256 commissionPercent,
      bytes calldata signature
  ) public payable returns (uint256){
    bytes32 message = prefixed(keccak256(abi.encodePacked(
        signer,
        tokenURI,
        price
    )));
    require(recoverSigner(message, signature) == owner() , 'wrong signature');

    require(IERC20(WETH).balanceOf(address(signer)) >= price, "Please submit the asking price in order to complete purchase");
    require(IERC20(WETH).allowance(address(signer), address(this)) >= price, "Please allow the asking WETH in order to complete purchase");

    //set a new token id for the token to be minted
    _tokenIds.increment();
    uint256 newItemId = _tokenIds.current();

    _mint(msg.sender, newItemId); //mint the token
    _setTokenURI(newItemId, tokenURI); //generate the URI

    _setApprovalForAll(msg.sender, marketplaceAddress, true); //grant transaction permission to marketplace

    // commision amount
    uint256 commissionAmount = price * commissionPercent / 100;
    //pay the seller the amount
    IERC20(WETH).transferFrom(signer, msg.sender, price - commissionAmount);
    //pay the commissiont
    IERC20(WETH).transferFrom(signer, commissionAddress, commissionAmount);

    _transfer(msg.sender, signer, newItemId);

    _setApprovalForAll(signer, marketplaceAddress, true); //grant transaction permission to marketplace

    //return token ID
    return newItemId;
  }

  function setPaused(bool _state) public onlyOwner {
    paused = _state;
  }

  function prefixed(bytes32 hash) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(
    '\x19Ethereum Signed Message:\n32', 
    hash
    ));
  }

  function recoverSigner(bytes32 message, bytes memory sig)
    internal
    pure
    returns (address)
  {
    uint8 v;
    bytes32 r;
    bytes32 s;

    (v, r, s) = splitSignature(sig);

    return ecrecover(message, v, r, s);
  }

  function splitSignature(bytes memory sig)
    internal
    pure
    returns (uint8, bytes32, bytes32)
  {
    require(sig.length == 65);

    bytes32 r;
    bytes32 s;
    uint8 v;

    assembly {
        // first 32 bytes, after the length prefix
        r := mload(add(sig, 32))
        // second 32 bytes
        s := mload(add(sig, 64))
        // final byte (first byte of the next 32 bytes)
        v := byte(0, mload(add(sig, 96)))
    }

    return (v, r, s);
  }

  function convertSignature(
    address nftContract,
    uint256 tokenId,
    bytes calldata signature
  ) public pure returns (address) {
    bytes32 message = prefixed(keccak256(abi.encodePacked(
        nftContract,
        tokenId
    )));

    return recoverSigner(message, signature);
  }
}
