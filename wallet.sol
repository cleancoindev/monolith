pragma solidity ^0.4.24;


/// @title The Token interface is a subset of the ERC20 specification.
interface Token {
    function transfer(address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

/// @title The Oracle interface provides exchange rates for ERC20 tokens in wei.
interface Oracle {
    function rate(address) external view returns (uint);
}

/// @title Control handles wallet access control.
contract Control {
    mapping (address => bool) public isController;
    address public owner;

    /// @dev Executable only by the owner.
    modifier onlyOwner {
        require(msg.sender == owner);
        _;
    }

    /// @dev Executable only by the controller.
    modifier onlyController {
        require(isController[msg.sender]);
        _;
    }

    /// @dev Executable by either owner or controller.
    modifier eitherOwnerOrController() {
        require(isController[msg.sender] || msg.sender == owner);
        _;
    }

    /// @dev Add a new controller to the list of controllers.
    function addController(address _account) public onlyController {
        isController[_account] = true;
    }

    /// @dev Remove a controller from the list of controllers.
    function removeController(address _account) public onlyController {
        isController[_account] = false;
    }
}

/// @title Whitelist provides payee-whitelist functionality.
contract Whitelist is Control {

    event WhitelistAddition(address[] _addresses);
    event WhitelistRemoval(address[] _addresses);

    mapping(address => bool) public isWhitelisted;
    address[] public pendingAddition;
    address[] public pendingRemoval;
    bool internal submittedAddition;
    bool internal submittedRemoval;
    bool internal whitelistInitialized;

    /// @dev Add addresses to the whitelist.
    /// @param _addresses are the Ethereum addresses to be whitelisted.
    function addToWhitelist(address[] _addresses) public onlyOwner {
        if (!whitelistInitialized) {
            // Add each of the provided addresses to the whitelist.
            for (uint i = 0; i < _addresses.length; i++) {
                isWhitelisted[_addresses[i]] = true;
            }
            emit WhitelistAddition(_addresses);
            whitelistInitialized = true;
        } else {
            // Check if this operation has been already submitted.
            require(!submittedAddition);
            // Limit the amount of addresses that can be whitelisted at one time.
            require(_addresses.length <= 20);
            // Add each of the provided addresses to the pending addition list.
            for (i = 0; i < _addresses.length; i++) {
                pendingAddition.push(_addresses[i]);
            }
            // Flag the operation as submitted.
            submittedAddition = true;
        }
    }

    /// @dev Confirm pending whitelist addition.
    function addToWhitelistConfirm() public onlyController {
        require(pendingAddition.length > 0 && submittedAddition);
        // Whitelist pending addresses.
        for (uint i = 0; i < pendingAddition.length; i++) {
            isWhitelisted[pendingAddition[i]] = true;
        }
        emit WhitelistAddition(pendingAddition);
        // Reset the submission flag.
        submittedAddition = false;
    }

    /// @dev Cancel pending whitelist addition.
    function addToWhitelistCancel() public onlyController {
        // Reset pending addresses.
        delete pendingAddition;
        // Reset the submitted operation flag.
        submittedAddition = false;
    }

    /// @dev Remove addresses from the whitelist.
    /// @param _addresses are the Ethereum addresses to be removed.
    function removeFromWhitelist(address[] _addresses) public onlyOwner {
        // Check if this operation has been already submitted.
        require(!submittedRemoval);
        // Limit the amount of addresses that can be removed at one time.
        require(_addresses.length <= 20);
        // Add each of the addresses to the pending removal list.
        for (uint i = 0; i < _addresses.length; i++) {
            pendingRemoval.push(_addresses[i]);
        }
        // Flag the operation as submitted.
        submittedRemoval = true;
    }

    /// @dev Confirm pending removal of whitelisted addresses.
    function removeFromWhitelistConfirm() public onlyController {
        require(pendingRemoval.length > 0 && submittedRemoval);
        // Remove pending addresses.
        for (uint i = 0; i < pendingRemoval.length; i++) {
            isWhitelisted[pendingRemoval[i]] = false;
        }
        emit WhitelistRemoval(pendingRemoval);
        // Reset the submission flag.
        submittedRemoval = false;
    }

    /// @dev Cancel pending removal of whitelisted addresses.
    function removeFromWhitelistCancel() public onlyController {
        // Reset pending addresses.
        delete pendingRemoval;
        // Reset the submitted operation flag.
        submittedRemoval = false;
    }
}

/// @title DailyLimit provides daily spend limit functionality.
contract DailyLimit is Control {

    event SetDailyLimit(uint _amount);

    uint public dailyLimit;
    uint public currentDay;
    uint internal availableToday;

    uint public pendingDailyLimit;
    bool internal submittedDailyLimit;
    bool internal dailyLimitInitialized;

    /// @dev Set a daily transfer limit for non-whitelisted addresses.
    /// @param _amount is the daily limit amount in wei.
    function setDailyLimit(uint _amount) public onlyOwner {
        if (!dailyLimitInitialized) {
            // Set the daily limit to the provided amount.
            dailyLimit = _amount;
            emit SetDailyLimit(_amount);
            dailyLimitInitialized = true;
        } else {
            // Check if this operation has been already submitted.
            require(!submittedDailyLimit);
            // Assign the provided amount to pending daily limit change.
            pendingDailyLimit = _amount;
            // Flag the operation as submitted.
            submittedDailyLimit = true;
        }
    }

    /// @dev Confirm pending set daily limit operation.
    function setDailyLimitConfirm() public onlyController {
        require(submittedDailyLimit);
        // Set the daily limit to the pending amount.
        dailyLimit = pendingDailyLimit;
        emit SetDailyLimit(pendingDailyLimit);
        // Reset the submission flag.
        submittedDailyLimit = false;
    }

    /// @dev Cancel pending set daily limit operation.
    function setDailyLimitCancel() public onlyController {
        // Reset pending daily limit change.
        pendingDailyLimit = 0;
        // Reset the submitted operation flag.
        submittedDailyLimit = false;
    }
}

/// @title Asset wallet with extra security features.
/// @author TokenCard
contract Wallet is Whitelist, DailyLimit {
    // Events
    event Deposit(address _from, uint _amount);
    event Transfer(address _to, address _token, uint _amount);
    event TopUpGas(address _sender, address _owner, uint _amount);

    // Constants
    uint private constant GAS_BALANCE_MAX = 500 finney;

    // Storage
    address public oracle;

    /// @dev Construct a wallet with an owner and a controller.
    constructor(address _owner, address _oracle, address[] _controllers) public {
        currentDay = now;
        dailyLimit = 1 ether;
        availableToday = dailyLimit;
        owner = _owner;
        oracle = _oracle;
        for (uint i = 0; i < _controllers.length; i++) {
            isController[_controllers[i]] = true;
        }
    }

    /// @dev Checks if the value is not zero.
    modifier notZero(uint _value) {
        require(_value != 0);
        _;
    }

    /// @dev Ether can be deposited from any source, so this contract must be payable by anyone.
    function() public payable {
        if (msg.value > 0) {
            emit Deposit(msg.sender, msg.value);
        }
    }

    /// @dev Returns the amount of an asset owned by the contract.
    /// @param _token address of an ERC20 token, 0x0 is used for ether.
    /// @return balance associated with the wallet address in wei.
    function balance(address _token) public view returns (uint) {
        if (_token != 0x0) {
            return Token(_token).balanceOf(this);
        } else {
            return address(this).balance;
        }
    }

    /// @dev Returns the available daily balance - accounts for daily limit reset.
    /// @return amount of ether in wei.
    function available() public view returns (uint) {
        if (now > currentDay + 24 hours) {
            return dailyLimit;
        } else {
            return availableToday;
        }
    }

    /// @dev Transfer asset to an address.
    /// @param _to recipient address.
    /// @param _token address of an ERC20 token, 0x0 is used for ether.
    /// @param _amount is the amount of tokens to be transferred in base units.
    function transfer(address _to, address _token, uint _amount) public onlyOwner notZero(_amount) {
        // If address is not whitelisted, take daily limit into account.
        if (!isWhitelisted[_to]) {
            // Convert token amount to ether value.
            uint etherValue;
            if (_token != 0x0) {
                etherValue = Oracle(oracle).rate(_token) * _amount;
                assert(etherValue != 0);
            } else {
                etherValue = _amount;
            }
            // Require that the value is under remaining limit.
            if (now > currentDay + 24 hours) {
                uint extraDays = (now - currentDay) / 24 hours;
                currentDay += extraDays * 24 hours;
                availableToday = dailyLimit;
            }
            require(etherValue <= availableToday);
            // Update the available limit.
            availableToday -= etherValue;
        }
        // Transfer token or ether based on the provided address.
        if (_token != 0x0) {
            require(Token(_token).transfer(_to, _amount));
        } else {
            _to.transfer(_amount);
        }
        emit Transfer(_to, _token, _amount);
    }

    /// @dev Refill owner's gas balance.
    /// @param _amount the amount of ether to transfer to the owner account in wei.
    function topUpGas(uint _amount) public eitherOwnerOrController notZero(_amount) {
        // Require that the owner's balance is below threshold.
        require(owner.balance < GAS_BALANCE_MAX);
        // Check for uint overflow.
        require(owner.balance + _amount > owner.balance);
        // Transfer ether to owner's account and don't exceed the maximum.
        if (owner.balance + _amount > GAS_BALANCE_MAX) {
            _amount = GAS_BALANCE_MAX - owner.balance;
        }
        owner.transfer(_amount);
        emit TopUpGas(tx.origin, owner, _amount);
    }
}