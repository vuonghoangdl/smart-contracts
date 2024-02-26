// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract NFTStoreFront is ERC1155, Ownable, ReentrancyGuard, EIP712 {
  string public name = "Straym Shared Storefront";
  string public symbol = "StraymStore";
  uint256 constant sellOfferType = 0;
  uint256 constant buyOfferType = 1;

  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds; //Counter to keep track of the number of NFT we minted and make sure we dont try to mint the same twice
  
  address public marketplaceAddress;
  address public mintingFeeAddress = 0xc8A649F517163205C62eE16F49F764715566f187;
  uint256 public mintingFee = 10000000000000000; // 0.01ETH
  IERC20 public WETH;
  address public commissionAddress;
  uint256 public commissionPercent;
  bool public paused = false;

  mapping (uint256 => string) private _tokenURIs;   //We create the mapping for TokenID -> URI

  constructor(
    address _marketplaceAddress, 
    address _WETH,
    address _commissionAddress, uint256 _commissionPercent
  ) 
    ERC1155("StraymStoreFront") 
    EIP712("Straym Marketplace", "1")
  {
    marketplaceAddress = _marketplaceAddress;
    WETH = IERC20(_WETH);
    commissionAddress = _commissionAddress;
    commissionPercent = _commissionPercent;
  }

  struct Offer {
    address seller;
    address buyer;
    string tokenUri;
    uint256 price;
    uint256 amount;
    uint256 totalAmount;
  }
  struct Signatures {
    /* Seller address. */
    bytes sellOfferSignature;
    /* Buyer maker address. */
    bytes buyOfferSignature;
  } 
  struct Message {
    address offerer;
    string tokenUri;
    uint256 price;
    uint256 amount;
    uint256 offerType;
  } 

  modifier mintPriceCompliance() {
    require(msg.value >= mintingFee, "Insufficient funds!");
    _;
  }

  function mintToken(string calldata tokenUri, uint256 amount) 
    public
    payable
    nonReentrant
    mintPriceCompliance()
    returns(uint256)
  {
    require(!paused, 'The contract is paused!');

    uint256 newItemId = _tokenIds.current();
    _mint(msg.sender, newItemId, amount, "");
    _setTokenUri(newItemId, tokenUri);

    _tokenIds.increment();
    setApprovalForAll(marketplaceAddress, true);

    if (mintingFeeAddress != address(0) && mintingFee > 0 && address(this).balance >= mintingFee) {
      // =============================================================================
      (bool hs, ) = payable(mintingFeeAddress).call{value: mintingFee}('');
      require(hs);
      // =============================================================================
    } 

    return newItemId;
  }

  modifier checkSellInfo(
    Offer memory offer
  ) {
    require(offer.totalAmount >= offer.amount , 'Offer amount should not bigger than total amount');
    _;
  }
  modifier checkSellSignature(
    Offer memory offer,
    bytes memory sellOfferSignature
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        keccak256("Message(address offerer,string tokenUri,uint256 price,uint256 amount,uint256 offerType)"),
        offer.seller,
        keccak256(bytes(offer.tokenUri)),
        offer.price,
        offer.amount,
        sellOfferType      
    )));
    address signer = ECDSA.recover(digest, sellOfferSignature);
    require(signer == offer.seller , 'wrong sell offer signature');
    _;
  }
  modifier checkBuyInfo(
    Offer memory offer,
    bytes memory buyOfferSignature
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        keccak256("Message(address offerer,string tokenUri,uint256 price,uint256 amount,uint256 offerType)"),
        offer.buyer,
        keccak256(bytes(offer.tokenUri)),
        offer.price,
        offer.amount,
        buyOfferType      
    )));
    address signer = ECDSA.recover(digest, buyOfferSignature);
    require(signer == offer.buyer , 'wrong buy offer signature');
    _;
  }
  modifier checkBuyerWETH(
    Offer memory offer
  ) {
    require(IERC20(WETH).balanceOf(offer.buyer) >= offer.price * offer.amount, "Please submit the asking price in order to complete purchase");
    require(IERC20(WETH).allowance(offer.buyer, address(this)) >= offer.price * offer.amount, "Please allow the asking WETH in order to complete purchase");
    _;
  }

  /// @notice function to accept an offer
  function matchOffer(
    address seller,
    address buyer,
    string calldata tokenUri,
    uint256 price,
    uint256 totalAmount,
    uint256 offerAmount,
    bytes calldata sellOfferSignature,
    bytes calldata buyOfferSignature
  ) 
    public
  {
    require(!paused, 'The contract is paused!');
    _matchOffer(
      Offer(
        seller,
        buyer,
        tokenUri,
        price,
        offerAmount,
        totalAmount
      ),
      Signatures(
        sellOfferSignature,
        buyOfferSignature
      )
    );
  }

  function _matchOffer(
    Offer memory offer,
    Signatures memory signatures
  ) 
    private 
    checkSellInfo(offer)
    checkSellSignature(offer,signatures.sellOfferSignature)
    checkBuyInfo(offer, signatures.buyOfferSignature)
    checkBuyerWETH(offer)
  {
    _transferWETH(offer);
    _transferNFTs(offer);
  }

  function _transferWETH(
    Offer memory offer
  ) 
    private
  {
    address offerSeller = offer.seller;
    address offerBuyer = offer.buyer;
    uint256 offerAmount = offer.amount;
    uint256 offerPrice = offer.price;
    uint256 offerTotalPrice = offerPrice * offerAmount;
    // commision amount
    uint256 commissionAmount = offerTotalPrice * commissionPercent / 100;
    //pay the seller the amount
    IERC20(WETH).transferFrom(offerBuyer, offerSeller, offerTotalPrice - commissionAmount);
    //pay commission
    IERC20(WETH).transferFrom(offerBuyer, commissionAddress, commissionAmount);
  }
  function _transferNFTs(
    Offer memory offer
  ) 
    private
  {
    address offerSeller = offer.seller;
    address offerBuyer = offer.buyer;
    uint256 offerAmount = offer.amount;
    uint256 totalAmount = offer.totalAmount;
     
    //transfer ownership of the nft from the contract itself to the buyer
    uint256 newItemId = _tokenIds.current();
    string memory tokenUri = offer.tokenUri;
    _mint(offerSeller, newItemId, totalAmount, "");
    _setTokenUri(newItemId, tokenUri);
    _safeTransferFrom(offerSeller, offerBuyer, newItemId, offerAmount, "");
    setApprovalForAll(marketplaceAddress, true);
    _tokenIds.increment();
  }

  function setCommissionAddress(address _commissionAddress) public onlyOwner {
    commissionAddress = _commissionAddress;
  }
  function setCommissionPercent(uint256 _commissionPercent) public onlyOwner {
    commissionPercent = _commissionPercent;
  }
  function uri(uint256 tokenId) override public view returns (string memory) { //We override the uri function of the EIP-1155: Multi Token Standard (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC1155/ERC1155.sol)
    return(_tokenURIs[tokenId]);
  }
  
  function _setTokenUri(uint256 tokenId, string memory tokenUri) private {
    _tokenURIs[tokenId] = tokenUri; 
  }

  function setPaused(bool _state) public onlyOwner {
    paused = _state;
  }
  function setMarketplaceAddress(address _marketplaceAddress) public onlyOwner {
    marketplaceAddress = _marketplaceAddress;
  }
  function setMintingFeeAddress(address _mintingFeeAddress) public onlyOwner {
    mintingFeeAddress = _mintingFeeAddress;
  }
  function setMintingFee(uint256 _mintingFee) public onlyOwner {
    mintingFee = _mintingFee;
  }
}