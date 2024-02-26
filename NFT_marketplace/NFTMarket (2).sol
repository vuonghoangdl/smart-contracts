//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

contract NFTStraymMarket is Ownable, EIP712 {
  using Counters for Counters.Counter;
  Counters.Counter private _itemIds; //total number of items ever created
  Counters.Counter private _itemsSold; //total number of items sold

  IERC20 public WETH;
  address public commissionAddress;
  uint256 public commissionPercent;

  uint256 constant sellOfferType = 0;
  uint256 constant buyOfferType = 1;

  bytes32 constant MESSAGE_TYPEHASH = keccak256(
    "Message(address offerer,address token,uint256 tokenId,uint256 price,uint256 amount,uint256 offerType)"
  );

  constructor(
    address _WETH, address _commissionAddress, uint256 _commissionPercent
  ) EIP712("Straym Marketplace", "1") {
    WETH = IERC20(_WETH);
    commissionAddress = _commissionAddress;
    commissionPercent = _commissionPercent;
  }

  struct Offer {
    /* Seller address. */
    address seller;
    /* Buyer maker address. */
    address buyer;
    /* NFT contract address. */
    address tokenAddress;
    /* NFT id. */
    uint256 tokenId;
    /* Offer price. */
    uint256 price;
    /* Offer amount. */
    uint256 amount;
  }
  struct Message {
    address offerer;
    address token;
    uint256 tokenId;
    uint256 price;
    uint256 amount;
    uint256 offerType;
  }
  struct Signatures {
    /* Seller address. */
    bytes sellOfferSignature;
    /* Buyer maker address. */
    bytes buyOfferSignature;
  }  

  //log message (when Item is sold)
  event MarketItemSelled (
    uint indexed itemId,
    address indexed tokenAddress,
    uint256 indexed tokenId,
    address  seller,
    address  owner,
    uint256 price,
    uint256 amount,
    bool sold
  );

  modifier checkSellSignature(
    Offer memory offer,
    bytes memory sellOfferSignature
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        MESSAGE_TYPEHASH,
        offer.seller,
        offer.tokenAddress,
        offer.tokenId,
        offer.price,
        offer.amount,
        sellOfferType      
    )));
    address signer = ECDSA.recover(digest, sellOfferSignature);
    require(signer == offer.seller , 'wrong sell offer signature');
    _;
  }
  modifier checkSellerNFTPermission(
    Offer memory offer
  ) {
    require(IERC1155(offer.tokenAddress).balanceOf(offer.seller, offer.tokenId) > 0, "Seller is not owner of NFT");
    require(IERC1155(offer.tokenAddress).isApprovedForAll(offer.seller, address(this)), "Marketplace do not have permission to transfer this NFT");
    _;
  }
  modifier checkBuyInfo(
    Offer memory offer,
    bytes memory buyOfferSignature
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        MESSAGE_TYPEHASH,
        offer.buyer,
        offer.tokenAddress,
        offer.tokenId,
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
    address tokenAddress,
    uint256 tokenId,
    uint256 price,
    uint256 amount,
    bytes calldata sellOfferSignature,
    bytes calldata buyOfferSignature
  ) 
    public
  {
    _matchOffer(
      Offer(
        seller,
        buyer,
        tokenAddress,
        tokenId,
        price,
        amount
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
    internal 
    checkSellSignature(offer,signatures.sellOfferSignature)
    checkSellerNFTPermission(offer)
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
    uint256 offerTokenId = offer.tokenId;
    address offerTokenAddress = offer.tokenAddress;

    //transfer ownership of the nft from the contract itself to the buyer
    IERC1155(offerTokenAddress).safeTransferFrom(offerSeller, offerBuyer, offerTokenId, offerAmount, '');

    _itemIds.increment(); //add 1 to the total number of items ever created
    uint256 itemId = _itemIds.current();

    emit MarketItemSelled(
      itemId,
      offerTokenAddress,
      offerTokenId,
      offerSeller,
      offerBuyer,
      offer.price,
      offerAmount,
      false
    );
  }

  function setCommissionAddress(address _commissionAddress) public onlyOwner {
    commissionAddress = _commissionAddress;
  }
  function setCommissionPercent(uint256 _commissionPercent) public onlyOwner {
    commissionPercent = _commissionPercent;
  }
}
