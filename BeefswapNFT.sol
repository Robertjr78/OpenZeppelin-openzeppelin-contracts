//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract BefswapNFT is Initializable, ERC721EnumerableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    bytes32 public constant TOKEN_FREEZER = keccak256("TOKEN_FREEZER");
    bytes32 public constant TOKEN_MINTER_ROLE = keccak256("TOKEN_MINTER");
    bytes32 public constant LAUNCHPAD_TOKEN_MINTER = keccak256("LAUNCHPAD_TOKEN_MINTER");
    bytes32 public constant RB_SETTER_ROLE = keccak256("RB_SETTER");
    uint public constant MAX_ARRAY_LENGTH_PER_REQUEST = 30;

    string private _internalBaseURI;
    uint private _initialBeefBoost;
    uint private _burnBBPeriod; //in days
    uint8 private _levelUpPercent; //in percents
    uint[7] private _rbTable;
    uint[7] private _levelTable;
    uint private _lastTokenId;

    struct Token {
        uint beefBoost;
        uint level;
        bool stakeFreeze; //Lock a token when it is staked
        uint createTimestamp;
    }

    mapping(uint256 => Token) private _tokens;
    mapping(address => mapping(uint => uint)) private _beefBoost;
    mapping(uint => uint) private _beefBoostTotalAmounts;

    event GainBB(uint indexed tokenId, uint newBB);
    event RBAccrued(address user, uint amount);
    event LevelUp(address indexed user, uint indexed newLevel, uint[] parentsTokensId);
    //BNF-01, SFR-01
    event Initialize(string baseURI, uint initialBeefBoost, uint burnBBPeriod);
    event TokenMint(address indexed to, uint indexed tokenId, uint level, uint beefBoost);
    event BbDecrease(uint[] tokensId, uint[] finalBB);

    function initialize(
        string memory baseURI,
        uint initialBeefBoost,
        uint burnBBPeriod
    ) public initializer {
        __ERC721_init("BeefCowBoost", "BCB");
        __ERC721Enumerable_init();
        __AccessControl_init_unchained();
        __ReentrancyGuard_init();

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _internalBaseURI = baseURI;
        _initialRobiBoost = initialBeefBoost;
        _levelUpPercent = 10; //10%
        _burnRBPeriod = burnBBPeriod;

        _rbTable[0] = 100 ether;
        _rbTable[1] = 10 ether;
        _rbTable[2] = 100 ether;
        _rbTable[3] = 1000 ether;
        _rbTable[4] = 10000 ether;
        _rbTable[5] = 50000 ether;
        _rbTable[6] = 150000 ether;

        _levelTable[0] = 0;
        _levelTable[1] = 6;
        _levelTable[2] = 5;
        _levelTable[3] = 4;
        _levelTable[4] = 3;
        _levelTable[5] = 2;
        _levelTable[6] = 0;

        //BNF-01, SFR-01
        emit Initialize(baseURI, initialBeefBoost, burnBBPeriod);
    }

    //External functions --------------------------------------------------------------------------------------------

    function getLevel(uint tokenId) external view returns (uint) {
        return _tokens[tokenId].level;
    }

    function getBB(uint tokenId) external view returns (uint) {
        return _tokens[tokenId].robiBoost;
    }

    function getInfoForStaking(uint tokenId)
        external
        view
        returns (
            address tokenOwner,
            bool stakeFreeze,
            uint robiBoost
        )
    {
        tokenOwner = ownerOf(tokenId);
        beefBoost = _tokens[tokenId].beefBoost;
        stakeFreeze = _tokens[tokenId].stakeFreeze;
    }

    function setBBTable(uint[7] calldata rbTable) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _bbTable = bbTable;
    }

    function setLevelTable(uint[7] calldata levelTable) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _levelTable = levelTable;
    }

    function setLevelUpPercent(uint8 percent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(percent > 0, "Wrong percent value");
        _levelUpPercent = percent;
    }

    function setBaseURI(string calldata newBaseUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _internalBaseURI = newBaseUri;
    }

    function setBurnBBPeriod(uint newPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPeriod > 0, "Wrong period");
        _burnBBPeriod = newPeriod;
    }

    function tokenFreeze(uint tokenId) external onlyRole(TOKEN_FREEZER) {
        // Clear all approvals when freeze token
        _approve(address(0), tokenId);

        _tokens[tokenId].stakeFreeze = true;
    }

    function tokenUnfreeze(uint tokenId) external onlyRole(TOKEN_FREEZER) {
        _tokens[tokenId].stakeFreeze = false;
    }

    function accrueBB(address user, uint amount) external onlyRole(BB_SETTER_ROLE) {
        uint curDay = block.timestamp / 86400;
        increaseBeefBoost(user, curDay, amount);
        emit BBAccrued(user, _beefBoost[user][curDay]);
    }

    function decreaseBB(uint[] calldata tokensId, uint decreasePercent, uint minDecreaseLevel, address user) external onlyRole(BB_SETTER_ROLE) returns(uint decreaseAmount) {
        require(decreasePercent <= 1e12, "Wrong decrease percent");
        uint[] memory finalBB = new uint[](tokensId.length);
        decreaseAmount = 0;
        for(uint i = 0; i < tokensId.length; i++){
            if(_tokens[tokensId[i]].level <= minDecreaseLevel) continue;
            require(ownerOf(tokensId[i]) == user, "Not owner");
            uint currentBB = _tokens[tokensId[i]].beefBoost;
            finalBB[i] = currentBB * decreasePercent / 1e12;
            _tokens[tokensId[i]].beefBoost = finalBB[i];
            decreaseAmount += currentBB - finalBB[i];
        }
        emit RbDecrease(tokensId, finalBB);
    }

    function decreaseBBView(uint[] calldata tokensId, uint decreasePercent, uint minDecreaseLevel) external view returns(uint decreaseAmount) {
        require(decreasePercent <= 1e12, "Wrong decrease percent");
        decreaseAmount = 0;
        for(uint i = 0; i < tokensId.length; i++){
            if(_tokens[tokensId[i]].level <= minDecreaseLevel) continue;
            decreaseAmount += _tokens[tokensId[i]].beefBoost - _tokens[tokensId[i]].beefBoost * decreasePercent / 1e12;
        }
    }

    //Public functions --------------------------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return interfaceId == type(IERC721EnumerableUpgradeable).interfaceId || super.supportsInterface(interfaceId);
    }

    function remainBBToNextLevel(uint[] calldata tokenId) public view returns (uint[] memory) {
        require(tokenId.length <= MAX_ARRAY_LENGTH_PER_REQUEST, "Array length gt max");
        uint[] memory remainBB = new uint[](tokenId.length);
        for (uint i = 0; i < tokenId.length; i++) {
            require(_exists(tokenId[i]), "ERC721: token does not exist");
            remainBB[i] = _remainBBToMaxLevel(tokenId[i]);
        }
        return remainRB;
    }

    function getBbBalance(address user) public view returns (uint) {
        return _getBbBalance(user);
    }

    function getBbBalanceByDays(address user, uint dayCount) public view returns (uint[] memory) {
        uint[] memory balance = new uint[](dayCount);
        for (uint i = 0; i < dayCount; i++) {
            balance[i] = _beefBoost[user][(block.timestamp - i * 1 days) / 86400];
        }
        return balance;
    }

    function getBbTotalAmount(uint period) public view returns (uint amount) {
        for (uint i = 0; i <= period; i++) {
            amount += _beefBoostTotalAmounts[(block.timestamp - i * 1 days) / 86400];
        }
        return amount;
    }

    function getToken(uint _tokenId)
        public
        view
        returns (
            uint tokenId,
            address tokenOwner,
            uint level,
            uint bb,
            bool stakeFreeze,
            uint createTimestamp,
            uint remainToNextLevel,
            string memory uri
        )
    {
        require(_exists(_tokenId), "ERC721: token does not exist");
        Token memory token = _tokens[_tokenId];
        tokenId = _tokenId;
        tokenOwner = ownerOf(_tokenId);
        level = token.level;
        rb = token.beefBoost;
        stakeFreeze = token.stakeFreeze;
        createTimestamp = token.createTimestamp;
        remainToNextLevel = _remainBBToMaxLevel(_tokenId);
        uri = tokenURI(_tokenId);
    }

    function approve(address to, uint256 tokenId) public override {
        if (_tokens[tokenId].stakeFreeze == true) {
            revert("ERC721: Token frozen");
        }
        super.approve(to, tokenId);
    }

    //BNF-02, SCN-01, SFR-02
    function mint(address to) public onlyRole(TOKEN_MINTER_ROLE) nonReentrant {
        require(to != address(0), "Address can not be zero");
        _lastTokenId += 1;
        uint tokenId = _lastTokenId;
        _tokens[tokenId].beefBoost = _initialbeefBoost;
        _tokens[tokenId].createTimestamp = block.timestamp;
        _tokens[tokenId].level = 1; //start from 1 level
        _safeMint(to, tokenId);
    }

    //BNF-02, SCN-01, SFR-02
    function launchpadMint(
        address to,
        uint level,
        uint beefBoost
    ) public onlyRole(LAUNCHPAD_TOKEN_MINTER) nonReentrant {
        require(to != address(0), "Address can not be zero");
        require(_bbTable[level] >= beefBoost, "BB Value out of limit");
        _lastTokenId += 1;
        uint tokenId = _lastTokenId;
        _tokens[tokenId].beefBoost = beefBoost;
        _tokens[tokenId].createTimestamp = block.timestamp;
        _tokens[tokenId].level = level;
        _safeMint(to, tokenId);
    }

    function levelUp(uint[] calldata tokenId) public nonReentrant {
        require(tokenId.length <= MAX_ARRAY_LENGTH_PER_REQUEST, "Array length gt max");
        uint currentLevel = _tokens[tokenId[0]].level;
        require(_levelTable[currentLevel] != 0, "This level not upgradable");
        uint numbersOfToken = _levelTable[currentLevel];
        require(numbersOfToken == tokenId.length, "Wrong numbers of tokens received");
        uint neededRb = numbersOfToken * _rbTable[currentLevel];
        uint cumulatedRb = 0;
        for (uint i = 0; i < numbersOfToken; i++) {
            Token memory token = _tokens[tokenId[i]]; //safe gas
            require(token.level == currentLevel, "Token not from this level");
            cumulatedBb += token.beefBoost;
        }
        if (neededBb == cumulatedBb) {
            _mintLevelUp((currentLevel + 1), tokenId);
        } else {
            revert("Wrong beef boost amount");
        }
        emit LevelUp(msg.sender, (currentLevel + 1), tokenId);
    }

    function sendBBToToken(uint[] calldata tokenId, uint[] calldata amount) public nonReentrant {
        _sendBBToToken(tokenId, amount);
    }

    function exchangeBB(uint amount, address userAddress) public nonReentrant onlyRole(BB_SETTER_ROLE) returns (bool) {
        uint calcAmount = amount;
        uint period = _burnBBPeriod;
        uint currentBB;
        uint curDay;
        while (calcAmount > 0 || period > 0) {
            curDay = (block.timestamp - period * 1 days) / 1 days;
            currentRB = _beefBoost[userAddress][curDay];
            if (currentBB == 0) {
                period--;
                continue;
            }
            if (calcAmount > currentBB) {
                calcAmount -= currentBB;
                _beefBoostTotalAmounts[curDay] -= currentBB;
                delete _beefBoost[userAddress][curDay];
            } else {
                decreaseBeefBoost(userAddress, curDay, calcAmount);
                calcAmount = 0;
                break;
            }
            period--;
        }
        if (calcAmount == 0) {
            return (true);
        } else {
            revert("Not enough BB balance");
        }
    }

    function sendBBToMaxInTokenLevel(uint[] calldata tokenId) public nonReentrant {
        require(tokenId.length <= MAX_ARRAY_LENGTH_PER_REQUEST, "Array length max");
        uint neededAmount;
        uint[] memory amounts = new uint[](tokenId.length);
        for (uint i = 0; i < tokenId.length; i++) {
            uint amount = _remainBBToMaxLevel(tokenId[i]);
            amounts[i] = amount;
            neededAmount += amount;
        }
        uint availableAmount = _getBbBalance(msg.sender);
        if (availableAmount >= neededAmount) {
            _sendBBToToken(tokenId, amounts);
        } else {
            revert("Insufficient funds");
        }
    }

    //Internal functions --------------------------------------------------------------------------------------------

    function _baseURI() internal view override returns (string memory) {
        return _internalBaseURI;
    }

    function _safeMint(address to, uint256 tokenId) internal override {
        super._safeMint(to, tokenId);
        emit TokenMint(to, tokenId, _tokens[tokenId].level, _tokens[tokenId].beefBoost);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override(ERC721EnumerableUpgradeable) {
        if (_tokens[tokenId].stakeFreeze == true) {
            revert("ERC721: Token frozen");
        }
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function _getBbBalance(address user) internal view returns (uint balance) {
        for (uint i = 0; i <= _burnBBPeriod; i++) {
            balance += _beefBoost[user][(block.timestamp - i * 1 days) / 86400];
        }
        return balance;
    }

    function _remainBBToMaxLevel(uint tokenId) internal view returns (uint) {
        return _bbTable[uint(_tokens[tokenId].level)] - _tokens[tokenId].beefBoost;
    }

    function _sendBBToToken(uint[] memory tokenId, uint[] memory amount) internal {
        require(tokenId.length <= MAX_ARRAY_LENGTH_PER_REQUEST, "Array length gt max");
        require(tokenId.length == amount.length, "Wrong length of arrays");
        for (uint i = 0; i < tokenId.length; i++) {
            require(ownerOf(tokenId[i]) == msg.sender, "Not owner of token");
            uint calcAmount = amount[i];
            uint period = _burnBBPeriod;
            uint currentBB;
            uint curDay;
            while (calcAmount > 0 || period > 0) {
                curDay = (block.timestamp - period * 1 days) / 86400;
                currentBB = _beefBoost[msg.sender][curDay];
                if (currentRB == 0) {
                    period--;
                    continue;
                }
                if (calcAmount > currentRB) {
                    calcAmount -= currentRB;
                    _beefBoostTotalAmounts[curDay] -= currentBB;
                    delete _beefBoost[msg.sender][curDay];
                } else {
                    decreasebeefBoost(msg.sender, curDay, calcAmount);
                    calcAmount = 0;
                    break;
                }
                period--;
            }
            if (calcAmount == 0) {
                _gainBB(tokenId[i], amount[i]);
            } else {
                revert("Not enough BB balance");
            }
        }
    }

    //Private functions --------------------------------------------------------------------------------------------

    function _mintLevelUp(uint level, uint[] memory tokenId) private {
        uint newBeefBoost = 0;
        for (uint i = 0; i < tokenId.length; i++) {
            require(ownerOf(tokenId[i]) == msg.sender, "Not owner of token");
            newBeefBoost += _tokens[tokenId[i]].robiBoost;
            _burn(tokenId[i]);
        }
        newBeefBoost = newBeefBoost + (newBeefBoost * _levelUpPercent) / 100;
        _lastTokenId += 1;
        uint newTokenId = _lastTokenId;
        _tokens[newTokenId].BeefBoost = newBeefBoost;
        _tokens[newTokenId].createTimestamp = block.timestamp;
        _tokens[newTokenId].level = level;
        _safeMint(msg.sender, newTokenId);
    }

    function increaseBeefBoost(
        address user,
        uint day,
        uint amount
    ) private {
        _robiBoost[user][day] += amount;
        _BeefBoostTotalAmounts[day] += amount;
    }

    function decreaseBeefBoost(
        address user,
        uint day,
        uint amount
    ) private {
        require(_BeefBoost[user][day] >= amount && _BeefBoostTotalAmounts[day] >= amount, "Wrong amount");
        _BeefBoost[user][day] -= amount;
        _BeefBoostTotalAmounts[day] -= amount;
    }

    function _gainRB(uint tokenId, uint rb) private {
        require(_exists(tokenId), "Token does not exist");
        require(_tokens[tokenId].stakeFreeze == false, "Token is staked");
        Token storage token = _tokens[tokenId];
        uint newRP = token.BeefBoost + bb;
        require(newRP <= _bbTable[token.level], "BB value over limit by level");
        token.beefBoost = newRP;
        emit GainRB(tokenId, newRP);
    }
}
