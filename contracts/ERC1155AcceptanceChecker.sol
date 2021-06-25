// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

abstract contract ERC1155AcceptanceChecker {
    /**
    * @dev Copied {ERC1155._doSafeTransferAcceptanceCheck}
    * from "openzeppelin/contracts/token/ERC1155/ERC1155.sol";
    */
    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    )
        internal
    {
        if (Address.isContract(to)) {
            try
            IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data)
            returns (bytes4 response)
            {
                if (response != IERC1155Receiver(to).onERC1155Received.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non ERC1155Receiver implementer");
            }
        }
    }
}