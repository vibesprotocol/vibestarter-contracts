// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VibesToken
 * @notice Simple fixed-supply ERC20 token with no mint function after deployment.
 * @dev All supply is minted to recipient at construction time.
 */
contract VibesToken {
    // ============================================
    // EVENTS
    // ============================================
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ============================================
    // STATE
    // ============================================
    
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public immutable totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ============================================
    // CONSTRUCTOR
    // ============================================
    
    /**
     * @param _name Token name
     * @param _symbol Token symbol  
     * @param _decimals Token decimals (typically 18)
     * @param _totalSupply Total supply to mint
     * @param _recipient Address to receive all tokens
     */
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _totalSupply,
        address _recipient
    ) {
        require(bytes(_name).length > 0, "Name required");
        require(bytes(_symbol).length > 0, "Symbol required");
        require(_totalSupply > 0, "Supply must be > 0");
        require(_recipient != address(0), "Invalid recipient");
        
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = _totalSupply;
        
        // Mint entire supply to recipient
        balanceOf[_recipient] = _totalSupply;
        emit Transfer(address(0), _recipient, _totalSupply);
    }

    // ============================================
    // ERC20 FUNCTIONS
    // ============================================
    
    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "Insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    // ============================================
    // INTERNAL
    // ============================================
    
    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(to != address(0), "Invalid recipient");
        require(balanceOf[from] >= amount, "Insufficient balance");
        
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        
        emit Transfer(from, to, amount);
        return true;
    }
}
