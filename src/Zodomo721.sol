// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.21;

import "../lib/solady/src/tokens/ERC721.sol";
import "../lib/solady/src/auth/Ownable.sol";
import "../lib/LayerZero/contracts/interfaces/ILayerZeroReceiver.sol";
import "../lib/solady/src/utils/LibString.sol";
import "../lib/solidity-bytes-utils/contracts/BytesLib.sol";
import "../lib/solady/src/utils/FixedPointMathLib.sol";
import "../lib/AlignmentVault/src/IAlignmentVaultFactory.sol";
import "../lib/LayerZero/contracts/interfaces/ILayerZeroEndpoint.sol";

interface IAlignmentVault {
    function transferOwnership(address _owner) external;
} 

/// @title Zodomo721
/// @notice ERC721 template built while streaming on Sanko.tv
/// @dev Supports sending a portion of mints to an AlignmentVault and performing cross-chain transfers via LayerZero
/// @custom:sanko https://sanko.tv/0xZodomo
/// @custom:github https://github.com/Zodomo/Zodomo721
contract Zodomo721 is ERC721, Ownable, ILayerZeroReceiver {
    using LibString for uint256;
    using LibString for string;
    using BytesLib for bytes;

    error Invalid();
    error LZEndpoint();
    error MintClosed();
    error MaxExceeded();
    error TransferFailed();
    error InsufficientPayment();

    event MintOpened();
    event MintDisabled();
    event SetBaseURI(string indexed baseURI_);
    event LZBridged(address indexed _owner, uint256 indexed _tokenId);

    address private constant avFactory = 0xD7810e145F1A30C7d0B8C332326050Af5E067d43;
    address private constant milady = 0x5Af0D9827E0c53E4799BB226655A1de152A425a5;

    string private _name;
    string private _symbol;
    string private _baseURI;
    string private _contractURI;

    mapping(uint16 => bool) public lzChains;
    address public lzEndpoint;
    uint96 public price;
    address public vault;
    uint32 public totalSupply;
    uint32 public maxSupply;
    uint16 public allocation;
    bool public mintOpen;
    bool public mintDisabled;

    modifier mintable(uint256 _amount) {
        if (msg.value < price) revert InsufficientPayment();
        if (!mintOpen) revert MintClosed();
        if (totalSupply + _amount > maxSupply) revert MaxExceeded();
        _;
    }

    modifier onlyHolder(uint256 _tokenId) {
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert Unauthorized();
        _;
    }

    modifier mainnetOnly() {
        if (mintDisabled) revert Invalid();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        string memory contractURI_,
        uint32 _maxSupply,
        uint96 _price,
        uint16 _allocation,
        address _lzEndpoint,
        address _owner
    ) {
        _name = name_;
        _symbol = symbol_;
        _baseURI = baseURI_;
        _contractURI = contractURI_;
        maxSupply = _maxSupply;
        price = _price;
        allocation = _allocation;
        lzEndpoint = _lzEndpoint;
        _initializeOwner(_owner);
        vault = IAlignmentVaultFactory(avFactory).deploy(milady, 392);
        IAlignmentVault(vault).transferOwnership(_owner);
    }

    function name() public view override returns (string memory) {
        return _name;
    }
    function symbol() public view override returns (string memory) {
        return _symbol;
    }
    function baseURI() public view returns (string memory) {
        return _baseURI;
    }
    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        if (!_exists(_tokenId)) revert Invalid();
        string memory baseURI_ = baseURI();
        return string(abi.encodePacked(baseURI_, _tokenId.toString()));
    }
    function _getDescription(uint256 _tokenId) internal pure returns (string memory) {
        return _tokenId.toString();
    }
    function _getImage(uint256 _tokenId) internal pure returns (string memory) {
        return _tokenId.toString();
    }
    function _getName(uint256 _tokenId) internal pure returns (string memory) {
        return _tokenId.toString();
    }
    /*function onchainTokenURI(uint256 _tokenId) public view returns (string memory) {
        if (!_exists(_tokenId)) revert Invalid();
        string memory json = string.concat(
            '{',
                '"description": "', _getDescription(_tokenId), '",',
                '"external_url": "', 'https://milady.zip', '",',
                '"image": "', _getImage(_tokenId), '",',
                '"name": "', _getName(_tokenId), '",',
                '"attributes": "', 'TODO', '"',
            '}'
        );
        return string.concat('data:application/json;utf8,', json);
    }*/

    function _mint(address _to, uint256 _amount) internal override mintable(_amount) {
        if (_amount > type(uint32).max) revert Invalid();
        uint256 _totalSupply = totalSupply;
        for (uint256 i; i < _amount;) {
            unchecked { ++_totalSupply; }
            super._mint(_to, _totalSupply);
            unchecked { ++i; }
        }
        unchecked { totalSupply += uint32(_amount); }
        (bool success, ) = payable(vault).call{ value: FixedPointMathLib.mulDivUp(msg.value, allocation, 10000) }("");
        if (!success) revert TransferFailed();
    }
    function mint() public payable {
        _mint(msg.sender, 1);
    }
    function mint(uint256 _amount) public payable {
        if (_amount > type(uint32).max) revert Invalid();
        _mint(msg.sender, _amount);
    }
    function mint(address _to) public payable {
        _mint(_to, 1);
    }
    function mint(address _to, uint256 _amount) public payable {
        _mint(_to, _amount);
    }

    function setBaseURI(string memory baseURI_) external onlyOwner {
        _baseURI = baseURI_;
        emit SetBaseURI(baseURI_);
    }
    function setPrice(uint96 _price) external onlyOwner mainnetOnly {
        if (_price >= price) revert Invalid();
        price = _price;
    }
    function setLzChain(uint16 _dstChainId, bool _status) external onlyOwner {
        lzChains[_dstChainId] = _status;
    }
    function reduceSupply(uint32 _supply) external onlyOwner mainnetOnly {
        if (_supply >= maxSupply) revert Invalid();
        maxSupply = _supply;
    }
    function increaseAllocation(uint16 _allocation) external onlyOwner mainnetOnly {
        if (_allocation <= allocation) revert Invalid();
        allocation = _allocation;
    }
    function openMint() external onlyOwner mainnetOnly {
        mintOpen = true;
        emit MintOpened();
    }
    function disableMint() external onlyOwner {
        mintDisabled = true;
        emit MintDisabled();
    }

    function lzSend(
        uint16 _dstChainId,
        address _zroPaymentAddress,
        uint256 _nativeFee,
        bytes memory _adapterParams,
        address _owner,
        uint256 _tokenId
    ) external onlyHolder(_tokenId) {
        if (!lzChains[_dstChainId]) revert Invalid();
        bytes memory payload = abi.encodePacked(_owner, _tokenId);
        ILayerZeroEndpoint(lzEndpoint).send{ value: _nativeFee }(
            _dstChainId,
            abi.encodePacked(address(this), address(this)),
            payload,
            payable(msg.sender),
            _zroPaymentAddress,
            _adapterParams
        );
        emit LZBridged(_owner, _tokenId);
        ERC721._burn(_tokenId);
    }

    function lzReceive(
        uint16,
        bytes calldata _srcAddress,
        uint64,
        bytes calldata _payload
    ) external {
        if (msg.sender != lzEndpoint) revert LZEndpoint();
        if (!_srcAddress.equal(abi.encodePacked(address(this), address(this)))) revert Unauthorized();
        address owner;
        uint256 tokenId;
        owner = _payload.slice(0, 20).toAddress(0);
        tokenId = _payload.slice(20, 32).toUint256(0);
        emit LZBridged(owner, tokenId);
        ERC721._mint(owner, tokenId);
    }
}