// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";


abstract contract LoanableV3 is OwnableUpgradeable {
    mapping(address => uint256) private _loanIssuerMap; // uint256 = 0 mean invalid
    address[] private _loanIssuers;

    function __Loanable_init_chained() internal initializer () {
        __Ownable_init();

        // fill in 0 index since we are going to make 0 index as invalid
        addLoanIssuer(address(0)); 
    }

    modifier onlyLoanIssuer() {
        require(_loanIssuerMap[msg.sender] > 0, "Caller is not loan issuer");
        _;
    }

    function getLoanIssuers() external view returns (address[] memory) {
        return _loanIssuers;
    }

    function addLoanIssuer(address loanIssuerAddress) public onlyOwner {
        require(_loanIssuerMap[loanIssuerAddress] == 0, "Loanable: Adding duplicated loan issuer address");

        _loanIssuers.push(loanIssuerAddress);
        _loanIssuerMap[loanIssuerAddress] = _loanIssuers.length - 1;
    }

    function removeLoanIssuer(address loanIssuerAddress) external onlyOwner {
        uint256 index = _loanIssuerMap[loanIssuerAddress];
        require(index != 0, "Loanable: Remove non existing loan issuer");

        _loanIssuerMap[loanIssuerAddress] = 0;
        delete _loanIssuers[index];
    }
}