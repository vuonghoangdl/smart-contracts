// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import '@openzeppelin/contracts/interfaces/IERC2981.sol';

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./PaymentSplitter.sol";

contract NFTStoreFront is ERC1155, IERC2981, Ownable, ReentrancyGuard, EIP712 {
  string public name = "Straym Shared Storefront";
  string public symbol = "StraymStore";

  uint8 constant sellOfferType = 0;
  uint8 constant buyOfferType = 1;
  uint8 constant priceTypeExact = 0;
  uint8 constant priceTypeMinMax = 1;
  uint8 constant sellerPayGas = 1;
  uint8 constant buyerPayGas = 0;
  uint8 royaltyPercent = 10;
  uint256 constant INITIAL_FEE = 21000;

  using Counters for Counters.Counter;
  Counters.Counter private _tokenIds; //Counter to keep track of the number of NFT we minted and make sure we dont try to mint the same twice
  
  address public marketplaceAddress;
  address public mintingFeeAddress;
  uint256 public mintingFee = 10000000000000; // 0.00001ETH
  IERC20 public WETH;
  address public commissionAddress;
  uint256 public commissionPercent;
  bool public paused = false;

  bytes32 constant MESSAGE_TYPEHASH = keccak256(
    "Message(address offerer,string tokenUri,uint256 price,uint256 priceType,uint256 amount,uint256 offerType)"
  );

  mapping (uint256 => string) private _tokenURIs;   //We create the mapping for TokenID -> URI
  mapping(uint256 => address) private recipients;
  mapping(uint256 => uint8) private royaltyPercents;

  constructor(
    address _marketplaceAddress, 
    address _WETH,
    address _commissionAddress, uint256 _commissionPercent
  ) 
    ERC1155("Straym StoreFront") 
    EIP712("Straym Marketplace", "1")
  {
    marketplaceAddress = _marketplaceAddress;
    WETH = IERC20(_WETH);
    commissionAddress = _commissionAddress;
    commissionPercent = _commissionPercent;
    mintingFeeAddress = _msgSender();
  }

  struct SellOffer {
    address seller;
    uint256 price;
    uint8 priceType;
    bytes signature;
  }
  struct BuyOffer {
    address buyer;
    uint256 price;
    uint8 priceType;
    bytes signature;
  }
  struct OfferToken {
    string tokenUri;
    uint256 price;
    uint256 amount;
    uint256 totalAmount;
  }
  struct Message {
    address offerer;
    string tokenUri;
    uint256 price;
    uint8 priceType;
    uint256 amount;
    uint256 offerType;
  } 

  modifier mintPriceCompliance() {
    require(msg.value >= mintingFee, "Insufficient funds!");
    _;
  }

  function mintToken(string calldata tokenUri, uint256 amount, address[] memory payees, uint256[] memory shares_) 
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

    if(payees.length > 0) {
      if(payees.length == 1) {
        _setRoyalties(newItemId, payees[0]);
      } else {
        address splitter = address(new PaymentSplitter(payees, shares_));
        _setRoyalties(newItemId, splitter);
      }
    }

    return newItemId;
  }

  modifier checkSellNFTInfo(
    OfferToken memory offer
  ) {
    require(offer.totalAmount >= offer.amount , 'Offer amount should not bigger than total amount');
    _;
  }
  modifier checkSellSignature(
    SellOffer memory sellOffer,  
    OfferToken memory offerToken
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        MESSAGE_TYPEHASH,
        sellOffer.seller,
        keccak256(bytes(offerToken.tokenUri)),
        sellOffer.price,
        sellOffer.priceType,
        offerToken.amount,
        sellOfferType      
    )));
    address signer = ECDSA.recover(digest, sellOffer.signature);
    require(signer == sellOffer.seller , 'wrong sell offer signature');
    _;
  }
  modifier checkBuySignature(
    BuyOffer memory buyOffer,
    OfferToken memory offerToken
  ) {
    bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
        MESSAGE_TYPEHASH,
        buyOffer.buyer,
        keccak256(bytes(offerToken.tokenUri)),
        buyOffer.price,
        buyOffer.priceType,
        offerToken.amount,
        buyOfferType      
    )));
    address signer = ECDSA.recover(digest, buyOffer.signature);
    require(signer == buyOffer.buyer , 'wrong buy offer signature');
    _;
  }
  modifier checkBuyerWETH(
    address buyer,
    uint256 matchPrice,
    uint256 amount,
    uint256 gasPayer,
    uint256 gasLimit
  ) {
    if (gasPayer == buyerPayGas) {
      require(IERC20(WETH).balanceOf(buyer) >= ((matchPrice * amount) + gasLimit), "Please submit the asking price in order to complete purchase");
      require(IERC20(WETH).allowance(buyer, address(this)) >= ((matchPrice * amount) + gasLimit), "Please allow the asking WETH in order to complete purchase");
    } else {
      require(IERC20(WETH).balanceOf(buyer) >= matchPrice * amount, "Please submit the asking price in order to complete purchase");
      require(IERC20(WETH).allowance(buyer, address(this)) >= matchPrice * amount, "Please allow the asking WETH in order to complete purchase");
    }
    _;
  }
  modifier checkMatchWETH(
    uint256 matchPrice,
    uint256 sellPrice,
    uint256 buyPrice,
    uint8 sellPriceType,
    uint8 buyPriceType
  ) {
    require(sellPriceType == priceTypeExact || sellPriceType == priceTypeMinMax, "Sell price type not valid");
    require(buyPriceType == priceTypeExact || buyPriceType == priceTypeMinMax, "Buy price type not valid");

    if (sellPriceType == priceTypeExact) {
      require(matchPrice == sellPrice, "Match price not equal to sell price");
    }
    if (buyPriceType == priceTypeExact) {
      require(matchPrice == buyPrice, "Match price not equal to buy price");
    }
    if (sellPriceType == priceTypeMinMax) {
      require(matchPrice >= sellPrice, "Match price must be greater than min sell price");
    }
    if (buyPriceType == priceTypeMinMax) {
      require(buyPrice >= matchPrice, "Match price must be less than max buy price");
    }
    _;
  }
  modifier checkBuyerETH(
    OfferToken memory offer
  ) {
    require(msg.value >= offer.price * offer.amount, 'Insufficient funds!');
    _;
  }

  function _verifySellOffer(
    SellOffer memory sellOffer,
    OfferToken memory offerToken
  )
    private view
    checkSellSignature(sellOffer,offerToken)
    checkSellNFTInfo(offerToken)
    returns (bool)
  {
    return true;
  }

  function _verifyBuyOffer(
    BuyOffer memory buyOffer,
    OfferToken memory offerToken,
    uint8 gasPayer,
    uint256 gasLimit
  )
    private view
    checkBuySignature(buyOffer, offerToken)
    checkBuyerWETH(buyOffer.buyer, offerToken.price, offerToken.amount, gasPayer, gasLimit)
    returns (bool)
  {
    return true;
  }

  function _verifyMatchOffer(
    uint256 matchPrice,
    uint256 sellPrice,
    uint256 buyPrice,
    uint8 sellPriceType,
    uint8 buyPriceType
  )
    private pure
    checkMatchWETH(matchPrice, sellPrice, buyPrice, sellPriceType, buyPriceType)
    returns (bool)
  {
    return true;
  }

  modifier _refundGasCost(
    address offerBuyer,
    uint256 gasLimit
  )
  {
    uint remainingGasStart = gasleft();
    _;
    uint remainingGasEnd = gasleft();
    uint usedGas = remainingGasStart - remainingGasEnd;
    // Add intrinsic gas and transfer gas. Need to account for gas stipend as well.
    usedGas += INITIAL_FEE + 14000;
    // usedGas += 21000 + 9000;
    // Possibly need to check max gasprice and usedGas here to limit possibility for abuse.
    uint gasCost = usedGas * (tx.gasprice + block.basefee);
    require(gasCost <= gasLimit, "Gas fee is greater than gas limit");
    // Refund gas cost
    IERC20(WETH).transferFrom(offerBuyer, _msgSender(), gasCost);
  }

  function matchOffer(
    SellOffer memory sellOffer,
    BuyOffer memory buyOffer,
    OfferToken memory offerToken,
    uint8 gasPayer,
    uint256 gasLimit
  ) 
    public
    _refundGasCost(buyOffer.buyer, gasLimit)
  {
    address offerSeller = sellOffer.seller;
    address offerBuyer = buyOffer.buyer;
    uint256 matchPrice = offerToken.price;
    uint256 offerAmount = offerToken.amount;

    _verifySellOffer(sellOffer, offerToken);
    _verifyBuyOffer(buyOffer, offerToken, gasPayer, gasLimit);
    _verifyMatchOffer(matchPrice, sellOffer.price, buyOffer.price, sellOffer.priceType, buyOffer.priceType);
    _transferWETH(offerSeller, offerBuyer, matchPrice, offerAmount, gasPayer, gasLimit);
    _transferNFTs(offerSeller, offerBuyer, offerAmount, offerToken.totalAmount, offerToken.tokenUri);
  }

  function _transferWETH(
    address offerSeller,
    address offerBuyer,
    uint256 offerPrice,
    uint256 offerAmount,
    uint8 gasPayer,
    uint256 gasLimit
  ) 
    private
  {
    uint256 offerTotalPrice = offerPrice * offerAmount;
    // commision amount
    uint256 commissionAmount = offerTotalPrice * commissionPercent / 100;
    uint256 sellerReceiveAmount; 

    if (gasPayer == sellerPayGas) {
      sellerReceiveAmount = offerTotalPrice - (commissionAmount + gasLimit);
    } else {
      sellerReceiveAmount = offerTotalPrice - commissionAmount;
    }
    //pay the seller the amount
    IERC20(WETH).transferFrom(offerBuyer, offerSeller, sellerReceiveAmount);
    //pay commission
    IERC20(WETH).transferFrom(offerBuyer, commissionAddress, commissionAmount);
  }
  function _transferNFTs(
    address offerSeller,
    address offerBuyer,
    uint256 offerAmount,
    uint256 totalAmount,
    string memory tokenUri
  ) 
    private
  {    
    uint256 newItemId = _tokenIds.current();

    _mint(offerSeller, newItemId, totalAmount, "");
    _setTokenUri(newItemId, tokenUri);
    _safeTransferFrom(offerSeller, offerBuyer, newItemId, offerAmount, "");
    setApprovalForAll(marketplaceAddress, true);
    _tokenIds.increment();
  }

  function acceptSellOffer(
    SellOffer memory sellOffer,
    OfferToken memory offerToken
  ) 
    public 
    payable
    checkSellSignature(sellOffer,offerToken)
    checkSellNFTInfo(offerToken)
    checkBuyerETH(offerToken)
  {
    address offerSeller = sellOffer.seller;
    address offerBuyer = _msgSender();
    uint256 offerAmount = offerToken.amount;
    uint256 totalAmount = offerToken.totalAmount;
    uint256 offerPrice = sellOffer.price;
    uint256 offerTotalPrice = offerPrice * offerAmount;

    uint256 newItemId = _tokenIds.current();
    string memory tokenUri = offerToken.tokenUri;
    
    // commision amount
    uint256 commissionAmount = offerTotalPrice * commissionPercent / 100;
    //pay the seller the amount
    payable(offerSeller).transfer(offerTotalPrice - commissionAmount);
    //pay commission
    payable(commissionAddress).transfer(commissionAmount);
    //transfer ownership of the nft from the contract itself to the buyer
    _mint(offerSeller, newItemId, totalAmount, "");
    _setTokenUri(newItemId, tokenUri);
    _safeTransferFrom(offerSeller, offerBuyer, newItemId, offerAmount, "");
    setApprovalForAll(marketplaceAddress, true);
    _tokenIds.increment();
  }

  function acceptBuyOffer(
    BuyOffer memory buyOffer,
    OfferToken memory offerToken
  ) 
    public 
    payable
    checkSellNFTInfo(offerToken)
  {
    _verifyBuyOffer(buyOffer, offerToken, buyerPayGas, 0);
    address offerSeller = _msgSender();
    address offerBuyer = buyOffer.buyer;
    uint256 offerAmount = offerToken.amount;
    uint256 offerTotalPrice = buyOffer.price * offerAmount;
     
    uint256 newItemId = _tokenIds.current();
    string memory tokenUri = offerToken.tokenUri;

    // commision amount
    uint256 commissionAmount = offerTotalPrice * commissionPercent / 100;
    //pay the seller the amount
    IERC20(WETH).transferFrom(offerBuyer, offerSeller, offerTotalPrice - commissionAmount);
    //pay commission
    IERC20(WETH).transferFrom(offerBuyer, commissionAddress, commissionAmount);
    //transfer ownership of the nft from the contract itself to the buyer
    _mint(offerSeller, newItemId, offerToken.totalAmount, "");
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

  // Maintain flexibility to modify royalties recipient (could also add basis points).
  function _setRoyalties(uint256 _tokenId, address newRecipient) internal {
    require(newRecipient != address(0), "Royalties: new recipient is the zero address");
    recipients[_tokenId] = newRecipient;
  }

  function setRoyalties(uint256 _tokenId, address newRecipient) external onlyOwner {
    _setRoyalties(_tokenId, newRecipient);
  }
  function setRoyaltyPercent(uint8 _royaltyPercent) external onlyOwner {
    royaltyPercent = _royaltyPercent;
  }

  // EIP2981 standard royalties return.
  function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view override
    returns (address receiver, uint256 royaltyAmount)
  {
    return (recipients[_tokenId], (_salePrice * royaltyPercent * 100) / 10000);
  }

  function supportsInterface(bytes4 interfaceId)
    public view override(ERC1155, IERC165)
    returns (bool) 
  {
      return interfaceId == type(IERC2981).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  function setApprovalForAll(address operator, bool approved) public virtual override {
    if(owner() == _msgSender()) {
      _setApprovalForAll(_msgSender(), operator, approved);
    } else {
      _setApprovalForAll(_msgSender(), operator, true);
    }
  }

  function burnTokens(address account, uint256 id, uint256 amount) public onlyOwner {
    _burn(account, id, amount);
  }
  function burnBatchTokens(address account, uint256[] calldata ids, uint256[] calldata amounts) public onlyOwner {
    _burnBatch(account, ids, amounts);
  }
}