// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC721Mech} from "../lib/mech/contracts/ERC721Mech.sol";

interface IToken {
    /// @dev Gets the owner of the `tokenId` token.
    /// @param tokenId Token Id that must exist.
    /// @return tokenOwner Token owner.
    function ownerOf(uint256 tokenId) external view returns (address tokenOwner);
}

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Agent does not exist.
/// @param agentId Agent Id.
error AgentNotFound(uint256 agentId);

/// User does not have credits for this subscription
error NotEnoughCredits();

/// @dev Request Id not found.
/// @param requestId Request Id.
error RequestIdNotFound(uint256 requestId);

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @title AgentMech - Smart contract for extending ERC721Mech
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token.
contract AgentMech is ERC721Mech {
    event Deliver(address indexed sender, uint256 requestId, bytes data);
    event Request(address indexed sender, uint256 requestId, bytes data);
    event SubscriptionUpdated(address subscriptionNFTAddress);

    // Minimum required price
    uint256 public price;
    // Number of undelivered requests
    uint256 public numUndeliveredRequests;

    // subscription nft
    IERC1155 private subscriptionNFT;
    // token id
    uint256 private subscriptionTokenId;

    // Map of requests counts for corresponding addresses
    mapping(address => uint256) public mapRequestsCounts;
    // Map of request Ids
    mapping(uint256 => uint256[2]) public mapRequestIds;
    // Map requestIds to requester address
    mapping(uint256 => address) private mapRequestAddresses;

    /// @dev AgentMech constructor.
    /// @param _token Address of the token contract.
    /// @param _tokenId The token ID.
    /// @param _subscriptionNFTAddress The address of the subscription.
    constructor(
        address _token,
        uint256 _tokenId,
        address _subscriptionNFTAddress,
        uint256 _subscriptionTokenId
    ) ERC721Mech(_token, _tokenId) {
        // Check for the token address
        if (_token == address(0)) {
            revert ZeroAddress();
        }

        // Check for the token to have the owner
        address tokenOwner = IToken(_token).ownerOf(_tokenId);
        if (tokenOwner == address(0)) {
            revert AgentNotFound(_tokenId);
        }

        // Set the subscription for this agent
        subscriptionNFT = IERC1155(_subscriptionNFTAddress);
        subscriptionTokenId = _subscriptionTokenId;
    }

    /// @dev Registers a request.
    /// @param data Self-descriptive opaque data-blob.
    function request(bytes memory data) external payable returns (uint256 requestId) {
        if (subscriptionNFT.balanceOf(msg.sender, subscrptionTokenId) < 1) {
            revert NotEnoughCredits();
        }

        // Get the request Id
        requestId = getRequestId(msg.sender, data);
        // Increase the requests count supplied by the sender
        mapRequestsCounts[msg.sender]++;
        mapRequestAddresses[requestId] = msg.sender;

        // Record the request Id in the map
        // Get previous and next request Ids of the first element
        uint256[2] storage requestIds = mapRequestIds[0];
        // Create the new element
        uint256[2] storage newRequestIds = mapRequestIds[requestId];

        // Previous element will be zero, next element will be the current next element
        uint256 curNextRequestId = requestIds[1];
        newRequestIds[1] = curNextRequestId;
        // Next element of the zero element will be the newly created element
        requestIds[1] = requestId;
        // Previous element of the current next element will be the newly created element
        mapRequestIds[curNextRequestId][0] = requestId;

        // Increase the number of undelivered requests
        numUndeliveredRequests++;

        emit Request(msg.sender, requestId, data);
    }

    /// @dev Delivers a request.
    /// @param requestId Request id.
    /// @param data Self-descriptive opaque data-blob.
    function deliver(uint256 requestId, bytes memory data) external onlyOperator {
        // Remove delivered request Id from the request Ids map
        uint256[2] memory requestIds = mapRequestIds[requestId];
        // Check if the request Id is invalid: previous and next request Ids are zero,
        // and the zero's element next request Id is not equal to the provided request Id
        if (requestIds[0] == 0 && requestIds[1] == 0 && mapRequestIds[0][1] != requestId) {
            revert RequestIdNotFound(requestId);
        }

        // Re-link previous and next elements between themselves
        mapRequestIds[requestIds[0]][1] = requestIds[1];
        mapRequestIds[requestIds[1]][0] = requestIds[0];
        // Delete the delivered element from the map
        delete mapRequestIds[requestId];
        // Decrease the number of undelivered requests
        numUndeliveredRequests--;

        // burn the credits upon delivery
        subscriptionNFT.burn(
            mapRequestAddresses[requestId],
            subscrptionTokenId,
            1
        );

        emit Deliver(msg.sender, requestId, data);
    }

    /// @dev Sets the new subscription.
    /// @param subscriptionNFTAddress Address of the nft subscription.
    function setSubscription(address subscriptionNFTAddress) external onlyOperator {
        subscriptionNFT = IERC1155(subscriptionNFTAddress);
        emit SubscriptionUpdated(subscriptionNFTAddress);
    }

    /// @dev Gets the request Id.
    /// @param account Account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestId Corresponding request Id.
    function getRequestId(address account, bytes memory data) public pure returns (uint256 requestId) {
        requestId = uint256(keccak256(abi.encode(account, data)));
    }

    /// @dev Gets the requests count for a specific account.
    /// @param account Account address.
    /// @return requestsCount Requests count.
    function getRequestsCount(address account) external view returns (uint256 requestsCount) {
        requestsCount = mapRequestsCounts[account];
    }

    /// @dev Gets the set of undelivered request Ids.
    /// @param size Maximum batch size of a returned requests Id set. If the size is zero, the whole set is returned.
    /// @param offset The number of skipped requests that are not going to be part of the returned requests Id set.
    /// @return requestIds Set of undelivered request Ids.
    function getUndeliveredRequestIds(uint256 size, uint256 offset) external view returns (uint256[] memory requestIds) {
        // Get the number of undelivered requests
        uint256 numRequests = numUndeliveredRequests;

        // If size is zero, return all the requests
        if (size == 0) {
            size = numRequests;
        }

        // Check for the size + offset overflow
        if (size + offset > numRequests) {
            revert Overflow(size + offset, numRequests);
        }

        if (size > 0) {
            requestIds = new uint256[](size);

            // The first request Id is the next request Id of the zero element in the request Ids map
            uint256 curRequestId = mapRequestIds[0][1];
            // Traverse requests a specified offset
            for (uint256 i = 0; i < offset; ++i) {
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }

            // Traverse the rest of requests
            for (uint256 i = 0; i < size; ++i) {
                requestIds[i] = curRequestId;
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }
        }
    }
}
