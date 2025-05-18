// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract SimpleContract {
    // State variable to store a number
    uint256 private storedNumber;
    
    // Event to notify when the number is updated
    event NumberUpdated(uint256 newNumber);
    
    // Constructor to initialize the contract
    constructor() {
        storedNumber = 0;
    }
    
    // Function 1: Increments the stored number by 1
    function increment() public returns (uint256) {
        storedNumber += 1;
        emit NumberUpdated(storedNumber);
        return storedNumber;
    }
    
    // Function 2: Returns the current stored number
    function getNumber() public view returns (uint256) {
        return storedNumber;
    }
}
